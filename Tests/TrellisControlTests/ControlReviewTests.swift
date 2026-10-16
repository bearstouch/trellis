import Darwin
import XCTest
@testable import TrellisControl

final class ControlReviewTests: XCTestCase {
    /// NFR-R04: a frame of nested brackets must not overflow the decoder's stack.
    func testDeeplyNestedFramesAreRejectedWithoutCrashing() async throws {
        let handler = CountingHandler()
        for (open, close) in [("[", "]"), (#"{"a":"#, "}")] {
            for depth in [ControlSession.maximumNesting + 1, 5_000, 100_000] {
                let session = ControlSession(peerUID: geteuid(), handler: handler)
                let body = String(repeating: open, count: depth) + "1" + String(repeating: close, count: depth)
                let frame = Data((#"{"jsonrpc":"2.0","id":1,"method":"system.info","params":"# + body + "}\n").utf8)
                let result = await Task.detached { await session.receive(frame) }.value
                let reply = try XCTUnwrap(try responses(result.output).first)
                XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? Int, -32700)
            }
            // Legitimate nesting (the envelope plus params) still parses; brackets inside strings don't count.
            let nested = String(repeating: open, count: ControlSession.maximumNesting - 2) + #""[[{{""# + String(repeating: close, count: ControlSession.maximumNesting - 2)
            let request = Data((#"{"jsonrpc":"2.0","id":1,"method":"auth.authenticate","params":{"token":"letmein","x":"# + nested + "}}\n").utf8)
            let session = ControlSession(peerUID: geteuid(), handler: handler)
            let result = await Task.detached { await session.receive(request) }.value
            XCTAssertEqual(try responses(result.output).first?["result"] as? [String: Bool], ["authenticated": true])
        }
        XCTAssertTrue(handler.dispatches.isEmpty)
    }

    func testTricklingBytesAndPackedFramesStayCorrect() throws {
        var framer = ControlFramer()
        let request = #"{"jsonrpc":"2.0","method":"system.info"}"#
        var frames: [Data] = []
        for byte in Data((request + "\n").utf8) { frames += try framer.append(Data([byte])) }
        XCTAssertEqual(frames, [Data(request.utf8)])
        let packed = Data(String(repeating: request + "\n", count: 2_000).utf8) + Data("{\"tail\"".utf8)
        XCTAssertEqual(try framer.append(packed).count, 2_000)
        XCTAssertEqual(try framer.append(Data(":1}\n".utf8)), [Data(#"{"tail":1}"#.utf8)])
    }
}
