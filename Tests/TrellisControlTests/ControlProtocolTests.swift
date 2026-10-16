import Darwin
import XCTest
@testable import TrellisControl

/// Accepts the fixture token "letmein" and counts every domain dispatch.
final class CountingHandler: ControlHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var _dispatches: [String] = []
    var dispatches: [String] { lock.withLock { _dispatches } }

    func authenticate(_ params: JSONValue?, connectionID: UUID, peerUID: uid_t) async -> Result<(ControlIdentity, JSONValue), ControlError> {
        guard params?["token"] == .string("letmein") else { return .failure(.authenticationFailed) }
        return .success((ControlIdentity(connectionID: connectionID, peerUID: peerUID), .object(["authenticated": .bool(true)])))
    }

    func dispatch(_ method: String, params: JSONValue?, identity: ControlIdentity) async -> Result<JSONValue, ControlError> {
        lock.withLock { _dispatches.append(method) }
        return .success(.object(["method": .string(method)]))
    }
}

func responses(_ data: Data) throws -> [[String: Any]] {
    try data.split(separator: 0x0A).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
}

func appCode(_ response: [String: Any]) -> String? {
    ((response["error"] as? [String: Any])?["data"] as? [String: Any])?["code"] as? String
}

final class ControlProtocolTests: XCTestCase {
    func testFrameAcrossReads() throws {
        let first = #"{"jsonrpc":"2.0","id":1,"method":"session.input","params":{"text":"line one\nline two"}}"#
        let second = #"{"jsonrpc":"2.0","id":"b","method":"system.info"}"#
        let stream = Data((first + "\n" + second + "\r\n" + "{\"partial\":").utf8)
        for chunkSize in [1, 2, 7, 64, stream.count] {
            var framer = ControlFramer()
            var frames: [Data] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunkSize, stream.count)
                frames += try framer.append(stream.subdata(in: offset..<end))
                offset = end
            }
            XCTAssertEqual(frames.map { String(decoding: $0, as: UTF8.self) }, [first, second], "chunk \(chunkSize)")
            // The escaped newline stays inside the string after decoding.
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: frames[0]) as? [String: Any])
            XCTAssertEqual((decoded["params"] as? [String: Any])?["text"] as? String, "line one\nline two")
            XCTAssertEqual(try framer.append(Data("}\n".utf8)), [Data(#"{"partial":}"#.utf8)])
        }
        var exact = ControlFramer()
        let limit = Data(repeating: 0x20, count: ControlFramer.maximumFrame) + Data([0x0A])
        XCTAssertEqual(try exact.append(limit).first?.count, ControlFramer.maximumFrame)
    }

    func testRejectOversizedAndMalformedFrames() async throws {
        let handler = CountingHandler()
        let uid = geteuid()

        let oversized = ControlSession(peerUID: uid, handler: handler)
        let large = await oversized.receive(Data(repeating: 0x61, count: ControlFramer.maximumFrame + 1))
        XCTAssertTrue(large.close)
        XCTAssertEqual(try responses(large.output).map(appCode), ["LIMIT_EXCEEDED"])
        let afterClose = await oversized.receive(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"system.info\"}\n".utf8))
        XCTAssertTrue(afterClose.close)
        XCTAssertEqual(afterClose.output, Data())

        let encoding = ControlSession(peerUID: uid, handler: handler)
        let invalidUTF8 = await encoding.receive(Data([0x7B, 0xFF, 0xFE, 0x7D, 0x0A]))
        XCTAssertTrue(invalidUTF8.close)
        XCTAssertEqual(try responses(invalidUTF8.output).first?["id"] as? NSNull, NSNull())

        let session = ControlSession(peerUID: uid, handler: handler)
        let lines = [
            "{not json",
            #"[{"jsonrpc":"2.0","id":1,"method":"system.info"}]"#,
            #"{"jsonrpc":"2.0","method":"window.create","params":{"name":"x"}}"#,
            #"{"jsonrpc":"2.0","method":"system.info"}"#,
            #"{"jsonrpc":"1.0","id":2,"method":"system.info"}"#,
            #"{"jsonrpc":"2.0","id":null,"method":"system.info"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"system.info","params":"secret-ish"}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"window.list"}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"auth.authenticate","params":{"token":"wrong"}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"window.list"}"#
        ]
        let result = await session.receive(Data((lines.joined(separator: "\n") + "\n").utf8))
        XCTAssertFalse(result.close, "Malformed JSON inside a valid frame does not close the connection")
        let replies = try responses(result.output)
        XCTAssertEqual(
            replies.map { ($0["error"] as? [String: Any])?["code"] as? Int },
            [-32700, -32600, -32600, -32600, -32600, -32600, -32000, -32000, -32000])
        XCTAssertEqual(replies.map(appCode), [nil, nil, nil, nil, nil, nil, "AUTH_REQUIRED", "AUTH_REQUIRED", "AUTH_REQUIRED"])
        XCTAssertEqual(handler.dispatches, [], "Nothing reached the domain")
        XCTAssertFalse(String(decoding: result.output, as: UTF8.self).contains("secret-ish"), "Errors never echo input")
        XCTAssertFalse(String(decoding: result.output, as: UTF8.self).contains("wrong"))

        // The gate opens only after a successful authentication.
        let authed = await session.receive(
            Data((#"{"jsonrpc":"2.0","id":7,"method":"auth.authenticate","params":{"token":"letmein"}}"# + "\n" + #"{"jsonrpc":"2.0","id":8,"method":"window.list"}"# + "\n").utf8))
        XCTAssertEqual(try responses(authed.output).compactMap { $0["result"] as? [String: Any] }.count, 2)
        XCTAssertEqual(handler.dispatches, ["window.list"])
    }

    func testPeerFromAnotherUserIsDroppedBeforeParsing() async throws {
        let handler = CountingHandler()
        let session = ControlSession(peerUID: geteuid() &+ 1, expectedUID: geteuid(), handler: handler)
        let result = await session.receive(Data((#"{"jsonrpc":"2.0","id":1,"method":"auth.authenticate","params":{"token":"letmein"}}"# + "\n").utf8))
        XCTAssertTrue(result.close)
        XCTAssertEqual(result.output, Data())
        XCTAssertEqual(handler.dispatches, [])
    }
}
