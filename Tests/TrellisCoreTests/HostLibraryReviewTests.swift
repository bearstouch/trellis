import Darwin
import XCTest
@testable import TrellisCore

final class HostLibraryReviewTests: XCTestCase {
    func testUserRejectsShellMetacharactersExpandedBySshTokens() throws {
        for user in ["$(touch x)", "`id`", "a;b", "a|b", "a'b", "a\"b", "a&b", "a<b", "a\\b", "{a}"] {
            XCTAssertThrowsError(try HostDraft(name: "a", destination: "h", user: user).validated { _ in true }, user)
        }
        XCTAssertEqual(try HostDraft(name: "a", destination: "h", user: "deploy.user_1-x").validated { _ in true }.user, "deploy.user_1-x")
    }

    func testHostRevisionAboveLibraryRevisionIsRejected() throws {
        let host = SavedHost(id: UUID(), draft: try HostDraft(name: "a", destination: "h").validated { _ in true }, revision: 9)
        XCTAssertThrowsError(try HostLibraryCodec.decode(try HostLibraryCodec.encode([host], revision: 3)))
        XCTAssertEqual(try HostLibraryCodec.decode(try HostLibraryCodec.encode([host], revision: 9)).hosts, [host])
    }

    func testResetKeepsOversizedUnreadableFile() async throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-hosts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let original = Data(repeating: 0x20, count: HostLibraryCodec.byteLimit + 1)
        try original.write(to: state.appendingPathComponent("hosts.json"))
        let library = HostLibrary(storage: HostFileStorage(directory: state))
        let loaded = await library.load()
        XCTAssertFalse(loaded)
        try await library.resetUnreadable()
        let kept = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: state.path).first { $0.hasPrefix("hosts.unreadable.") })
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent(kept)), original)
        let reloaded = HostLibrary(storage: HostFileStorage(directory: state))
        let reloadedOK = await reloaded.load()
        XCTAssertTrue(reloadedOK)
    }
}
