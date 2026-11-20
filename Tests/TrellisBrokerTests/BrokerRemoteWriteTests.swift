#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import Foundation
import XCTest
@testable import TrellisBroker

/// The helper's writes for dropped files (FR-RW20). Runs on macOS and Linux.
final class BrokerRemoteWriteTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = try XCTUnwrap(BrokerFiles.realPath(NSTemporaryDirectory())) + "/trellis-brw-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: root) }

    private func upload(_ bytes: Data, to folder: String, name: String, mode: Int = 0o644, replace: Bool = false) throws -> Result<Void, BrokerRemoteWrite.Failure> {
        let temp = try BrokerRemoteWrite.begin(directory: folder).get()
        try BrokerRemoteWrite.write(directory: folder, temp: temp, offset: 0, data: bytes).get()
        let result = BrokerRemoteWrite.finish(directory: folder, temp: temp, name: name, mode: mode, size: Int64(bytes.count), replace: replace)
        if case .failure = result { BrokerRemoteWrite.abort(directory: folder, temp: temp) }
        return result
    }

    /// "ok" or the failure, since `Void` isn't `Equatable`.
    private func code<T>(_ result: Result<T, BrokerRemoteWrite.Failure>) -> String {
        switch result {
        case .success: "ok"
        case .failure(let failure): "\(failure)"
        }
    }

    private func contents(_ path: String) -> String? { (try? Data(contentsOf: URL(fileURLWithPath: path))).map { String(decoding: $0, as: UTF8.self) } }
    private func mode(_ path: String) -> Int? { BrokerFiles.entry(path).map { Int($0.mode & 0o7777) } }
    private func names(_ folder: String) -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []) }

    func testNamesAndTemporaryNamesAreSingleSafeComponents() {
        XCTAssertTrue(BrokerRemoteWrite.isName("report 2.pdf"))
        for bad in ["", ".", "..", "a/b", "a\0b", String(repeating: "x", count: 256)] { XCTAssertFalse(BrokerRemoteWrite.isName(bad), bad) }
        XCTAssertTrue(BrokerRemoteWrite.isTemp(".trellis-upload-0123456789abcdef"))
        for bad in [".trellis-upload-0123", ".trellis-upload-0123456789ABCDEF", ".trellis-upload-0123456789abcdefg", "notes.txt"] { XCTAssertFalse(BrokerRemoteWrite.isTemp(bad), bad) }
        XCTAssertEqual(code(BrokerRemoteWrite.write(directory: root, temp: "notes.txt", offset: 0, data: Data())), "notAllowed", "Only an upload's own file is written")
        XCTAssertEqual(code(BrokerRemoteWrite.begin(directory: root + "/../x")), "notAllowed")
    }

    func testAFileIsWrittenUnderATemporaryNameAndMovedIntoPlaceWithItsPermissionBits() throws {
        let temp = try BrokerRemoteWrite.begin(directory: root).get()
        XCTAssertEqual(mode(root + "/" + temp), 0o600, "Owner-only while it is written")
        // Chunks in any order.
        try BrokerRemoteWrite.write(directory: root, temp: temp, offset: 3, data: Data("def".utf8)).get()
        try BrokerRemoteWrite.write(directory: root, temp: temp, offset: 0, data: Data("abc".utf8)).get()
        XCTAssertNil(contents(root + "/out.txt"), "Nothing has the real name until it is finished")
        XCTAssertEqual(code(BrokerRemoteWrite.finish(directory: root, temp: temp, name: "out.txt", mode: 0o6755, size: 6, replace: false)), "ok")
        XCTAssertEqual(contents(root + "/out.txt"), "abcdef")
        XCTAssertEqual(mode(root + "/out.txt"), 0o755, "Never setuid or setgid")
        XCTAssertEqual(names(root), ["out.txt"])
    }

    func testASizeThatDoesntMatchIsChanged() throws {
        let temp = try BrokerRemoteWrite.begin(directory: root).get()
        try BrokerRemoteWrite.write(directory: root, temp: temp, offset: 0, data: Data("abc".utf8)).get()
        XCTAssertEqual(code(BrokerRemoteWrite.finish(directory: root, temp: temp, name: "out.txt", mode: 0o644, size: 4, replace: false)), "changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/out.txt"))
    }

    func testATakenNameIsKeptUnlessReplacedAndAFolderIsNeverReplaced() throws {
        try Data("old".utf8).write(to: URL(fileURLWithPath: root + "/a.txt"))
        let temp = try BrokerRemoteWrite.begin(directory: root).get()
        try BrokerRemoteWrite.write(directory: root, temp: temp, offset: 0, data: Data("new".utf8)).get()
        XCTAssertEqual(code(BrokerRemoteWrite.finish(directory: root, temp: temp, name: "a.txt", mode: 0o644, size: 3, replace: false)), "exists")
        XCTAssertEqual(contents(root + "/a.txt"), "old")
        // The temporary file stays for another name.
        XCTAssertEqual(code(BrokerRemoteWrite.finish(directory: root, temp: temp, name: "a 2.txt", mode: 0o644, size: 3, replace: false)), "ok")
        XCTAssertEqual(contents(root + "/a 2.txt"), "new")
        XCTAssertEqual(code(try upload(Data("newer".utf8), to: root, name: "a.txt", replace: true)), "ok")
        XCTAssertEqual(contents(root + "/a.txt"), "newer")
        try FileManager.default.createDirectory(atPath: root + "/dir", withIntermediateDirectories: false)
        XCTAssertEqual(code(try upload(Data("x".utf8), to: root, name: "dir", replace: true)), "notAllowed")
        XCTAssertEqual(names(root), ["a.txt", "a 2.txt", "dir"], "A refused upload leaves nothing behind")
    }

    func testALinkIsNeverWrittenThrough() throws {
        try FileManager.default.createDirectory(atPath: root + "/real", withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: root + "/real/target.txt"))
        try FileManager.default.createSymbolicLink(atPath: root + "/linked", withDestinationPath: root + "/real")
        XCTAssertEqual(code(BrokerRemoteWrite.begin(directory: root + "/linked")), "notAllowed", "A folder that is a link")
        XCTAssertEqual(code(BrokerRemoteWrite.makeDirectory(root + "/linked/x", mode: 0o755)), "notAllowed")
        // A file name that is a link is replaced as an entry; its target keeps its contents.
        try FileManager.default.createSymbolicLink(atPath: root + "/real/link.txt", withDestinationPath: root + "/real/target.txt")
        XCTAssertEqual(code(try upload(Data("new".utf8), to: root + "/real", name: "link.txt", replace: true)), "ok")
        XCTAssertEqual(contents(root + "/real/target.txt"), "keep")
        XCTAssertEqual(BrokerFiles.entry(root + "/real/link.txt")?.kind, .file)
        // A temporary file swapped for a link isn't written.
        let temp = try BrokerRemoteWrite.begin(directory: root + "/real").get()
        unlink(root + "/real/" + temp)
        try FileManager.default.createSymbolicLink(atPath: root + "/real/" + temp, withDestinationPath: root + "/real/target.txt")
        XCTAssertEqual(code(BrokerRemoteWrite.write(directory: root + "/real", temp: temp, offset: 0, data: Data("bad".utf8))), "notAllowed")
        XCTAssertEqual(contents(root + "/real/target.txt"), "keep")
    }

    func testAbortIsIdempotentAndTouchesOnlyTemporaryFiles() throws {
        let temp = try BrokerRemoteWrite.begin(directory: root).get()
        BrokerRemoteWrite.abort(directory: root, temp: temp)
        BrokerRemoteWrite.abort(directory: root, temp: temp)
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/notes.txt"))
        BrokerRemoteWrite.abort(directory: root, temp: "notes.txt")
        XCTAssertEqual(names(root), ["notes.txt"])
    }

    func testStaleTemporaryFilesAreSweptAndRecentOnesKept() throws {
        let old = try BrokerRemoteWrite.begin(directory: root).get()
        let recent = try BrokerRemoteWrite.begin(directory: root).get()
        let later = Int64(time(nil)) + BrokerProtocol.uploadTempStaleAge + 10
        var times = [timeval(tv_sec: 0, tv_usec: 0), timeval(tv_sec: 0, tv_usec: 0)]
        XCTAssertEqual(utimes(root + "/" + old, &times), 0)
        // A day on, `recent` was touched just now.
        times = [timeval(tv_sec: Int(later), tv_usec: 0), timeval(tv_sec: Int(later), tv_usec: 0)]
        XCTAssertEqual(utimes(root + "/" + recent, &times), 0)
        let made = try BrokerRemoteWrite.begin(directory: root, sweep: true, now: later).get()
        XCTAssertEqual(names(root), [recent, made])
    }

    func testFoldersAreMadeAndEntriesMovedWithoutReplacing() throws {
        XCTAssertEqual(code(BrokerRemoteWrite.makeDirectory(root + "/docs", mode: 0o700)), "ok")
        XCTAssertEqual(code(BrokerRemoteWrite.makeDirectory(root + "/docs", mode: 0o755)), "exists")
        XCTAssertEqual(code(BrokerRemoteWrite.makeDirectory(root + "/missing/docs", mode: 0o755)), "notFound")
        try Data("a".utf8).write(to: URL(fileURLWithPath: root + "/a.txt"))
        try Data("b".utf8).write(to: URL(fileURLWithPath: root + "/docs/a.txt"))
        XCTAssertEqual(code(BrokerRemoteWrite.rename(from: root + "/a.txt", to: root + "/docs/a.txt")), "exists")
        XCTAssertEqual(contents(root + "/docs/a.txt"), "b")
        XCTAssertEqual(code(BrokerRemoteWrite.rename(from: root + "/a.txt", to: root + "/docs/c.txt")), "ok")
        XCTAssertEqual(contents(root + "/docs/c.txt"), "a")
        XCTAssertEqual(code(BrokerRemoteWrite.rename(from: root + "/docs", to: root + "/docs/inner")), "notAllowed", "Never into itself")
    }

    func testRequestsRoundTripAndAnOlderPathInfoStillDecodes() throws {
        for message: BrokerMessage in [
            .makeDirectory(path: "/a", mode: 0o755), .beginWrite(directory: "/a"), .writeStarted(temp: ".trellis-upload-0123456789abcdef"),
            .writeFileChunk(directory: "/a", temp: "t", offset: 5, data: Data([1, 2])), .finishWrite(directory: "/a", temp: "t", name: "n", mode: 0o644, size: 2, replace: true),
            .abortWrite(directory: "/a", temp: "t"), .renamePath(from: "/a", to: "/b")
        ] {
            let data = try JSONEncoder().encode(BrokerEnvelope(requestID: 1, message: message))
            XCTAssertEqual(try JSONDecoder().decode(BrokerEnvelope.self, from: data).message, message)
        }
        let old = Data(#"{"path":"/a","kind":"file","owned":true,"size":3}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(BrokerPathInfo.self, from: old).mode)
        XCTAssertEqual(BrokerRemoteFiles.describe([root])?.first?.mode, mode(root))
    }
}
