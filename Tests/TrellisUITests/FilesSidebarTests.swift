import AppKit
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// The sidebar's Files view (FR-FB01–FR-FB06) at the model level: a real shell pane in a temporary project, with apps,
/// Finder and the pasteboard injected so nothing outside the test is touched.
final class FilesSidebarTests: XCTestCase {
    private var scratch: URL!
    private var project: String!
    private var shell: String!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-fb-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let manager = FileManager.default
        project = scratch.appendingPathComponent("project").path
        for folder in ["bin", "state", "project/.git", "project/Sources/Deep", "project/.hidden", "other"] {
            try manager.createDirectory(at: scratch.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["project/README.md", "project/Sources/App.swift", "project/Sources/Deep/Inner.swift", "project/notes.log", "other/x.txt"] {
            try "x".write(to: scratch.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try "*.log\n".write(to: scratch.appendingPathComponent("project/.gitignore"), atomically: true, encoding: .utf8)
        shell = scratch.appendingPathComponent("bin/sh").path
        try "#!/bin/sh\nprintf 'SHELL-UP\\n'\n[ \"$2\" = -c ] && exec /bin/sh -c \"$3\"\nexec /bin/cat\n".write(toFile: shell, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private final class Recorder: @unchecked Sendable {
        var opened: [(URL, URL?)] = []
        var revealed: [[URL]] = []
        var copied: [String] = []
    }

    @MainActor
    private func makeModel(directory: String? = nil) async throws -> (AppWorkspaceModel, UUID, Recorder, UserDefaults) {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-fb-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        _ = await model.loadWorkspace()
        model.confirmCloseSessions = { _ in true }
        model.workspaceIsFrontmost = { true }
        let recorder = Recorder()
        model.openFileInApp = { recorder.opened.append(($0, $1)) }
        model.revealFiles = { recorder.revealed.append($0) }
        model.copyToPasteboard = { recorder.copied.append($0) }
        model.applicationURL = { $0 == "com.microsoft.VSCode" ? URL(fileURLWithPath: "/Applications/Visual Studio Code.app") : nil }
        let saved = await model.saveLaunchSettings(shell: shell, directory: directory ?? project + "/Sources")
        XCTAssertTrue(saved)
        _ = await model.createSpace(name: "W")
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        try await waitFor { self.text(model, pane).contains("SHELL-UP") }
        return (model, pane, recorder, preferences)
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

    @MainActor
    func testFilesIsADockViewThatFocusesSearchAndIsLocalOnly() async throws {
        let (model, local, _, _) = try await makeModel()
        defer { cleanUp(model) }
        XCTAssertEqual(SidebarView.allCases.first, .files, "Files is the first dock icon")
        XCTAssertEqual(SidebarView(shortcut: .toggleFiles), .files)
        XCTAssertNil(model.sidebarUnavailableReason(.files))
        let before = model.snapshot
        let request = model.filesFocusRequest
        model.toggleSidebarView(.files)
        XCTAssertEqual(model.visibleSidebarView, .files)
        XCTAssertEqual(model.filesFocusRequest, request + 1, "Showing Files focuses its search field")

        XCTAssertEqual(model.snapshot, before, "Showing Files is never a workspace change")

        let created = try await model.service.execute(.createRemoteSpace(name: "Remote", hostID: UUID()))
        let remoteSpace = try XCTUnwrap(created.snapshot.spaces.last)
        let remote = try XCTUnwrap(created.snapshot.tabs[remoteSpace.activeTabID]?.activePaneID)
        model.publish(try await model.service.execute(.configureStoppedSession(paneID: remote, launch: .remoteShell(hostID: remoteSpace.remoteHostID!, directory: "/srv/app"))).snapshot)
        await model.selectSpace(remoteSpace.id)
        XCTAssertEqual(model.presentation.activePane?.id, remote)
        XCTAssertEqual(model.sidebarUnavailableReason(.files), "Files shows only folders on this Mac.")
        XCTAssertNil(model.sidebarUnavailableReason(.tasks), "Tasks still works there")
        XCTAssertNil(model.visibleSidebarView, "Files hides on a remote workspace pane")
        await model.refreshFiles(paneID: remote)
        XCTAssertNil(model.files.root, "Nothing is listed for a remote pane")

        await model.selectSpace(try XCTUnwrap(model.snapshot.spaces.first?.id))
        XCTAssertEqual(model.presentation.activePane?.id, local)
        XCTAssertEqual(model.visibleSidebarView, .files, "and comes back with focus")
        model.toggleSidebarView(.files)
        XCTAssertNil(model.visibleSidebarView)
    }

    @MainActor
    func testTheTreeIsRootedAtTheProjectAndListsFoldersOnDemand() async throws {
        let (model, pane, _, _) = try await makeModel()
        defer { cleanUp(model) }
        await model.refreshFiles(paneID: pane)
        XCTAssertEqual(model.files.root, project, "A pane in Sources shows its whole project (the folder with .git)")
        XCTAssertEqual(model.files.rows.map(\.entry.name), ["Sources", "README.md"], "Folders first; .git, hidden and .gitignore'd files are left out")

        await model.toggleFilesFolder(project + "/Sources")
        XCTAssertEqual(model.files.rows.map(\.entry.name), ["Sources", "Deep", "App.swift", "README.md"])
        XCTAssertEqual(model.files.rows.map(\.depth), [0, 1, 1, 0])
        XCTAssertEqual(model.files.selection, project + "/Sources")
        model.moveFilesSelection(by: 2)
        XCTAssertEqual(model.files.selectedEntry?.name, "App.swift")
        model.moveFilesSelection(by: 10)
        XCTAssertEqual(model.files.selectedEntry?.name, "README.md", "Moving stops at the last entry")

        await model.setFilesShowHidden(true)
        XCTAssertTrue(model.files.rows.map(\.entry.name).contains(".hidden"))
        XCTAssertFalse(model.files.rows.map(\.entry.name).contains(".git"), ".git never shows")
        XCTAssertTrue(model.files.rows.map(\.entry.name).contains("App.swift"), "Open folders stay open")

        try FileManager.default.removeItem(atPath: project + "/Sources/Deep")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: project + "/Sources")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project + "/Sources") }
        await model.refreshFiles(paneID: pane)
        XCTAssertEqual(model.files.rows.filter(\.unreadable).map(\.entry.path), [project + "/Sources"], "An unreadable folder shows a note")
        XCTAssertTrue(model.files.rows.contains { $0.entry.name == "README.md" }, "and the rest of the tree stays")

        model.collapseAllFilesFolders()
        XCTAssertTrue(model.files.expanded.isEmpty)
    }

    @MainActor
    func testAPaneOutsideAProjectShowsItsOwnFolder() async throws {
        let (model, pane, _, _) = try await makeModel(directory: scratch.appendingPathComponent("other").path)
        defer { cleanUp(model) }
        await model.refreshFiles(paneID: pane)
        XCTAssertEqual(model.files.root, scratch.appendingPathComponent("other").path)
        XCTAssertEqual(model.files.rows.map(\.entry.name), ["x.txt"])
    }

    @MainActor
    func testSearchFindsFilesAcrossTheProjectAndSelectsTheBest() async throws {
        let (model, pane, _, _) = try await makeModel()
        defer { cleanUp(model) }
        await model.refreshFiles(paneID: pane)
        model.setFilesQuery("inner")
        await model.waitForFilesSearch()
        XCTAssertEqual(model.files.search?.matches.map(\.entry.name), ["Inner.swift"], "Search reaches folders that were never opened")
        XCTAssertEqual(model.files.search?.matches.first?.relativeFolder, "Sources/Deep")
        XCTAssertEqual(model.files.selectedEntry?.name, "Inner.swift", "The best match is selected, so Return opens it")
        model.setFilesQuery("notes")
        await model.waitForFilesSearch()
        XCTAssertEqual(model.files.search?.matches, [], ".gitignore'd files aren't found")
        model.setFilesQuery("")
        XCTAssertNil(model.files.search, "Clearing the query shows the tree again")
        XCTAssertFalse(model.files.searching)
    }

    @MainActor
    func testOpenInUsesTheRememberedEditorAndFinderReveals() async throws {
        let (model, pane, recorder, preferences) = try await makeModel()
        defer { cleanUp(model) }
        await model.refreshFiles(paneID: pane)
        XCTAssertEqual(model.files.editors.map(\.id), ["trellis-editor", "finder", "vscode", "default", "trellis-tab"], "Only installed editors are offered")
        XCTAssertEqual(model.files.editor, .trellisEditor, "Trellis Editor until another is chosen (FR-ED09)")
        let readme = FileEntry(path: project + "/README.md", isDirectory: false)

        await model.openFile(readme)
        XCTAssertEqual(model.shownEditor?.document.path, readme.path, "The default opens an editor tab")
        XCTAssertTrue(recorder.opened.isEmpty && recorder.revealed.isEmpty, "Nothing leaves Trellis")
        await model.openFile(readme, in: .finder)
        XCTAssertEqual(recorder.revealed, [[URL(fileURLWithPath: readme.path)]], "Finder reveals a file")
        await model.openFile(nil)
        XCTAssertEqual(recorder.opened.last?.0.path, project, "No selection opens the project folder")
        XCTAssertNil(recorder.opened.last?.1)

        let vscode = try XCTUnwrap(EditorApp.with(id: "vscode"))
        await model.openFile(readme, in: vscode)
        XCTAssertEqual(recorder.opened.last?.0.path, readme.path)
        XCTAssertEqual(recorder.opened.last?.1?.lastPathComponent, "Visual Studio Code.app")
        XCTAssertEqual(model.files.editor.id, "vscode", "Choosing an editor remembers it")
        XCTAssertEqual(preferences.string(forKey: "files.editor"), "vscode")
        await model.openFile(readme)
        XCTAssertEqual(recorder.opened.count, 3, "The main button now opens in VS Code")

        await model.openFile(readme, in: try XCTUnwrap(EditorApp.with(id: "xcode")))
        XCTAssertEqual(model.errorMessage, "Xcode isn't installed on this Mac.")
        XCTAssertEqual(recorder.opened.count, 3, "Nothing opens with a missing app")

        let tabs = model.snapshot.tabs.count
        await model.openFile(readme, in: .newTab)
        XCTAssertEqual(model.snapshot.tabs.count, tabs + 1, "New Tab Here opens a tab in the file's folder")
        let newPane = try XCTUnwrap(model.presentation.activePane?.id)
        XCTAssertEqual(model.paneDirectory(newPane), project)
    }

    @MainActor
    func testFinderAndDefaultAppNeverRunAnythingFromTheTree() async throws {
        let (model, pane, recorder, _) = try await makeModel()
        defer { cleanUp(model) }
        await model.refreshFiles(paneID: pane)
        let bundle = project + "/Tool.app", script = project + "/run.command", readme = project + "/README.md"
        try FileManager.default.createDirectory(atPath: bundle + "/Contents", withIntermediateDirectories: true)
        try "#!/bin/sh\necho hi\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)

        await model.openFile(FileEntry(path: bundle, isDirectory: true), in: .finder)
        XCTAssertEqual(recorder.opened.count, 0, "Finder doesn't open an app bundle, which would launch it")
        XCTAssertEqual(recorder.revealed.last?.map(\.path), [bundle])
        await model.openFile(FileEntry(path: script, isDirectory: false), in: .defaultApp)
        XCTAssertEqual(recorder.opened.count, 0, "Default App never runs a script")
        XCTAssertEqual(recorder.revealed.last?.map(\.path), [script])
        await model.openFile(FileEntry(path: readme, isDirectory: false), in: .defaultApp)
        XCTAssertEqual(recorder.opened.last?.0.path, readme, "A plain file opens in its default app")
        XCTAssertNil(recorder.opened.last?.1)
    }

    @MainActor
    func testCopyPathAndInsertPathInTerminal() async throws {
        let (model, pane, recorder, _) = try await makeModel()
        defer { cleanUp(model) }
        await model.refreshFiles(paneID: pane)
        let app = FileEntry(path: project + "/Sources/App.swift", isDirectory: false)
        model.copyFilePath(app)
        model.copyFilePath(app, style: .relative)
        model.copyFilePath(app, style: .name)
        XCTAssertEqual(recorder.copied, [app.path, "Sources/App.swift", "App.swift"])
        XCTAssertEqual(model.files.status, "Copied App.swift", "A short confirmation names what was copied")

        let quoted = FileEntry(path: project + "/it's here.txt", isDirectory: false)
        model.insertFilePath(quoted)
        try await waitFor { self.text(model, pane).contains("it'\\''s here.txt") }
        XCTAssertTrue(text(model, pane).contains("'" + project + "/it'\\''s here.txt'"), "The path is quoted for the shell, like a dropped file")
        XCTAssertFalse(text(model, pane).contains("\r'"), "Nothing runs: no Return is sent")
    }
}
