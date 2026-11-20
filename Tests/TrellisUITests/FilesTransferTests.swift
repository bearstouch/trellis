import AppKit
import UniformTypeIdentifiers
import XCTest
import TrellisCore
@testable import TrellisUI

/// Drops on the Files view and drags out of it (FR-FB10–FR-FB14), at the model level: the "host" is a temporary folder
/// behind an injected ``RemoteFileAccess`` whose copies use this Mac's endpoint, so no link is needed.
@MainActor
final class FilesTransferTests: XCTestCase {
    private final class Host: RemoteFileAccess, @unchecked Sendable {
        let home: String
        private let lock = NSLock()
        private var _writes = true
        init(home: String) { self.home = home }
        var browses: Bool { true }
        var writes: Bool {
            get { lock.withLock { _writes } }
            set { lock.withLock { _writes = newValue } }
        }
        func projectRoot(containing directory: String) async -> String {
            ProjectLocator.taskRoot(containing: directory, home: home, exists: { FileManager.default.fileExists(atPath: $0) }) ?? directory
        }
        func contents(of directories: [String]) async -> [String: FolderListing] {
            Dictionary(uniqueKeysWithValues: directories.map { ($0, (try? LocalFileListing().contents(of: $0)).map { .entries($0, truncated: false) } ?? .unreadable) })
        }
        func read(_ path: String, limit: Int) async -> Result<RemoteFileContents, RemoteFileFailure> { .failure(.unreadable) }
        func transferSource() -> (any TransferSource)? { LocalTransferEndpoint() }
        func transferDestination() -> (any TransferDestination)? { writes ? LocalTransferEndpoint() : nil }
    }

    private var scratch: URL!
    private var project = ""
    private var desktop = ""
    private var saved: SavedHost!

    override func setUp() async throws {
        _ = NSApplication.shared
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-ftu-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        project = scratch.appendingPathComponent("home/project").path
        desktop = scratch.appendingPathComponent("desktop").path
        for folder in ["state", "home/project/.git", "home/project/Sources", "desktop/photos"] {
            try FileManager.default.createDirectory(at: scratch.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try "host readme\n".write(toFile: project + "/README.md", atomically: true, encoding: .utf8)
        try "a picture\n".write(toFile: desktop + "/photos/a.jpg", atomically: true, encoding: .utf8)
        try "notes\n".write(toFile: desktop + "/README.md", atomically: true, encoding: .utf8)
        saved = SavedHost(id: UUID(), draft: try HostDraft(name: "build-box", destination: "build-box").validated { _ in false }, revision: 1)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    private func makeModel() async throws -> (AppWorkspaceModel, UUID, Host) {
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-ftu-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        _ = await model.loadWorkspace()
        model.copyToPasteboard = { _ in }
        let host = Host(home: scratch.appendingPathComponent("home").path), saved = saved!
        model.commandPaletteHosts = { [saved] }
        model.remoteFileAccess = { $0 == saved.id ? host : nil }
        let created = try await model.service.execute(.createRemoteSpace(name: "Remote", hostID: saved.id))
        let space = try XCTUnwrap(created.snapshot.spaces.last)
        let pane = try XCTUnwrap(created.snapshot.tabs[space.activeTabID]?.activePaneID)
        model.publish(try await model.service.execute(.configureStoppedSession(paneID: pane, launch: .remoteShell(hostID: saved.id, directory: project))).snapshot)
        await model.selectSpace(space.id)
        await model.refreshFiles(paneID: pane)
        XCTAssertEqual(model.files.root, project)
        return (model, pane, host)
    }

    private func text(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    func testFinderFilesAndFoldersDroppedOnAHostsFolderAreCopiedThereAndSelected() async throws {
        let (model, _, _) = try await makeModel()
        XCTAssertTrue(model.filesAcceptsDrops)
        let report = try await XCTUnwrapAsync(await model.dropIntoFiles(.local([desktop + "/photos"]), folder: project + "/Sources", move: true))
        XCTAssertEqual(report.copied, 2)
        XCTAssertEqual(text(project + "/Sources/photos/a.jpg"), "a picture\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: desktop + "/photos/a.jpg"), "⌘ never moves between machines")
        XCTAssertTrue(model.files.expanded.contains(project + "/Sources"), "The folder that took the drop opens")
        XCTAssertEqual(model.files.selection, project + "/Sources/photos")
        XCTAssertEqual(model.files.status, "Copied 2 items to Sources")
        XCTAssertTrue(model.fileTransfers.runs.isEmpty)
    }

    func testAHostWhoseHelperDoesntWriteIsNeverAskedAndSaysWhy() async throws {
        let (model, _, host) = try await makeModel()
        host.writes = false
        XCTAssertFalse(model.filesAcceptsDrops)
        let report = await model.dropIntoFiles(.local([desktop + "/README.md"]), folder: project, move: false)
        XCTAssertNil(report)
        XCTAssertEqual(model.files.notice, "Update the Trellis helper on build-box to copy files to it.")
        XCTAssertEqual(text(project + "/README.md"), "host readme\n")
    }

    func testATakenNameAsksAndKeepBothCopiesBesideIt() async throws {
        let (model, _, _) = try await makeModel()
        let drop = Task { await model.dropIntoFiles(.local([desktop + "/README.md"]), folder: project, move: false) }
        let deadline = Date().addingTimeInterval(5)
        while model.fileTransfers.prompt == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let prompt = try XCTUnwrap(model.fileTransfers.prompt)
        XCTAssertEqual(prompt.conflict.name, "README.md")
        XCTAssertEqual(prompt.conflict.choices, [.replace, .keepBoth, .skip])
        model.fileTransfers.answer(FileTransferDecision(.keepBoth))
        _ = await drop.value
        XCTAssertEqual(text(project + "/README.md"), "host readme\n")
        XCTAssertEqual(text(project + "/README 2.md"), "notes\n")
        XCTAssertNil(model.fileTransfers.prompt)
    }

    func testAnAnswerMeantForAnEarlierConflictNeverStopsTheOneShownNow() async throws {
        let (model, _, _) = try await makeModel()
        let drop = Task { await model.dropIntoFiles(.local([desktop + "/README.md"]), folder: project, move: false) }
        let deadline = Date().addingTimeInterval(5)
        while model.fileTransfers.prompt == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let prompt = try XCTUnwrap(model.fileTransfers.prompt)
        model.fileTransfers.answer(nil, to: UUID())
        XCTAssertEqual(model.fileTransfers.prompt, prompt, "A stale sheet's answer is ignored")
        model.fileTransfers.answer(FileTransferDecision(.skip), to: prompt.id)
        let report = try await XCTUnwrapAsync(await drop.value)
        XCTAssertFalse(report.cancelled)
        XCTAssertEqual(report.skipped, 1)
    }

    func testStoppingAtTheConflictCopiesNothingMore() async throws {
        let (model, _, _) = try await makeModel()
        let drop = Task { await model.dropIntoFiles(.local([desktop + "/README.md"]), folder: project, move: false) }
        let deadline = Date().addingTimeInterval(5)
        while model.fileTransfers.prompt == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        model.fileTransfers.answer(nil)
        let report = try await XCTUnwrapAsync(await drop.value)
        XCTAssertTrue(report.cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project + "/README 2.md"))
        XCTAssertEqual(model.files.status, "Stopped after 0 copied")
    }

    func testAHostsRowMovesWithinTheHostAndNeverIntoItself() async throws {
        let (model, _, _) = try await makeModel()
        let moved = try await XCTUnwrapAsync(await model.dropIntoFiles(.host(saved.id, [project + "/README.md"]), folder: project + "/Sources", move: true))
        XCTAssertEqual(moved.copied, 1)
        XCTAssertEqual(text(project + "/Sources/README.md"), "host readme\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project + "/README.md"))
        let refused = try await XCTUnwrapAsync(await model.dropIntoFiles(.host(saved.id, [project + "/Sources"]), folder: project + "/Sources", move: false))
        XCTAssertEqual(refused.failures[project + "/Sources"], .intoItself)
    }

    func testAPromisedRowIsCopiedIntoFindersFolderBesideATakenName() async throws {
        let (model, _, _) = try await makeModel()
        try "already here\n".write(toFile: desktop + "/README.md", atomically: true, encoding: .utf8)
        let failure = await model.downloadForPromise(hostID: saved.id, path: project + "/README.md", to: desktop)
        XCTAssertNil(failure)
        XCTAssertEqual(text(desktop + "/README.md"), "already here\n")
        XCTAssertEqual(text(desktop + "/README 2.md"), "host readme\n")
        let gone = await model.downloadForPromise(hostID: UUID(), path: project + "/README.md", to: desktop)
        XCTAssertEqual(gone, .disconnected)
    }

    func testAPromisedLinkFailsInsteadOfPromisingNothing() async throws {
        let (model, _, _) = try await makeModel()
        try FileManager.default.createSymbolicLink(atPath: project + "/latest", withDestinationPath: "README.md")
        let failure = await model.downloadForPromise(hostID: saved.id, path: project + "/latest", to: desktop)
        XCTAssertEqual(failure, .notAllowed, "Finder is told nothing was written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: desktop + "/latest"))
        XCTAssertEqual(model.files.status, "latest is a link; links aren't copied from a host.")
    }

    func testTheSummarySaysWhatHappened() {
        var report = FileTransferReport()
        report.copied = 3
        report.skipped = 1
        report.linksSkipped = 2
        report.failures = ["/a/b.bin": .changed]
        XCTAssertEqual(AppWorkspaceModel.transferSummary(report, folder: "docs", moved: false), "Copied 3 items to docs · 1 skipped · 2 links not copied · b.bin failed: it changed while it was copied")
        report = FileTransferReport()
        report.stopped = .tooLarge
        XCTAssertEqual(AppWorkspaceModel.transferSummary(report, folder: "docs", moved: false), "Nothing was copied: one drag copies at most 2 GB and 10,000 items.")
    }

    func testDropPayloadsAreReadFromTrellisRowsOrFinderURLs() async throws {
        let (model, _, _) = try await makeModel()
        let row = NSItemProvider()
        let payload = try JSONEncoder().encode(FilesDragPayload(host: saved.id, paths: ["/srv/a"]))
        row.registerDataRepresentation(forTypeIdentifier: UTType.trellisFilesEntry.identifier, visibility: .ownProcess) { done in
            done(payload, nil); return nil
        }
        let source = await model.filesDropSource(from: [row])
        XCTAssertEqual(source, .host(saved.id, ["/srv/a"]))
        let finder = NSItemProvider(object: URL(fileURLWithPath: desktop + "/README.md") as NSURL)
        let local = await model.filesDropSource(from: [finder])
        XCTAssertEqual(local, .local([desktop + "/README.md"]))
    }

    private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        let result = try await value()
        return try XCTUnwrap(result, file: file, line: line)
    }
}
