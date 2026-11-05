import AppKit
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// The tool dock's model (FR-TD01–FR-TD15) with a real pane running the fake echoing `zsh` of `ScratchpadTests`.
final class ToolDockTests: XCTestCase {
    private var scratch: URL!
    private var project: String!
    private var shell: String!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-td-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let manager = FileManager.default
        try manager.createDirectory(at: scratch.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try manager.createDirectory(at: scratch.appendingPathComponent("state"), withIntermediateDirectories: true)
        try manager.createDirectory(at: scratch.appendingPathComponent("project/.git"), withIntermediateDirectories: true)
        try manager.createDirectory(at: scratch.appendingPathComponent("project/Sources"), withIntermediateDirectories: true)
        project = scratch.appendingPathComponent("project").path
        shell = scratch.appendingPathComponent("bin/zsh").path
        try "#!/bin/sh\n/bin/stty raw -echo\nprintf 'SHELL-UP\\n'\nexec /bin/cat -uv\n".write(toFile: shell, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    @MainActor
    private func makeModel() async throws -> (AppWorkspaceModel, UUID) {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-td-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        _ = await model.loadWorkspace()
        model.confirmCloseSessions = { _ in true }
        model.confirmUnsavedEdits = { _ in
            XCTFail("Unexpected unsaved-edits prompt"); return .cancel
        }
        model.editorFileWatcher = { _, _ in nil }
        let saved = await model.saveLaunchSettings(shell: shell, directory: project)
        XCTAssertTrue(saved)
        _ = await model.createWindow(name: "W")
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        try await waitFor { self.text(model, pane).contains("SHELL-UP") }
        try XCTUnwrap(model.terminals[pane]).onShellIntegrationEvent?(.promptStart(directory: project + "/Sources"))
        return (model, pane)
    }

    @MainActor
    private func cleanUp(_ model: AppWorkspaceModel) {
        model.terminals.values.forEach {
            $0.requestTermination(force: true); $0.adapter.detach()
        }
    }

    @MainActor
    private func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    @MainActor
    private func text(_ model: AppWorkspaceModel, _ pane: UUID) -> String { (try? model.terminals[pane]?.adapter.read(.retainedText)) ?? "" }

    private func write(_ relative: String, _ text: String) throws -> String {
        let path = project + "/" + relative
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @MainActor
    func testEachTabHasItsOwnDockAndTheRailButtonTogglesIt() async throws {
        let (model, _) = try await makeModel()
        defer { cleanUp(model) }
        let first = try XCTUnwrap(model.presentation.selectedTab?.id)
        model.toggleToolDock(.files)
        XCTAssertTrue(model.toolDock(first).isOpen)
        let created = await model.createTab()
        let second = try XCTUnwrap(created)
        await model.selectTab(second)
        XCTAssertFalse(model.selectedToolDock.isOpen, "A new tab starts with the dock closed")
        await model.selectTab(first)
        XCTAssertTrue(model.selectedToolDock.isOpen, "Switching back shows the dock as it was left")
        model.toggleToolDock(.files)
        XCTAssertFalse(model.toolDock(first).isOpen)
        await model.closeTab(second)
        XCTAssertNil(model.toolDocks[second], "A closed tab's dock goes with it")
    }

    @MainActor
    func testTheTreeFollowsTheFocusedPanesProject() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        let tab = try XCTUnwrap(model.presentation.selectedTab?.id)
        guard case .project(let root, _) = model.toolDockContext(tab) else { return XCTFail("\(model.toolDockContext(tab))") }
        XCTAssertEqual(root, project, "The git work tree, not the pane's subfolder")
        try XCTUnwrap(model.terminals[pane]).onShellIntegrationEvent?(.promptStart(directory: NSHomeDirectory()))
        if case .notAProject = model.toolDockContext(tab) {} else { XCTFail("Home is never a root: \(model.toolDockContext(tab))") }
    }

    @MainActor
    func testOpenEditSaveAndAChangeOnDisk() async throws {
        let (model, _) = try await makeModel()
        defer { cleanUp(model) }
        let tab = try XCTUnwrap(model.presentation.selectedTab?.id)
        let path = try write("Sources/App.swift", "let a = 1\n")
        XCTAssertTrue(model.openFileInToolDock(path, line: 1))
        let state = model.toolDock(tab)
        XCTAssertTrue(state.isOpen)
        XCTAssertEqual(state.activeFile, path)
        XCTAssertEqual(state.markedLines[path], 1)
        let buffer = try XCTUnwrap(model.buffer(tab, path))
        buffer.text = "let a = 2\n"
        XCTAssertTrue(buffer.isDirty)
        XCTAssertTrue(model.saveFile(path, tabID: tab))
        XCTAssertFalse(buffer.isDirty)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "let a = 2\n")

        // A clean buffer follows the file on disk.
        _ = try write("Sources/App.swift", "let a = 3 // agent\n")
        model.checkFileOnDisk(path, tabID: tab)
        XCTAssertEqual(buffer.text, "let a = 3 // agent\n")
        // An edited one asks, and saving never silently overwrites.
        buffer.text = "let a = 4\n"
        _ = try write("Sources/App.swift", "let a = 5 // agent again\n")
        model.checkFileOnDisk(path, tabID: tab)
        XCTAssertEqual(buffer.conflict, .changedWhileEditing)
        model.keepEdits(path, tabID: tab)
        XCTAssertFalse(model.saveFile(path, tabID: tab))
        XCTAssertEqual(buffer.conflict, .saveWouldOverwrite)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "let a = 5 // agent again\n")
        XCTAssertTrue(model.saveFile(path, tabID: tab, overwrite: true))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "let a = 4\n")
    }

    @MainActor
    func testAFileTheEditorCantOpenSaysWhyAndChangesNothing() async throws {
        let (model, _) = try await makeModel()
        defer { cleanUp(model) }
        let tab = try XCTUnwrap(model.presentation.selectedTab?.id)
        let binary = project + "/logo.png"
        try Data([0x89, 0x50, 0x00, 0x01]).write(to: URL(fileURLWithPath: binary))
        XCTAssertFalse(model.openFileInToolDock(binary))
        XCTAssertEqual(model.toolDock(tab).openFailure?.message, "Binary file.")
        XCTAssertTrue(model.toolDock(tab).openFiles.isEmpty)
    }

    @MainActor
    func testUnsavedEditsAskBeforeAFileOrTabCloses() async throws {
        let (model, _) = try await makeModel()
        defer { cleanUp(model) }
        let tab = try XCTUnwrap(model.presentation.selectedTab?.id)
        let other = await model.createTab()
        XCTAssertNotNil(other)
        await model.selectTab(tab)
        let path = try write("notes.md", "# Notes\n")
        model.openFileInToolDock(path)
        try XCTUnwrap(model.buffer(tab, path)).text = "# Notes\nmore\n"
        var asked: [[String]] = []
        model.confirmUnsavedEdits = {
            asked.append($0); return .cancel
        }
        XCTAssertFalse(model.closeFile(path, tabID: tab))
        await model.closeTab(tab)
        XCTAssertNotNil(model.snapshot.tabs[tab], "Cancel keeps the tab")
        XCTAssertEqual(model.confirmQuit(), .cancel, "Quitting asks too")
        XCTAssertEqual(asked, [["notes.md"], ["notes.md"], ["notes.md"]])
        model.confirmUnsavedEdits = { _ in .save }
        await model.closeTab(tab)
        XCTAssertNil(model.snapshot.tabs[tab])
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "# Notes\nmore\n", "Save writes before the tab closes")
    }

    @MainActor
    func testFileLinksOpenTextFilesInTheDockAtTheirLine() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        let tab = try XCTUnwrap(model.presentation.selectedTab?.id)
        let path = try write("Sources/Link.swift", "a\nb\nc\n")
        XCTAssertTrue(model.openLinkedFile(path, line: 3, paneID: pane))
        XCTAssertEqual(model.toolDock(tab).markedLines[path], 3)
        let image = project + "/image.bin"
        try Data([0, 1, 2]).write(to: URL(fileURLWithPath: image))
        XCTAssertFalse(model.openLinkedFile(image, line: nil, paneID: pane), "What the editor can't open goes to the default app")
        var settings = model.appearance
        settings.fileLinkTarget = .defaultApp
        XCTAssertTrue(model.applyAppearance(settings))
        XCTAssertFalse(model.openLinkedFile(path, line: nil, paneID: pane), "The Default app setting sends every file there")
    }

    @MainActor
    func testInsertPathTypesAQuotedPathWithoutReturn() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        XCTAssertNil(model.insertPathBlockedReason)
        XCTAssertTrue(model.insertPath(project + "/Sources/My File.swift"))
        try await waitFor { self.text(model, pane).contains("'My File.swift' ") }
        XCTAssertTrue(text(model, pane).contains("'My File.swift' "))
        XCTAssertFalse(text(model, pane).contains("^M"), "No Return")
        XCTAssertEqual(AppWorkspaceModel.insertedPath("/Users/me/code/a.swift", directory: "/tmp", home: "/Users/me"), "~/code/a.swift")
        XCTAssertEqual(AppWorkspaceModel.insertedPath("/opt/x y", directory: "/tmp", home: "/Users/me"), "'/opt/x y'")
    }

    func testTheDockFloatsOnlyWhenDockingWouldShrinkAPaneBelowItsMinimum() {
        XCTAssertFalse(ToolDockLayout.floats(availableWidth: 1278, dockWidth: 760, minimumCanvasWidth: 321))
        XCTAssertTrue(ToolDockLayout.floats(availableWidth: 1278, dockWidth: 760, minimumCanvasWidth: 643))
        XCTAssertEqual(ToolDockLayout.clamped(100, availableWidth: 1000), 260)
        XCTAssertEqual(ToolDockLayout.clamped(900, availableWidth: 1000), 700)
    }
}
