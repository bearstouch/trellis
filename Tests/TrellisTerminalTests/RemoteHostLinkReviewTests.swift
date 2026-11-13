import Darwin
import Foundation
import TrellisCore
import XCTest

@testable import TrellisTerminal

/// ssh can exit before the host's last reply is read: that reply (e.g. `ERROR DIGEST` just before `exit 1`) must still name the failure.
final class RemoteHostLinkReviewTests: XCTestCase {
    func testAReplyBufferedWhenSSHExitsIsStillRead() async throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { Darwin.close(pair[1]) }
        let nonce = "0123456789abcdef"
        let channel = LinkChannel(fd: pair[0], nonce: nonce)
        // The peer stays open, so only the drain (not EOF) can end the reads.
        let line = Array("login noise\n\(RemoteBootstrap.replyPrefix)\(nonce) ERROR DIGEST\n".utf8)
        XCTAssertEqual(write(pair[1], line, line.count), line.count)

        channel.endAfterBuffered()
        guard case .error("DIGEST")? = await channel.reply() else { return XCTFail("The buffered error reply was dropped") }
        XCTAssertEqual(channel.lastError, "DIGEST")
        let started = Date()
        let after = await channel.reply()
        XCTAssertNil(after, "Nothing more is buffered, so the read ends")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "without waiting for a peer that has gone")
    }
}
