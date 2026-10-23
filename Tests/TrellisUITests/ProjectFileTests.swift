import AppKit
import XCTest
import TrellisControl
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// `.trellis/project.json` end to end (FR-WF01–FR-WF06), with a fake `zsh` that gets shell integration
/// injected but never prints marks itself, so each test decides when the "first prompt" arrives.
final class ProjectFileTests: XCTestCase {
    private var scratch: URL!
    private var project: String!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-wf-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let manager = FileManager.default
        try manager.createDirectory(at: scratch.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try manager.createDirectory(at: scratch.appendingPathComponent("state"), withIntermediateDirectories: true)
        try manager.createDirectory(at: scratch.appendingPathComponent("project/src"), withIntermediateDirectories: true)
        project = scratch.appendingPathComponent("project").path
        let shell = scratch.appendingPathComponent("bin/zsh")
        try "#!/bin/sh\nprintf 'SHELL-UP PWD=%s\\n' \"$(/bin/pwd -P | /usr/bin/sed 's|.*/||')\"\nexec /bin/sleep 30\n".write(to: shell, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    @MainActor
    private func makeModel() async throws -> AppWorkspaceModel {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-wf-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        _ = await model.loadWorkspace()
        model.confirmCloseSessions = { _ in true }
        model.chooseProjectFolder = { _, _ in
            XCTFail("Unexpected folder panel"); return nil
        }
        let saved = await model.saveLaunchSettings(shell: scratch.appendingPathComponent("bin/zsh").path, directory: scratch.path)
        XCTAssertTrue(saved)
        return model
    }

    @MainActor
    private func cleanUp(_ model: AppWorkspaceModel) {
        model.terminals.values.forEach {
            $0.requestTermination(force: true); $0.adapter.detach()
        }
    }

    private func writeFile(_ text: String, name: String = ProjectFile.fileName) throws {
        try FileManager.default.createDirectory(atPath: project + "/.trellis", withIntermediateDirectories: true)
        try text.write(toFile: project + "/.trellis/" + name, atomically: true, encoding: .utf8)
    }

    private func layout(command: String? = nil, title: String = "Dev") -> String {
        let commandField = command.map { #", "command": "\#($0)""# } ?? ""
        return """
            {"version": 1, "name": "Demo", "tabs": [
              {"title": "\(title)", "color": "green", "root": {"type": "split", "axis": "x", "ratio": 0.7, "children": [
                {"type": "pane", "title": "Code", "directory": "src"\(commandField)},
                {"type": "pane", "title": "Shell"}]}},
              {"title": "Logs", "root": {"type": "pane"}}]}
            """
    }

    @MainActor
    private func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    @MainActor
    private func text(_ model: AppWorkspaceModel, _ pane: UUID) -> String { (try? model.terminals[pane]?.adapter.read(.retainedText)) ?? "" }

    @MainActor
    private func window(_ model: AppWorkspaceModel, named name: String) throws -> ManagedWindow { try XCTUnwrap(model.snapshot.windows.first { $0.name == name }) }

    @MainActor
    private func panes(_ model: AppWorkspaceModel, _ window: ManagedWindow) -> [UUID] { window.tabIDs.flatMap { model.snapshot.tabs[$0]?.root.paneIDs ?? [] } }

    @MainActor
    private func prompt(_ model: AppWorkspaceModel, _ pane: UUID, _ directory: String?) throws {
        try XCTUnwrap(model.terminals[pane]).onShellIntegrationEvent?(.promptStart(directory: directory))
    }

    @MainActor
    func testOpenCreatesProjectWindowAndReopenReconcilesWithoutRestarting() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        try writeFile(layout())
        await model.loadProjectFile(root: project + "/.")
        XCTAssertNil(model.pendingProjectReview, "A file without commands needs no review")
        XCTAssertNil(model.errorMessage)
        let opened = try window(model, named: "Demo")
        XCTAssertEqual(model.snapshot.activeWindowID, opened.id)
        let tabs = opened.tabIDs.compactMap { model.snapshot.tabs[$0] }
        XCTAssertEqual(tabs.map(\.title), ["Dev", "Logs"])
        XCTAssertEqual(tabs.map(\.color), [.green, nil])
        guard case .split(_, .x, 0.7, _) = tabs[0].root else { return XCTFail("split expected: \(tabs[0].root)") }
        let ids = panes(model, opened)
        XCTAssertEqual(ids.map { model.snapshot.panes[$0]?.title }, ["Code", "Shell", nil])
        try await waitFor { ids.allSatisfy { model.snapshot.panes[$0].flatMap { model.snapshot.sessions[$0.sessionID] }?.state == .running } }
        try await waitFor { self.text(model, ids[0]).contains("PWD=src") }
        XCTAssertTrue(text(model, ids[0]).contains("PWD=src"), "The pane starts in the file's folder")
        let sessions = ids.compactMap { model.snapshot.panes[$0]?.sessionID }

        try writeFile(layout(title: "Develop"))
        await model.loadProjectFile(root: project)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.snapshot.windows.filter { $0.name == "Demo" }.count, 1, "Reopening reuses the project's window")
        let reopened = try window(model, named: "Demo")
        XCTAssertEqual(reopened.id, opened.id)
        XCTAssertEqual(model.snapshot.tabs[reopened.tabIDs[0]]?.title, "Develop")
        XCTAssertEqual(panes(model, reopened), ids)
        XCTAssertEqual(ids.compactMap { model.snapshot.panes[$0]?.sessionID }, sessions, "Nothing restarts")
        XCTAssertTrue(sessions.allSatisfy { model.snapshot.sessions[$0]?.state == .running })
    }

    @MainActor
    func testUntrustedCommandsWaitForReviewAndOpenWithoutCommandsTypesNothing() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        try writeFile(layout(command: "echo WF-MARKER"))
        let windows = model.snapshot.windows.count
        await model.loadProjectFile(root: project)
        let review = try XCTUnwrap(model.pendingProjectReview)
        XCTAssertEqual(review.file.entries.compactMap(\.pane.command), ["echo WF-MARKER"])
        XCTAssertFalse(review.changedSinceTrusted)
        XCTAssertEqual(model.snapshot.windows.count, windows, "Nothing opens before review")
        await model.resolveProjectReview(review.id, .openWithoutCommands)
        let pane = try XCTUnwrap(panes(model, try window(model, named: "Demo")).first)
        try await waitFor { self.text(model, pane).contains("SHELL-UP") }
        try prompt(model, pane, project + "/src")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(text(model, pane).contains("WF-MARKER"))
        XCTAssertNil(model.pendingProjectCommands[try XCTUnwrap(model.snapshot.panes[pane]).sessionID])
        await model.loadProjectFile(root: project)
        XCTAssertNotNil(model.pendingProjectReview, "Opening without commands trusts nothing")
    }

    @MainActor
    func testTrustedCommandRunsOnceAtFirstPromptAndChangesNeedReviewAgain() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        try writeFile(layout(command: "echo WF-MARKER"))
        await model.loadProjectFile(root: project)
        await model.resolveProjectReview(try XCTUnwrap(model.pendingProjectReview).id, .trustAndOpen)
        let opened = try window(model, named: "Demo")
        let pane = try XCTUnwrap(panes(model, opened).first)
        try await waitFor { self.text(model, pane).contains("SHELL-UP") }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(text(model, pane).contains("WF-MARKER"), "An integrated shell gets the command only at its first prompt")
        try prompt(model, pane, project + "/src")
        try await waitFor { self.text(model, pane).contains("WF-MARKER") }
        try prompt(model, pane, project + "/src")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(text(model, pane).components(separatedBy: "WF-MARKER").count - 1, 1, "Typed once")
        let trust = try String(contentsOf: scratch.appendingPathComponent("state/workspace-trust.json"), encoding: .utf8)
        XCTAssertFalse(trust.contains("WF-MARKER"), "Only the digest is stored")
        let attributes = try FileManager.default.attributesOfItem(atPath: scratch.appendingPathComponent("state/workspace-trust.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        await model.loadProjectFile(root: project)
        XCTAssertNil(model.pendingProjectReview, "The same bytes stay trusted")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(text(model, pane).components(separatedBy: "WF-MARKER").count - 1, 1, "Reopening never runs a command again")

        try writeFile(layout(command: "echo WF-MARKER "))
        await model.loadProjectFile(root: project)
        let review = try XCTUnwrap(model.pendingProjectReview, "A changed file needs a new review")
        XCTAssertTrue(review.changedSinceTrusted)
        await model.resolveProjectReview(review.id, .cancel)
        XCTAssertNil(model.pendingProjectReview)
    }

    @MainActor
    func testCommandWithoutShellIntegrationIsWrittenAtStart() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        model.setShellIntegrationEnabled(false)
        try writeFile(layout(command: "echo WF-PLAIN"))
        await model.loadProjectFile(root: project)
        await model.resolveProjectReview(try XCTUnwrap(model.pendingProjectReview).id, .trustAndOpen)
        let pane = try XCTUnwrap(panes(model, try window(model, named: "Demo")).first)
        try await waitFor { self.text(model, pane).contains("WF-PLAIN") }
        XCTAssertTrue(text(model, pane).contains("WF-PLAIN"))
        XCTAssertTrue(model.pendingProjectCommands.isEmpty)
    }

    @MainActor
    func testDetectionOffersOnTheTabAndNeverInTheProjectWindow() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        try writeFile(layout())
        await model.createWindow(name: "Scratch")
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        try prompt(model, tab.activePaneID, project + "/src")
        try await waitFor { model.projectFileOffer(tabID: tab.id) != nil }
        let offer = try XCTUnwrap(model.projectFileOffer(tabID: tab.id))
        XCTAssertEqual(offer.root, project)
        XCTAssertEqual(offer.name, "Demo")
        try prompt(model, tab.activePaneID, scratch.path)
        try await waitFor { model.projectFileOffer(tabID: tab.id) == nil }
        XCTAssertNil(model.projectFileOffer(tabID: tab.id), "Leaving the project clears the offer")

        // The offer's action opens the project's window; its own tabs never offer it again.
        try prompt(model, tab.activePaneID, project)
        try await waitFor { model.projectFileOffer(tabID: tab.id) != nil }
        await model.loadProjectFile(root: try XCTUnwrap(model.projectFileOffer(tabID: tab.id)).root)
        let projectWindow = try window(model, named: "Demo")
        let projectTab = try XCTUnwrap(model.snapshot.tabs[projectWindow.tabIDs[0]])
        try await waitFor { model.terminals[projectTab.activePaneID]?.sessionState == .running }
        try prompt(model, projectTab.activePaneID, project + "/src")
        try await waitFor { model.projectFileOffers[projectTab.activePaneID] != nil }
        XCTAssertNotNil(model.projectFileOffers[projectTab.activePaneID])
        XCTAssertNil(model.projectFileOffer(tabID: projectTab.id))
        XCTAssertNotNil(model.projectFileOffer(tabID: tab.id))

        model.stopOfferingProjectFile(root: project)
        XCTAssertNil(model.projectFileOffer(tabID: tab.id), "Don't Offer for This Folder hides it")

        // Closed panes leave no offer, lookup or queued state behind.
        let closed = tab.activePaneID
        await model.closeTab(tab.id)
        XCTAssertNil(model.snapshot.panes[closed])
        try prompt(model, projectTab.activePaneID, project)
        XCTAssertNil(model.projectFileOffers[closed])
        XCTAssertNil(model.projectFileLookups[closed])
    }

    @MainActor
    func testDetectionIgnoresSymbolicLinksAndNewerTrustListsStayUntouched() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        try FileManager.default.createDirectory(atPath: project + "/.trellis", withIntermediateDirectories: true)
        try layout().write(toFile: scratch.appendingPathComponent("elsewhere.json").path, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: project + "/.trellis/project.json", withDestinationPath: scratch.appendingPathComponent("elsewhere.json").path)
        // Nor does a linked project.json fall back to a regular legacy file beside it (FR-WF07).
        try writeFile(layout(), name: ProjectFile.legacyFileName)
        await model.createWindow(name: "Scratch")
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        try prompt(model, tab.activePaneID, project + "/src")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.projectFileOffer(tabID: tab.id), "A symbolic link is never offered")
        try FileManager.default.removeItem(atPath: project + "/.trellis/" + ProjectFile.legacyFileName)

        // A trust list from a newer Trellis is never rewritten, and trusts nothing.
        try FileManager.default.removeItem(atPath: project + "/.trellis/project.json")
        try writeFile(layout(command: "echo WF-MARKER"))
        let trustURL = scratch.appendingPathComponent("state/workspace-trust.json")
        let newer = Data(#"{"version":2,"trusted":[],"ignored":[]}"#.utf8)
        try newer.write(to: trustURL)
        await model.loadProjectFile(root: project)
        let review = try XCTUnwrap(model.pendingProjectReview)
        await model.resolveProjectReview(review.id, .trustAndOpen)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.snapshot.windows.first { $0.name == "Demo" })
        XCTAssertEqual(try Data(contentsOf: trustURL), newer)
    }

    @MainActor
    func testSaveWritesStableFileTrustsItAndBindsTheWindow() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        let created = await model.createWindow(name: "Mine")
        let windowID = try XCTUnwrap(created)
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        await model.renameTab(tab.id, title: "Work")
        await model.setTabColor(tab.id, color: .orange)
        let first = tab.activePaneID
        let split = await model.splitPane(first, axis: .y)
        let second = try XCTUnwrap(split)
        try await waitFor { [first, second].allSatisfy { model.terminals[$0]?.sessionState == .running } }
        try prompt(model, first, project + "/src")
        try prompt(model, second, project)
        var chosen: String?
        model.chooseProjectFolder = { _, directory in
            chosen = directory; return self.project
        }
        model.beginSaveProjectFile(windowID: windowID)
        XCTAssertEqual(chosen, project, "Without a file yet, the picker starts at the active pane's directory")
        var draft = try XCTUnwrap(model.pendingProjectSave)
        XCTAssertFalse(draft.replacesExisting)
        XCTAssertEqual(draft.warnings, [])
        XCTAssertEqual(draft.commands.count, 2)
        draft.commands[0] = "make watch"
        XCTAssertTrue(model.writeProjectFile(draft))
        XCTAssertNil(model.pendingProjectSave)
        let data = try Data(contentsOf: URL(fileURLWithPath: project + "/.trellis/project.json"))
        let file = try ProjectFileJSON.parse(data).get()
        XCTAssertEqual(file.name, "Mine")
        XCTAssertEqual(file.tabs.map(\.title), ["Work"])
        XCTAssertEqual(file.tabs.map(\.color), [.orange])
        XCTAssertEqual(file.entries.map(\.pane.directory), ["src", nil])
        XCTAssertEqual(file.entries.map(\.pane.command), ["make watch", nil])

        // Saving again keeps the command and writes the same bytes.
        model.beginSaveProjectFile(windowID: windowID)
        let again = try XCTUnwrap(model.pendingProjectSave)
        XCTAssertTrue(again.replacesExisting)
        XCTAssertEqual(again.commands, ["make watch", ""])
        XCTAssertTrue(model.writeProjectFile(again))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: project + "/.trellis/project.json")), data)
        // After a relaunch (no runtime commands), the existing file's commands carry over through the bindings.
        model.projectFileCommands = [:]
        XCTAssertEqual(try model.projectFileDraft(windowID: windowID, root: project).commands, ["make watch", ""])

        // The saved window is the project's window: opening the file selects it, with no review and nothing new.
        let windows = model.snapshot.windows.count, paneCount = model.snapshot.panes.count
        await model.createWindow(name: "Elsewhere")
        await model.loadProjectFile(root: project)
        XCTAssertNil(model.pendingProjectReview)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.snapshot.activeWindowID, windowID)
        XCTAssertEqual(model.snapshot.windows.count, windows + 1)
        XCTAssertEqual(model.snapshot.panes.count, paneCount + 1)
        XCTAssertNil(model.projectFileOffer(tabID: tab.id))
    }

    @MainActor
    func testSaveThroughSymlinkedFolderKeepsPaneDirectories() async throws {
        let link = scratch.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: project)
        let model = try await makeModel()
        defer { cleanUp(model) }
        let created = await model.createWindow(name: "Linked")
        let windowID = try XCTUnwrap(created)
        let first = try XCTUnwrap(model.presentation.selectedTab).activePaneID
        let split = await model.splitPane(first, axis: .y)
        let second = try XCTUnwrap(split)
        try await waitFor { [first, second].allSatisfy { model.terminals[$0]?.sessionState == .running } }
        // A shell's $PWD keeps the logical path through the link; the root is canonical.
        try prompt(model, first, link + "/src")
        try prompt(model, second, link)
        let draft = try model.projectFileDraft(windowID: windowID, root: link)
        XCTAssertEqual(draft.root, project)
        XCTAssertEqual(draft.warnings, [])
        XCTAssertEqual(draft.file.entries.map(\.pane.directory), ["src", nil])
        XCTAssertTrue(model.writeProjectFile(draft))
    }

    @MainActor
    func testSaveNeverWritesThroughALinkedTrellisFolder() async throws {
        let elsewhere = scratch.appendingPathComponent("elsewhere").path
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: project + "/.trellis", withDestinationPath: elsewhere)
        let model = try await makeModel()
        defer { cleanUp(model) }
        let created = await model.createWindow(name: "Linked")
        let windowID = try XCTUnwrap(created)
        let draft = try model.projectFileDraft(windowID: windowID, root: project)
        XCTAssertFalse(model.writeProjectFile(draft))
        XCTAssertTrue(model.errorMessage?.contains("symbolic link") == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere), [])
    }

    @MainActor
    func testSaveKeepsALinkedFolderInsideTheProject() async throws {
        let outside = scratch.appendingPathComponent("vendored").path
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: project + "/vendor", withDestinationPath: outside)
        let model = try await makeModel()
        defer { cleanUp(model) }
        let created = await model.createWindow(name: "Vendor")
        let windowID = try XCTUnwrap(created)
        let pane = try XCTUnwrap(model.presentation.selectedTab).activePaneID
        try await waitFor { model.terminals[pane]?.sessionState == .running }
        // The shell is in the project's linked folder: it stays there rather than resolving outside the project.
        try prompt(model, pane, project + "/vendor")
        let draft = try model.projectFileDraft(windowID: windowID, root: project)
        XCTAssertEqual(draft.warnings, [])
        XCTAssertEqual(draft.file.entries.map(\.pane.directory), ["vendor"])
    }

    @MainActor
    func testSaveFailureAndCorruptTrustLeaveEverythingAsItWas() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        let created = await model.createWindow(name: "Mine")
        let windowID = try XCTUnwrap(created)
        // `.trellis` is a file, so the project file can't be written.
        try Data("x".utf8).write(to: URL(fileURLWithPath: project + "/.trellis"))
        var draft = try model.projectFileDraft(windowID: windowID, root: project)
        draft.commands[0] = "make"
        XCTAssertFalse(model.writeProjectFile(draft))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try String(contentsOfFile: project + "/.trellis", encoding: .utf8), "x")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("state/workspace-trust.json").path))
        model.errorMessage = nil

        // A command that isn't one line is refused before anything is written.
        try FileManager.default.removeItem(atPath: project + "/.trellis")
        draft.commands[0] = "a\u{202E}b"
        XCTAssertFalse(model.writeProjectFile(draft))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project + "/.trellis/project.json"))
        model.errorMessage = nil

        // An unreadable trust list trusts nothing and is never overwritten.
        let trustURL = scratch.appendingPathComponent("state/workspace-trust.json")
        try Data("not json".utf8).write(to: trustURL)
        try writeFile(layout(command: "echo WF-MARKER"))
        let windows = model.snapshot.windows.count
        await model.loadProjectFile(root: project)
        let review = try XCTUnwrap(model.pendingProjectReview)
        await model.resolveProjectReview(review.id, .trustAndOpen)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.snapshot.windows.count, windows)
        XCTAssertEqual(try Data(contentsOf: trustURL), Data("not json".utf8))
    }

    @MainActor
    func testLegacyWorkspaceJSONIsStillReadAndSavingWritesProjectJSON() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        let legacy = project + "/.trellis/workspace.json", current = project + "/.trellis/project.json"
        try writeFile(layout(command: "echo WF-MARKER"), name: ProjectFile.legacyFileName)
        await model.createWindow(name: "Scratch")
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        try prompt(model, tab.activePaneID, project + "/src")
        try await waitFor { model.projectFileOffer(tabID: tab.id) != nil }
        XCTAssertEqual(model.projectFileOffer(tabID: tab.id)?.path, legacy, "A project with only the old file is still offered")

        await model.loadProjectFile(root: project)
        let review = try XCTUnwrap(model.pendingProjectReview)
        XCTAssertEqual(review.path, legacy, "The review names the file that was read")
        await model.resolveProjectReview(review.id, .trustAndOpen)
        let opened = try window(model, named: "Demo")

        // Renaming the file keeps its bytes, so it stays trusted and reopens the same window.
        try FileManager.default.moveItem(atPath: legacy, toPath: current)
        await model.loadProjectFile(root: project)
        XCTAssertNil(model.pendingProjectReview, "The same bytes under the new name stay trusted")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.snapshot.windows.filter { $0.name == "Demo" }.map(\.id), [opened.id])

        // With both files, project.json wins: a broken legacy file is never read.
        try writeFile("not json", name: ProjectFile.legacyFileName)
        await model.loadProjectFile(root: project)
        XCTAssertNil(model.errorMessage)

        // Saving writes project.json, warns about the old file and never touches it.
        try FileManager.default.removeItem(atPath: current)
        model.chooseProjectFolder = { _, _ in self.project }
        try writeFile(layout(command: "echo WF-MARKER"), name: ProjectFile.legacyFileName)
        model.beginSaveProjectFile(windowID: opened.id)
        let draft = try XCTUnwrap(model.pendingProjectSave)
        XCTAssertEqual(draft.path, current)
        XCTAssertFalse(draft.replacesExisting)
        XCTAssertEqual(draft.commands.first, "echo WF-MARKER", "Commands carry over from the old file")
        XCTAssertTrue(draft.warnings.contains { $0.contains("workspace.json is no longer used") }, "\(draft.warnings)")
        let before = try Data(contentsOf: URL(fileURLWithPath: legacy))
        XCTAssertTrue(model.writeProjectFile(draft))
        XCTAssertNoThrow(try ProjectFileJSON.parse(Data(contentsOf: URL(fileURLWithPath: current))).get())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: legacy)), before)
    }

    @MainActor
    func testInvalidOrUnsafeFilesAreRefusedWithoutChanges() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        let before = model.snapshot
        await model.loadProjectFile(root: project)
        XCTAssertNotNil(model.errorMessage, "No file")
        model.errorMessage = nil
        try writeFile(#"{"version": 1, "name": "Bad", "tabs": [{"title": "T", "root": {"type": "pane", "directory": "../outside"}}]}"#)
        await model.loadProjectFile(root: project)
        XCTAssertTrue(model.errorMessage?.contains("relative to the project folder") == true, model.errorMessage ?? "")
        model.errorMessage = nil
        // A symbolic link could point anywhere; only a regular file in the project is read.
        try FileManager.default.removeItem(atPath: project + "/.trellis/project.json")
        try layout().write(toFile: scratch.appendingPathComponent("elsewhere.json").path, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: project + "/.trellis/project.json", withDestinationPath: scratch.appendingPathComponent("elsewhere.json").path)
        await model.loadProjectFile(root: project)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.snapshot, before)
        // A linked (or dangling) project.json is refused, never skipped in favour of a valid legacy file (FR-WF07).
        model.errorMessage = nil
        try writeFile(layout(), name: ProjectFile.legacyFileName)
        await model.loadProjectFile(root: project)
        XCTAssertTrue(model.errorMessage?.contains("symbolic link") == true, model.errorMessage ?? "")
        XCTAssertEqual(model.snapshot, before)
        model.errorMessage = nil
        try FileManager.default.removeItem(atPath: scratch.appendingPathComponent("elsewhere.json").path)
        await model.loadProjectFile(root: project)
        XCTAssertTrue(model.errorMessage?.contains("symbolic link") == true, model.errorMessage ?? "")
        XCTAssertEqual(model.snapshot, before)
        XCTAssertEqual(ProjectFilePanels.projectRoot(forSelection: project + "/.trellis/project.json"), project)
        XCTAssertEqual(ProjectFilePanels.projectRoot(forSelection: project + "/.trellis/workspace.json"), project)
        XCTAssertEqual(ProjectFilePanels.projectRoot(forSelection: project + "/.trellis"), project)
        XCTAssertEqual(ProjectFilePanels.projectRoot(forSelection: project), project)
    }
}
