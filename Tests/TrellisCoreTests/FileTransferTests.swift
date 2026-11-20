import XCTest

@testable import TrellisCore

/// The copy engine behind drops on the Files view (FR-FB10–FR-FB14), over an in-memory host and this Mac's temp folders.
final class FileTransferTests: XCTestCase {
    /// A host's files in memory: a source and a destination like the helper, without links or moves that replace.
    final class Memory: TransferSource, TransferDestination, @unchecked Sendable {
        struct Entry { var kind: TransferItemKind; var data = Data(); var mode = 0o644 }
        private let lock = NSLock()
        private var entries: [String: Entry]
        var writes = 0
        var failReads: Set<String> = []
        var failListings: Set<String> = []
        var disconnectAfterWrites: Int?
        /// Called before each chunk is read, to change a file mid-copy.
        var onRead: (@Sendable (String, Int64) -> Void)?

        init(_ entries: [String: Entry]) { self.entries = entries }
        subscript(path: String) -> Entry? {
            get { lock.withLock { entries[path] } }
            set { lock.withLock { entries[path] = newValue } }
        }
        var paths: Set<String> { lock.withLock { Set(entries.keys) } }
        static func parent(_ path: String) -> String { let p = (path as NSString).deletingLastPathComponent; return p.isEmpty ? "/" : p }
        static func join(_ folder: String, _ name: String) -> String { folder == "/" ? "/" + name : folder + "/" + name }

        func describe(_ paths: [String]) async throws(FileTransferFailure) -> [TransferItem] {
            paths.compactMap { path in self[path].map { TransferItem(path: path, kind: $0.kind, size: Int64($0.data.count), mode: $0.mode) } }
        }
        func children(of folder: String) async throws(FileTransferFailure) -> [TransferItem] {
            guard self[folder]?.kind == .directory else { throw .unreadable }
            return try await describe(paths.filter { Self.parent($0) == folder && $0 != folder }.sorted())
        }
        func read(_ path: String, offset: Int64, length: Int) async throws(FileTransferFailure) -> TransferChunk {
            onRead?(path, offset)
            guard !failReads.contains(path), let entry = self[path], entry.kind == .file else { throw .unreadable }
            let start = min(Int(offset), entry.data.count), end = min(start + length, entry.data.count)
            return TransferChunk(data: entry.data.subdata(in: start..<end), size: Int64(entry.data.count), modified: Int64(entry.data.hashValue))
        }
        func existing(in folder: String) async throws(FileTransferFailure) -> [String: TransferItemKind] {
            guard !failListings.contains(folder) else { throw .unwritable }
            return Dictionary(uniqueKeysWithValues: paths.filter { Self.parent($0) == folder && $0 != folder }.map { (($0 as NSString).lastPathComponent, self[$0]!.kind) })
        }
        func makeDirectory(_ path: String, mode: Int) async throws(FileTransferFailure) {
            guard self[path] == nil else { throw .exists }
            self[path] = Entry(kind: .directory, mode: mode)
        }
        func begin(in folder: String) async throws(FileTransferFailure) -> String {
            let temp = ".trellis-upload-" + UUID().uuidString.prefix(8)
            self[Self.join(folder, temp)] = Entry(kind: .file, mode: 0o600)
            return temp
        }
        func write(_ temp: String, in folder: String, offset: Int64, data: Data) async throws(FileTransferFailure) {
            let count = lock.withLock {
                writes += 1; return writes
            }
            if let limit = disconnectAfterWrites, count > limit { throw .disconnected }
            let path = Self.join(folder, temp)
            guard var entry = self[path] else { throw .missing }
            if entry.data.count < Int(offset) + data.count { entry.data.append(Data(count: Int(offset) + data.count - entry.data.count)) }
            entry.data.replaceSubrange(Int(offset)..<Int(offset) + data.count, with: data)
            self[path] = entry
        }
        func finish(_ temp: String, in folder: String, name: String, mode: Int, size: Int64, replace: Bool) async throws(FileTransferFailure) {
            let from = Self.join(folder, temp), to = Self.join(folder, name)
            guard var entry = self[from], entry.data.count == size else { throw .changed }
            if let existing = self[to] { guard replace, existing.kind != .directory else { throw replace ? .notAllowed : .exists } }
            entry.mode = mode
            self[to] = entry
            self[from] = nil
        }
        func abort(_ temp: String, in folder: String) async { self[Self.join(folder, temp)] = nil }
        func move(_ path: String, to target: String, replace: Bool) async throws(FileTransferFailure) {
            guard self[target] == nil else { throw .exists }
            for old in paths where old == path || old.hasPrefix(path + "/") {
                self[target + old.dropFirst(path.count)] = self[old]
                self[old] = nil
            }
        }
    }

    private func file(_ text: String, mode: Int = 0o644) -> Memory.Entry { Memory.Entry(kind: .file, data: Data(text.utf8), mode: mode) }
    private let folder = Memory.Entry(kind: .directory)
    private func temporaryNames(_ memory: Memory) -> [String] { memory.paths.filter { $0.contains(".trellis-upload-") }.sorted() }

    private func run(
        _ source: Memory, _ destination: Memory, same: Bool = false, limits: FileTransferLimits = FileTransferLimits(chunk: 4),
        resolve: @escaping FileTransferRun.Resolve = { _ in
            XCTFail("No conflict expected"); return nil
        }
    ) -> FileTransferRun {
        FileTransferRun(source: source, destination: destination, sameMachine: same, limits: limits, resolve: resolve)
    }

    func testFilesAndFoldersAreCopiedInChunksWithTheirModes() async {
        let mac = Memory(["/src": folder, "/src/a.txt": file("hello world", mode: 0o755), "/src/sub": folder, "/src/sub/b.txt": file("b"), "/one.txt": file("1")])
        let host = Memory(["/srv": folder])
        let report = await run(mac, host).copy(["/src", "/one.txt"], into: "/srv")
        XCTAssertEqual(report.copied, 5)
        XCTAssertEqual(report.firstPlaced, "/srv/src")
        XCTAssertEqual(host["/srv/src/a.txt"]?.data, Data("hello world".utf8))
        XCTAssertEqual(host["/srv/src/a.txt"]?.mode, 0o755)
        XCTAssertEqual(host["/srv/src/sub/b.txt"]?.data, Data("b".utf8))
        XCTAssertEqual(host["/srv/one.txt"]?.data, Data("1".utf8))
        XCTAssertEqual(temporaryNames(host), [])
        XCTAssertGreaterThanOrEqual(host.writes, 3, "11 bytes in 4-byte chunks")
    }

    func testTheLimitsRefuseADropBeforeAnythingIsWritten() async {
        let mac = Memory(["/src": folder, "/src/a": file("12345"), "/src/b": file("12345"), "/src/c": file("1")])
        let host = Memory(["/srv": folder])
        var report = await run(mac, host, limits: FileTransferLimits(totalBytes: 10, entries: 100, chunk: 4)).copy(["/src"], into: "/srv")
        XCTAssertEqual(report.stopped, .tooLarge)
        report = await run(mac, host, limits: FileTransferLimits(totalBytes: 100, entries: 3, chunk: 4)).copy(["/src"], into: "/srv")
        XCTAssertEqual(report.stopped, .tooManyItems)
        XCTAssertEqual(host.paths, ["/srv"], "Nothing was written")
    }

    func testKeepBothNamesAreFinderLike() {
        XCTAssertEqual(FileTransferNaming.keepBoth("report.pdf", taken: ["report.pdf"]), "report 2.pdf")
        XCTAssertEqual(FileTransferNaming.keepBoth("report.pdf", taken: ["report.pdf", "report 2.pdf"]), "report 3.pdf")
        XCTAssertEqual(FileTransferNaming.keepBoth("a.tar.gz", taken: []), "a 2.tar.gz")
        XCTAssertEqual(FileTransferNaming.keepBoth(".env", taken: []), ".env 2")
        XCTAssertEqual(FileTransferNaming.keepBoth("docs.v1", taken: [], isFolder: true), "docs.v1 2")
        XCTAssertEqual(FileTransferNaming.keepBoth("Makefile", taken: []), "Makefile 2")
    }

    func testConflictsAskWithSafeChoicesAndApplyToAll() async {
        let mac = Memory(["/a.txt": file("new a"), "/b.txt": file("new b"), "/c.txt": file("new c"), "/docs": folder, "/docs/x": file("x"), "/f": folder])
        let host = Memory(["/srv": folder, "/srv/a.txt": file("old a"), "/srv/b.txt": file("old b"), "/srv/c.txt": file("old c"), "/srv/docs": folder, "/srv/docs/y": file("y"), "/srv/f": file("a file")])
        let asked = Memory([:])
        let report = await run(mac, host) { conflict in
            asked[conflict.name] = Memory.Entry(kind: .file, data: Data(conflict.choices.map(\.rawValue).joined(separator: ",").utf8))
            switch conflict.name {
            case "a.txt": return FileTransferDecision(.replace)
            case "b.txt": return FileTransferDecision(.keepBoth, applyToAll: true)
            case "docs": return FileTransferDecision(.merge)
            default: return FileTransferDecision(.skip)
            }
        }.copy(["/a.txt", "/b.txt", "/c.txt", "/docs", "/f"], into: "/srv")
        XCTAssertEqual(host["/srv/a.txt"]?.data, Data("new a".utf8))
        XCTAssertEqual(host["/srv/b 2.txt"]?.data, Data("new b".utf8))
        XCTAssertEqual(host["/srv/c 2.txt"]?.data, Data("new c".utf8), "Keep Both applied to the next file without asking")
        XCTAssertEqual(host["/srv/c.txt"]?.data, Data("old c".utf8))
        XCTAssertNil(asked["c.txt"])
        XCTAssertEqual(host["/srv/docs/x"]?.data, Data("x".utf8), "Merged")
        XCTAssertEqual(host["/srv/docs/y"]?.data, Data("y".utf8), "Merging removes nothing")
        XCTAssertEqual(String(decoding: asked["docs"]!.data, as: UTF8.self), "merge,keepBoth,skip")
        XCTAssertEqual(String(decoding: asked["f"]!.data, as: UTF8.self), "keepBoth,skip", "A folder never replaces a file, nor a file a folder")
        XCTAssertEqual(host["/srv/f"]?.data, Data("a file".utf8))
        XCTAssertEqual(report.skipped, 1)
    }

    func testStoppingAtAConflictCancelsAndKeepsWhatWasFinished() async {
        let mac = Memory(["/a": file("a"), "/b": file("b"), "/c": file("c")])
        let host = Memory(["/srv": folder, "/srv/b": file("old")])
        let report = await run(mac, host) { _ in nil }.copy(["/a", "/b", "/c"], into: "/srv")
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(host["/srv/a"]?.data, Data("a".utf8))
        XCTAssertNil(host["/srv/c"])
    }

    func testAFolderNeverGoesIntoItselfAndADuplicateInPlaceIsKeptBeside() async {
        let host = Memory(["/srv": folder, "/srv/app": folder, "/srv/app/inner": folder, "/srv/x.txt": file("x")])
        var report = await run(host, host, same: true).copy(["/srv/app"], into: "/srv/app/inner")
        XCTAssertEqual(report.failures["/srv/app"], .intoItself)
        report = await run(host, host, same: true).copy(["/srv/x.txt"], into: "/srv")
        XCTAssertEqual(host["/srv/x 2.txt"]?.data, Data("x".utf8))
        XCTAssertEqual(report.firstPlaced, "/srv/x 2.txt")
    }

    func testLinksAndSpecialFilesAreSkippedBetweenMachines() async {
        let mac = Memory(["/src": folder, "/src/link": Memory.Entry(kind: .symlink), "/src/fifo": Memory.Entry(kind: .other), "/src/a": file("a")])
        let host = Memory(["/srv": folder])
        let report = await run(mac, host).copy(["/src"], into: "/srv")
        XCTAssertEqual(report.linksSkipped, 1)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(host.paths, ["/srv", "/srv/src", "/srv/src/a"])
    }

    func testAFailingFileIsReportedAndTheRestGoOnButADroppedLinkStops() async {
        let mac = Memory(["/a": file("a"), "/b": file("b"), "/c": file("c")])
        mac.failReads = ["/b"]
        let host = Memory(["/srv": folder])
        var report = await run(mac, host).copy(["/a", "/b", "/c"], into: "/srv")
        XCTAssertEqual(report.failures, ["/b": .unreadable])
        XCTAssertEqual(host.paths, ["/srv", "/srv/a", "/srv/c"], "The failed file's temporary file is removed")
        let other = Memory(["/srv": folder])
        other.disconnectAfterWrites = 1
        report = await run(Memory(["/a": file("a"), "/b": file("b"), "/c": file("c")]), other).copy(["/a", "/b", "/c"], into: "/srv")
        XCTAssertEqual(report.stopped, .disconnected)
        XCTAssertEqual(report.copied, 1)
    }

    func testAFolderThereThatCantBeListedFailsAloneAndTheRestGoOn() async {
        let mac = Memory(["/docs": folder, "/docs/x": file("x"), "/z": file("z")])
        let host = Memory(["/srv": folder, "/srv/docs": folder])
        host.failListings = ["/srv/docs"]
        let report = await run(mac, host) { _ in FileTransferDecision(.merge) }.copy(["/docs", "/z"], into: "/srv")
        XCTAssertNil(report.stopped)
        XCTAssertEqual(report.failures, ["/docs/x": .unwritable])
        XCTAssertEqual(report.copied, 1)
        XCTAssertEqual(host["/srv/z"]?.data, Data("z".utf8))
    }

    func testAFileThatChangesWhileItIsCopiedFails() async {
        let mac = Memory(["/a": file("0123456789")])
        let host = Memory(["/srv": folder])
        mac.onRead = { [unowned mac] _, offset in if offset > 0 { mac["/a"] = Memory.Entry(kind: .file, data: Data("changed!!!!".utf8)) } }
        let report = await run(mac, host).copy(["/a"], into: "/srv")
        XCTAssertEqual(report.failures["/a"], .changed)
        XCTAssertEqual(host.paths, ["/srv"])
    }

    func testCancellingMidFileRemovesItAndKeepsFinishedOnes() async {
        let mac = Memory(["/a": file("a"), "/b": file(String(repeating: "b", count: 64))])
        let host = Memory(["/srv": folder])
        let started = expectation(description: "b started")
        // The read waits a moment, so the cancel lands while the file is half copied.
        mac.onRead = { path, offset in if path == "/b", offset == 8 { started.fulfill(); usleep(300_000) } }
        let transfer = run(mac, host)
        let task = Task { await transfer.copy(["/a", "/b"], into: "/srv") }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        let report = await task.value
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(host.paths, ["/srv", "/srv/a"])
    }

    func testAMoveWithinAHostTakesFreeNamesOnly() async {
        let host = Memory(["/srv": folder, "/srv/a": file("a"), "/srv/docs": folder, "/srv/docs/a": file("old"), "/srv/b": file("b")])
        let asked = Memory([:])
        let report = await run(host, host, same: true) { conflict in
            asked[conflict.name] = Memory.Entry(kind: .file, data: Data(conflict.choices.map(\.rawValue).joined(separator: ",").utf8))
            return FileTransferDecision(.keepBoth)
        }.move(["/srv/a", "/srv/b"], into: "/srv/docs")
        XCTAssertEqual(String(decoding: asked["a"]!.data, as: UTF8.self), "keepBoth,skip", "A host's move never replaces")
        XCTAssertEqual(host["/srv/docs/a 2"]?.data, Data("a".utf8))
        XCTAssertEqual(host["/srv/docs/b"]?.data, Data("b".utf8))
        XCTAssertNil(host["/srv/a"])
        XCTAssertEqual(report.copied, 2)
    }

    // MARK: This Mac

    private func temporaryFolder() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-ft-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    func testOnThisMacLinksStayLinksAndAMoveCanMergeAndReplace() async throws {
        let root = try temporaryFolder()
        let manager = FileManager.default
        try manager.createDirectory(atPath: root + "/src/sub", withIntermediateDirectories: true)
        try Data("a".utf8).write(to: URL(fileURLWithPath: root + "/src/a.txt"))
        try manager.createSymbolicLink(atPath: root + "/src/link", withDestinationPath: "a.txt")
        try manager.createDirectory(atPath: root + "/dst", withIntermediateDirectories: true)
        let local = LocalTransferEndpoint()
        var report = await FileTransferRun(source: local, destination: local, sameMachine: true, bothLocal: true, resolve: { _ in nil }).copy([root + "/src"], into: root + "/dst")
        XCTAssertEqual(report.copied, 4)
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: root + "/dst/src/link"), "a.txt")
        XCTAssertEqual(try String(contentsOfFile: root + "/dst/src/a.txt", encoding: .utf8), "a")
        XCTAssertFalse(try manager.contentsOfDirectory(atPath: root + "/dst/src").contains { $0.hasPrefix(".trellis-upload-") })

        try Data("newer".utf8).write(to: URL(fileURLWithPath: root + "/src/a.txt"))
        report = await FileTransferRun(source: local, destination: local, sameMachine: true, bothLocal: true) { conflict in
            FileTransferDecision(conflict.choices.contains(.merge) ? .merge : .replace, applyToAll: true)
        }.move([root + "/src"], into: root + "/dst")
        XCTAssertEqual(try String(contentsOfFile: root + "/dst/src/a.txt", encoding: .utf8), "newer")
        XCTAssertFalse(manager.fileExists(atPath: root + "/src"), "The emptied folder is removed")
        XCTAssertTrue(report.failures.isEmpty)
    }

    func testOnThisMacATakenNameIsNeverReplacedUnlessAsked() async throws {
        let root = try temporaryFolder()
        let local = LocalTransferEndpoint()
        try Data("old".utf8).write(to: URL(fileURLWithPath: root + "/a"))
        let temp = try await local.begin(in: root)
        try await local.write(temp, in: root, offset: 0, data: Data("new".utf8))
        do {
            try await local.finish(temp, in: root, name: "a", mode: 0o644, size: 3, replace: false)
            XCTFail("Replaced")
        } catch { XCTAssertEqual(error, .exists) }
        XCTAssertEqual(try String(contentsOfFile: root + "/a", encoding: .utf8), "old")
        try await local.finish(temp, in: root, name: "a", mode: 0o600, size: 3, replace: true)
        XCTAssertEqual(try String(contentsOfFile: root + "/a", encoding: .utf8), "new")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: root + "/a")[.posixPermissions] as? Int, 0o600)
    }
}
