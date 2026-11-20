import AppKit
import XCTest
import TrellisCore
@testable import TrellisUI

/// The Files view on a remote workspace pane (FR-FB09) and the read-only editor tab its files open in (FR-ED16), at the
/// model level: the host's files are a temporary folder behind an injected ``RemoteFileAccess``, so no link is needed.
@MainActor
final class RemoteFilesSidebarTests: XCTestCase {
    /// A "host" whose disk is a folder on this Mac; it records what was asked of it.
    private final class Host: RemoteFileAccess, @unchecked Sendable {
        let home: String
        private let lock = NSLock()
        private var _browses = true, _asked: [[String]] = [], _truncated: Set<String> = []
        init(home: String) { self.home = home }
        var browses: Bool {
            get { lock.withLock { _browses } }
            set { lock.withLock { _browses = newValue } }
        }
        var asked: [[String]] { lock.withLock { _asked } }
        var truncated: Set<String> {
            get { lock.withLock { _truncated } }
            set { lock.withLock { _truncated = newValue } }
        }

        func projectRoot(containing directory: String) async -> String {
            ProjectLocator.taskRoot(containing: directory, home: home, exists: { FileManager.default.fileExists(atPath: $0) }) ?? directory
        }

        func contents(of directories: [String]) async -> [String: FolderListing] {
            lock.withLock { _asked.append(directories) }
            let cut = truncated
            return Dictionary(uniqueKeysWithValues: directories.map { path in (path, (try? LocalFileListing().contents(of: path)).map { .entries($0, truncated: cut.contains(path)) } ?? .unreadable) })
        }

        func read(_ path: String, limit: Int) async -> Result<RemoteFileContents, RemoteFileFailure> {
            var folder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &folder) else { return .failure(.missing) }
            guard !folder.boolValue, let data = FileManager.default.contents(atPath: path) else { return .failure(.notAFile) }
            guard data.count <= limit else { return .failure(.tooLarge) }
            return .success(RemoteFileContents(data: data, stamp: EditorDiskStamp(modified: 1, size: Int64(data.count))))
        }
    }

    private var scratch: URL!
    private var project = ""
    private var saved: SavedHost!

    override func setUp() async throws {
        _ = NSApplication.shared
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-rf-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        project = scratch.appendingPathComponent("home/project").path
        for folder in ["state", "home/project/.git", "home/project/Sources/Deep", "home/project/.hidden"] {
            try FileManager.default.createDirectory(at: scratch.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["home/project/README.md", "home/project/Sources/App.swift", "home/project/Sources/Deep/Inner.swift", "home/project/notes.log"] {
            try "host text\n".write(to: scratch.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try "*.log\n".write(to: scratch.appendingPathComponent("home/project/.gitignore"), atomically: true, encoding: .utf8)
        try Data([0x7f, 0x45, 0x4c, 0x46, 0, 1, 2]).write(to: scratch.appendingPathComponent("home/project/tool.bin"))
        saved = SavedHost(id: UUID(), draft: try HostDraft(name: "build-box", destination: "build-box").validated { _ in false }, revision: 1)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    private final class Recorder: @unchecked Sendable {
        var opened: [URL] = [], revealed: [[URL]] = [], copied: [String] = []
    }

    /// A model whose focused pane is a remote workspace pane in the project's `Sources` folder on the host; nothing runs.
    private func makeModel(connected: Bool = true) async throws -> (AppWorkspaceModel, UUID, Host, Recorder) {
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-rf-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        _ = await model.loadWorkspace()
        let recorder = Recorder()
        model.openFileInApp = { url, _ in recorder.opened.append(url) }
        model.revealFiles = { recorder.revealed.append($0) }
        model.copyToPasteboard = { recorder.copied.append($0) }
        model.applicationURL = { $0 == "com.microsoft.VSCode" ? URL(fileURLWithPath: "/Applications/Visual Studio Code.app") : nil }
        let host = Host(home: scratch.appendingPathComponent("home").path), saved = saved!
        model.commandPaletteHosts = { [saved] }
        if connected { model.remoteFileAccess = { $0 == saved.id ? host : nil } } else { model.remoteFileAccess = { _ in nil } }
        let created = try await model.service.execute(.createRemoteSpace(name: "Remote", hostID: saved.id))
        let space = try XCTUnwrap(created.snapshot.spaces.last)
        let pane = try XCTUnwrap(created.snapshot.tabs[space.activeTabID]?.activePaneID)
        model.publish(try await model.service.execute(.configureStoppedSession(paneID: pane, launch: .remoteShell(hostID: saved.id, directory: project + "/Sources"))).snapshot)
        await model.selectSpace(space.id)
        XCTAssertEqual(model.presentation.activePane?.id, pane)
        return (model, pane, host, recorder)
    }

    private func names(_ model: AppWorkspaceModel) -> [String] { model.files.rows.map { $0.isNote ? "(note)" : $0.entry.name } }

    func testARemoteWorkspacePaneShowsItsHostsProjectAndListsFoldersOnDemand() async throws {
        let (model, pane, host, _) = try await makeModel()
        XCTAssertNil(model.sidebarUnavailableReason(.files), "Files works on a remote workspace pane")
        XCTAssertEqual(model.sidebarUnavailableReason(.changes), "Changes reads git only in panes on this Mac.", "Changes still doesn't")
        let before = model.snapshot
        model.toggleSidebarView(.files)
        XCTAssertEqual(model.visibleSidebarView, .files)
        await model.refreshFiles(paneID: pane)
        XCTAssertEqual(model.files.root, project, "The project holding the pane's folder on the host")
        XCTAssertEqual(model.files.host, FilesHost(id: saved.id, name: "build-box", home: host.home))
        XCTAssertNil(model.files.notice)
        XCTAssertEqual(names(model), ["Sources", "README.md", "tool.bin"], "Folders first; hidden, ignored and .git left out, as on this Mac")
        XCTAssertEqual(host.asked.last, [project], "Only the root is read until a folder opens")

        await model.toggleFilesFolder(project + "/Sources")
        XCTAssertEqual(names(model), ["Sources", "Deep", "App.swift", "README.md", "tool.bin"])
        XCTAssertEqual(host.asked.last, [project + "/Sources"])
        await model.setFilesShowHidden(true)
        XCTAssertTrue(names(model).contains(".hidden"))
        XCTAssertTrue(names(model).contains(".gitignore"))
        XCTAssertFalse(names(model).contains(".git"))
        XCTAssertEqual(host.asked.last, [project, project + "/Sources"], "Reading again asks for the root and the open folders in one request")
        await model.setFilesShowIgnored(true)
        XCTAssertTrue(names(model).contains("notes.log"))
        XCTAssertEqual(model.snapshot, before, "Nothing about Files is a workspace change")
    }

    func testAHostsOpenFoldersAreKeptApartFromThisMacsAtTheSamePath() async throws {
        let (model, pane, _, _) = try await makeModel()
        await model.refreshFiles(paneID: pane)
        await model.toggleFilesFolder(project + "/Sources")
        XCTAssertEqual(model.files.expandedByRoot.keys.count, 0)
        // Another host at the same path starts closed.
        let other = SavedHost(id: UUID(), draft: try HostDraft(name: "other-box", destination: "other-box").validated { _ in false }, revision: 1)
        XCTAssertNotEqual(FilesBrowserState.rootKey(project, host: model.files.host), FilesBrowserState.rootKey(project, host: nil))
        XCTAssertNotEqual(FilesBrowserState.rootKey(project, host: model.files.host), FilesBrowserState.rootKey(project, host: FilesHost(id: other.id, name: other.name, home: "/")))
    }

    func testSearchWalksTheHostOnceForEveryLetter() async throws {
        let (model, pane, host, _) = try await makeModel()
        await model.refreshFiles(paneID: pane)
        let asked = host.asked.count
        model.setFilesQuery("inn")
        await model.waitForFilesSearch()
        XCTAssertEqual(model.files.search?.matches.map(\.entry.name), ["Inner.swift"], "Found in a folder that was never opened")
        XCTAssertEqual(model.files.selection, project + "/Sources/Deep/Inner.swift")
        XCTAssertEqual(Array(host.asked.dropFirst(asked)), [[project], [project + "/Sources"], [project + "/Sources/Deep"]], "One request per level; .git and .hidden never asked for")
        let walked = host.asked.count
        model.setFilesQuery("inner")
        await model.waitForFilesSearch()
        XCTAssertEqual(model.files.search?.matches.map(\.entry.name), ["Inner.swift"])
        XCTAssertEqual(host.asked.count, walked, "The next letter searches what was already listed")
        model.setFilesQuery("log")
        await model.waitForFilesSearch()
        XCTAssertEqual(model.files.search?.matches.count, 0, "Ignored files stay out of search")
        // Clearing the field forgets the walk, so the next search sees the host as it is now.
        model.setFilesQuery("")
        try "x".write(toFile: project + "/Sources/Deep/Innermost.swift", atomically: true, encoding: .utf8)
        model.setFilesQuery("innermost")
        await model.waitForFilesSearch()
        XCTAssertEqual(model.files.search?.matches.map(\.entry.name), ["Innermost.swift"])
        XCTAssertGreaterThan(host.asked.count, walked)
    }

    func testAHostThatIsNotConnectedOrHasAnOldHelperSaysSoInWords() async throws {
        let (model, pane, host, _) = try await makeModel(connected: false)
        XCTAssertNil(model.sidebarUnavailableReason(.files), "The view stays available; it says why it is empty")
        await model.refreshFiles(paneID: pane)
        XCTAssertNil(model.files.root)
        XCTAssertEqual(model.files.notice, "Not connected to build-box. Its files show once it is connected.")

        let saved = saved!
        model.remoteFileAccess = { _ in host }
        host.browses = false
        await model.refreshFiles(paneID: pane)
        XCTAssertNil(model.files.root)
        XCTAssertEqual(model.files.notice, "Update the Trellis helper on build-box to browse its files.")
        XCTAssertEqual(host.asked.count, 0, "An older helper is never asked for a listing")

        host.browses = true
        await model.refreshFiles(paneID: pane)
        XCTAssertEqual(model.files.root, project)
        XCTAssertNil(model.files.notice)
        let rows = names(model)

        // The link drops: the tree already read stays, and says it may be stale.
        model.remoteFileAccess = { _ in nil }
        await model.refreshFiles(paneID: pane)
        XCTAssertEqual(names(model), rows)
        XCTAssertEqual(model.files.notice, "Not connected to build-box. The tree shows what was last read.")
        await model.toggleFilesFolder(project + "/Sources")
        XCTAssertEqual(names(model), ["Sources", "(note)", "README.md", "tool.bin"], "A folder opened meanwhile can't be read, and says so")
        await model.openFile(FileEntry(path: project + "/README.md", isDirectory: false))
        XCTAssertNil(model.shownEditor)
        XCTAssertEqual(model.errorMessage, "README.md can't be opened: build-box isn't connected.")
        _ = saved
    }

    func testAFolderTheHostListsOnlyInPartSaysSo() async throws {
        let (model, pane, host, _) = try await makeModel()
        host.truncated = [project]
        await model.refreshFiles(paneID: pane)
        XCTAssertEqual(names(model), ["Sources", "README.md", "tool.bin", "(note)"])
        XCTAssertEqual(model.files.rows.last?.truncated, true)
        XCTAssertEqual(model.files.navigableEntries.map(\.name), ["Sources", "README.md", "tool.bin"], "The note is never selected")
        host.truncated = []
        await model.refreshFiles(paneID: pane)
        XCTAssertEqual(names(model), ["Sources", "README.md", "tool.bin"])
    }

    func testAHostsFileOpensInAReadOnlyEditorTabAndIsNeverWritten() async throws {
        let (model, pane, _, recorder) = try await makeModel()
        await model.refreshFiles(paneID: pane)
        XCTAssertEqual(model.files.offeredEditors, [.trellisEditor, .newTab], "No app on this Mac is offered for a host's file")
        XCTAssertEqual(model.files.treeEditor, .trellisEditor)
        let readme = FileEntry(path: project + "/README.md", isDirectory: false)
        let before = model.snapshot
        await model.openFile(readme, in: EditorApp.with(id: "vscode"))
        let tab = try XCTUnwrap(model.shownEditor)
        XCTAssertTrue(recorder.opened.isEmpty, "Never handed to an app here")
        XCTAssertEqual(model.preferences.string(forKey: AppWorkspaceModel.filesEditorKey), nil, "and the remembered app isn't changed")
        XCTAssertEqual(tab.document.path, readme.path)
        XCTAssertEqual(tab.text, "host text\n")
        XCTAssertEqual(tab.remoteHost?.name, "build-box")
        XCTAssertTrue(tab.isReadOnly)
        XCTAssertEqual(tab.displayPath, "README.md")
        XCTAssertEqual(model.snapshot, before, "Editor tabs are never part of the workspace (FR-ED08)")

        // Nothing typed reaches the tab, nothing is saved, and closing never asks.
        model.updateEditorText(tab.id, "changed")
        XCTAssertEqual(model.editorTab(tab.id)?.text, "host text\n")
        XCTAssertFalse(model.hasUnsavedEditors)
        let wrote = await model.saveEditor(tab.id)
        XCTAssertFalse(wrote)
        XCTAssertEqual(try String(contentsOfFile: readme.path, encoding: .utf8), "host text\n")
        model.checkEditorOnDisk(tab.id)
        XCTAssertNil(model.editorTab(tab.id)?.banner, "This Mac's disk is never compared with a host's file")

        // Opening it again shows the same tab; a double click does too.
        await model.openFileOnDoubleClick(readme)
        XCTAssertEqual(model.currentEditors.count, 1)
        XCTAssertEqual(model.shownEditor?.id, tab.id)

        // Reload reads the host again.
        try "newer\n".write(toFile: readme.path, atomically: true, encoding: .utf8)
        await model.reloadEditor(tab.id)
        XCTAssertEqual(model.editorTab(tab.id)?.text, "newer\n")
        XCTAssertFalse(model.editorTab(tab.id)?.isDirty ?? true)

        // The same path on this Mac is another tab, which can be edited.
        await model.openInEditor(path: readme.path)
        XCTAssertEqual(model.currentEditors.count, 2)
        let local = try XCTUnwrap(model.shownEditor)
        XCTAssertNil(local.remoteHost)
        XCTAssertEqual(model.editorTitle(tab), "README.md — build-box", "The host tells the two apart")
        // Changes, review and that tab's Open With act on this Mac even while Files shows the host.
        await model.openLocalFile(readme, in: EditorApp.with(id: "vscode"), remember: false)
        XCTAssertEqual(recorder.opened, [URL(fileURLWithPath: readme.path)])
        model.confirmUnsavedEditors = { _ in
            XCTFail("A read-only tab never asks"); return .cancel
        }
        await model.closeEditor(tab.id)
        XCTAssertEqual(model.currentEditors.map(\.id), [local.id])
    }

    func testFilesTheEditorRefusesOpenNothingAndFoldersOpenATabOnTheHost() async throws {
        let (model, pane, _, recorder) = try await makeModel()
        await model.refreshFiles(paneID: pane)
        await model.openFile(FileEntry(path: project + "/tool.bin", isDirectory: false))
        XCTAssertNil(model.shownEditor, "A binary file opens nothing (FR-ED02)")
        XCTAssertEqual(model.errorMessage, "tool.bin can't be opened in Trellis. It isn't a text file.")
        XCTAssertTrue(recorder.opened.isEmpty)
        XCTAssertTrue(recorder.revealed.isEmpty)
        model.errorMessage = nil
        await model.openFile(FileEntry(path: project + "/gone.txt", isDirectory: false))
        XCTAssertEqual(model.errorMessage, "gone.txt can't be opened in Trellis. It can't be read: The file is no longer there.")

        model.revealFile(FileEntry(path: project + "/README.md", isDirectory: false))
        model.openFile(FileEntry(path: project + "/README.md", isDirectory: false), withApp: URL(fileURLWithPath: "/Applications/TextEdit.app"))
        XCTAssertTrue(recorder.revealed.isEmpty, "Finder can't show a host's file")
        XCTAssertTrue(recorder.opened.isEmpty)

        // A folder, or New Tab Here on a file, opens a tab in that folder on the host.
        let tabs = model.presentation.visibleTabs.count
        await model.openFile(FileEntry(path: project + "/Sources/App.swift", isDirectory: false), in: .newTab)
        XCTAssertEqual(model.presentation.visibleTabs.count, tabs + 1)
        let launched = model.presentation.activePane.flatMap { model.snapshot.sessions[$0.sessionID]?.launch }
        XCTAssertEqual(launched, .remoteShell(hostID: saved.id, directory: project + "/Sources"))
    }

    func testCopiedPathsAreTheHostsWithItsHomeAbbreviated() async throws {
        let (model, pane, host, recorder) = try await makeModel()
        await model.refreshFiles(paneID: pane)
        let entry = FileEntry(path: project + "/Sources/App.swift", isDirectory: false)
        model.copyFilePath(entry)
        model.copyFilePath(entry, style: .relative)
        model.copyFilePath(entry, style: .name)
        XCTAssertEqual(recorder.copied, [entry.path, "Sources/App.swift", "App.swift"])
        XCTAssertEqual(AppWorkspaceModel.abbreviatingHome(entry.path, home: host.home), "~/project/Sources/App.swift")
        XCTAssertEqual(model.files.status, "Copied App.swift")
    }

    func testGoingBackToAPaneOnThisMacShowsItsOwnTree() async throws {
        let (model, pane, _, _) = try await makeModel()
        await model.refreshFiles(paneID: pane)
        XCTAssertNotNil(model.files.host)
        XCTAssertEqual(model.filesRefreshKey(paneID: pane), [pane.uuidString, project + "/Sources", saved.id.uuidString, "down"], "The key changes when the link comes back")
        let created = await model.createSpace(startSession: false)
        await model.selectSpace(try XCTUnwrap(created))
        let localPane = try XCTUnwrap(model.presentation.activePane?.id)
        XCTAssertNotEqual(localPane, pane)
        await model.refreshFiles(paneID: localPane)
        XCTAssertNil(model.files.host, "A pane on this Mac never shows a host's tree")
        XCTAssertNil(model.files.notice)
        XCTAssertEqual(model.files.offeredEditors, model.files.editors)
    }
}
