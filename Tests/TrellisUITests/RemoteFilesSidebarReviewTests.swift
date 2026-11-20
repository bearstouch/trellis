import AppKit
import XCTest
import TrellisCore
@testable import TrellisUI

/// Review-driven checks of the Files view on a remote workspace pane (FR-FB09): a link that goes down while the tree is
/// being read must leave the tree already read, not a guessed root or "Can't read this folder".
@MainActor
final class RemoteFilesSidebarReviewTests: XCTestCase {
    /// A "host" whose disk is a folder on this Mac, and whose link can go down at two points of a refresh.
    private final class Host: RemoteFileAccess, @unchecked Sendable {
        enum Drop { case never, whileFindingTheRoot, whileListing }
        let home: String
        let browses = true
        private let lock = NSLock()
        private var _drop = Drop.never, _down = false
        init(home: String) { self.home = home }
        var drop: Drop {
            get { lock.withLock { _drop } }
            set { lock.withLock { _drop = newValue } }
        }
        var down: Bool {
            get { lock.withLock { _down } }
            set { lock.withLock { _down = newValue } }
        }

        func projectRoot(containing directory: String) async -> String {
            // As the helper's side does: with no answer, the folder asked about is all it knows.
            if drop == .whileFindingTheRoot { down = true }
            guard !down else { return directory }
            return ProjectLocator.taskRoot(containing: directory, home: home, exists: { FileManager.default.fileExists(atPath: $0) }) ?? directory
        }

        func contents(of directories: [String]) async -> [String: FolderListing] {
            if drop == .whileListing { down = true }
            guard !down else { return [:] }
            return Dictionary(uniqueKeysWithValues: directories.map { path in (path, (try? LocalFileListing().contents(of: path)).map { .entries($0, truncated: false) } ?? .unreadable) })
        }

        func read(_ path: String, limit: Int) async -> Result<RemoteFileContents, RemoteFileFailure> { .failure(.disconnected) }
    }

    private var scratch: URL!
    private var project = ""

    override func setUp() async throws {
        _ = NSApplication.shared
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-rfr-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        project = scratch.appendingPathComponent("home/project").path
        for folder in ["state", "home/project/.git", "home/project/Sources"] {
            try FileManager.default.createDirectory(at: scratch.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["home/project/README.md", "home/project/Sources/App.swift"] {
            try "host text\n".write(to: scratch.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    private func makeModel() async throws -> (AppWorkspaceModel, UUID, Host) {
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-rfr-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        _ = await model.loadWorkspace()
        let saved = SavedHost(id: UUID(), draft: try HostDraft(name: "build-box", destination: "build-box").validated { _ in false }, revision: 1)
        let host = Host(home: scratch.appendingPathComponent("home").path)
        model.commandPaletteHosts = { [saved] }
        // A host whose link is down has no connection to ask.
        model.remoteFileAccess = { $0 == saved.id && !host.down ? host : nil }
        let created = try await model.service.execute(.createRemoteSpace(name: "Remote", hostID: saved.id))
        let space = try XCTUnwrap(created.snapshot.spaces.last)
        let pane = try XCTUnwrap(created.snapshot.tabs[space.activeTabID]?.activePaneID)
        model.publish(try await model.service.execute(.configureStoppedSession(paneID: pane, launch: .remoteShell(hostID: saved.id, directory: project + "/Sources"))).snapshot)
        await model.selectSpace(space.id)
        return (model, pane, host)
    }

    private func names(_ model: AppWorkspaceModel) -> [String] { model.files.rows.map { $0.isNote ? "(note)" : $0.entry.name } }

    func testALinkThatDropsWhileTheRootIsAskedForKeepsTheTreeAlreadyRead() async throws {
        let (model, pane, host) = try await makeModel()
        await model.refreshFiles(paneID: pane)
        await model.toggleFilesFolder(project + "/Sources")
        XCTAssertEqual(model.files.root, project)
        let rows = names(model)
        XCTAssertEqual(rows, ["Sources", "App.swift", "README.md"])

        host.drop = .whileFindingTheRoot
        await model.refreshFiles(paneID: pane)
        XCTAssertEqual(model.files.root, project, "The pane's folder isn't taken for the project because nothing answered")
        XCTAssertEqual(names(model), rows)
        XCTAssertEqual(model.files.notice, "Not connected to build-box. The tree shows what was last read.")

        // Back up: the tree is read again and the notice goes.
        host.drop = .never
        host.down = false
        await model.refreshFiles(paneID: pane)
        XCTAssertEqual(names(model), rows)
        XCTAssertNil(model.files.notice)
    }

    func testALinkThatDropsWhileFoldersAreListedKeepsTheirListings() async throws {
        let (model, pane, host) = try await makeModel()
        await model.refreshFiles(paneID: pane)
        await model.toggleFilesFolder(project + "/Sources")
        let rows = names(model)

        host.drop = .whileListing
        await model.refreshFiles(paneID: pane)
        XCTAssertEqual(model.files.root, project)
        XCTAssertEqual(names(model), rows, "No answer isn't an unreadable folder")
        XCTAssertFalse(model.files.rows.contains { $0.unreadable })
    }
}
