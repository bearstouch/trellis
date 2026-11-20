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

/// Review-driven checks of the helper's folder listings (FR-RW19). Runs on macOS and Linux.
final class BrokerRemoteBrowseReviewTests: XCTestCase {
    /// JSON writes a control character as six bytes and a quote or backslash as two: a folder of such names is cut
    /// short like any other, so its reply still fits a frame and the folder can be shown.
    func testAFolderOfNamesThatGrowAsJSONStillFitsAFrame() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-brr-\(UUID().uuidString.prefix(8))").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        // Each name is 230 control characters: 1.4 KB in the reply, six times what it is on disk.
        let filler = String(repeating: "\u{1}", count: 230)
        for index in 0..<800 {
            let fd = open(root + "/" + filler + String(index), O_CREAT | O_WRONLY, 0o600)
            XCTAssertGreaterThanOrEqual(fd, 0)
            if fd >= 0 { close(fd) }
        }
        let listings = try XCTUnwrap(BrokerRemoteBrowse.list([root]))
        XCTAssertEqual(listings.first?.state, .ok)
        XCTAssertEqual(listings.first?.truncated, true, "More names than a frame holds")
        XCTAssertGreaterThan(listings.first?.entries.count ?? 0, 100)
        XCTAssertNoThrow(try BrokerFrame.control(BrokerEnvelope(requestID: 1, message: .directories(listings))), "The reply fits one frame")

        XCTAssertEqual(BrokerRemoteBrowse.cost(BrokerDirectoryEntry(name: "a\"b\\c\u{1}", kind: .file)), 32 + 3 + 2 + 2 + 6)
    }
}
