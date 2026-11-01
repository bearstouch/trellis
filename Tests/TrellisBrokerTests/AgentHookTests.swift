#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import Dispatch
import Foundation
import XCTest
@testable import TrellisBroker

/// FR-AG08: the pane-scoped agent hook channel.
final class AgentHookTests: XCTestCase {
    func testDatagramsCarryOnlyAKnownEventAndAWellFormedNonce() throws {
        let nonce = AgentHook.makeNonce()
        XCTAssertTrue(AgentHook.isNonce(nonce))
        XCTAssertNotEqual(nonce, AgentHook.makeNonce())
        let datagram = try XCTUnwrap(AgentHook.encode(nonce: nonce, event: "needs-input"))
        XCTAssertEqual(String(decoding: datagram, as: UTF8.self), "TRELLIS-AGENT-1 \(nonce) needs-input")
        XCTAssertEqual(AgentHook.decode(datagram)?.nonce, nonce)
        XCTAssertEqual(AgentHook.decode(datagram)?.event, "needs-input")
        XCTAssertNil(AgentHook.encode(nonce: nonce, event: "rm -rf"))
        XCTAssertNil(AgentHook.encode(nonce: "short", event: "done"))
        XCTAssertNil(AgentHook.encode(nonce: String(repeating: "Z", count: 32), event: "done"))
        for bad in ["TRELLIS-AGENT-2 \(nonce) done", "TRELLIS-AGENT-1 \(nonce) done extra", "TRELLIS-AGENT-1 \(nonce) prompt-text", "TRELLIS-AGENT-1  done"] {
            XCTAssertNil(AgentHook.decode(Array(bad.utf8)), bad)
        }
        XCTAssertNil(AgentHook.decode(Array("TRELLIS-AGENT-1 \(nonce) done\u{0}".utf8)))
        XCTAssertNil(AgentHook.decode([UInt8](repeating: 0x41, count: AgentHook.datagramLimit + 1)))
    }

    func testAHookStuckInALoopIsLimitedPerSession() {
        var limiter = AgentEventLimiter(limit: 3)
        XCTAssertEqual((0..<5).map { _ in limiter.allow("a", now: 10) }, [true, true, true, false, false])
        XCTAssertTrue(limiter.allow("b", now: 10.5), "Another session has its own budget")
        XCTAssertTrue(limiter.allow("a", now: 11.1), "A new second starts a new budget")
    }

    func testTheHookCommandAlwaysExitsZeroAndSendsNothingOutsideAnAgentSession() {
        XCTAssertEqual(AgentHook.main(arguments: ["trellis-broker", "agent-hook", "done"], environment: [:]), 0)
        XCTAssertEqual(AgentHook.main(arguments: ["trellis-broker", "agent-hook"], environment: [BrokerProtocol.agentSocketVariable: "/nonexistent"]), 0)
        XCTAssertEqual(
            AgentHook.main(
                arguments: ["trellis-broker", "agent-hook", "done"],
                environment: [BrokerProtocol.agentSocketVariable: "/nonexistent/agent.sock", BrokerProtocol.agentNonceVariable: AgentHook.makeNonce()]), 0)
    }

    func testTheReceiverDeliversValidDatagramsAndDropsTheRest() throws {
        let directory = try ownerOnlyDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/" + BrokerProtocol.agentSocketName
        let queue = DispatchQueue(label: "agent-hook-test")
        let received = Box()
        let receiver = AgentHookReceiver(path: path, queue: queue) { nonce, event in received.append("\(nonce.prefix(4)) \(event)") }
        try receiver.start()
        defer { receiver.stop() }
        let nonce = "abcd" + String(repeating: "0", count: 28)
        XCTAssertTrue(AgentHook.send(try XCTUnwrap(AgentHook.encode(nonce: nonce, event: "working")), to: path))
        XCTAssertTrue(AgentHook.send(Array("not a hook".utf8), to: path))
        XCTAssertTrue(AgentHook.send(try XCTUnwrap(AgentHook.encode(nonce: nonce, event: "done")), to: path))
        let deadline = Date().addingTimeInterval(3)
        while received.values.count < 2, Date() < deadline { usleep(10_000) }
        queue.sync {}
        XCTAssertEqual(received.values, ["abcd working", "abcd done"])
        // The hook command reaches it through the session's environment.
        XCTAssertEqual(
            AgentHook.main(
                arguments: ["trellis-broker", "agent-hook", "error"],
                environment: [BrokerProtocol.agentSocketVariable: path, BrokerProtocol.agentNonceVariable: nonce]), 0)
        while received.values.count < 3, Date() < deadline { usleep(10_000) }
        XCTAssertEqual(received.values.last, "abcd error")
    }

    func testTheReceiverRefusesAFolderOthersCanWriteAndReplacesOnlyAStaleSocket() throws {
        let open = NSTemporaryDirectory() + "trellis-agent-open-\(UUID().uuidString.prefix(8))"
        XCTAssertEqual(mkdir(open, 0o755), 0)
        defer { rmdir(open) }
        XCTAssertThrowsError(try AgentHookReceiver(path: open + "/agent.sock", queue: .main) { _, _ in }.start())

        let directory = try ownerOnlyDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/" + BrokerProtocol.agentSocketName
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: Data("keep".utf8)))
        XCTAssertThrowsError(try AgentHookReceiver(path: file, queue: .main) { _, _ in }.start(), "A regular file is never replaced")
        XCTAssertEqual(FileManager.default.contents(atPath: file), Data("keep".utf8))
    }

    func testOldBrokersAndAppsIgnoreTheNewFields() throws {
        let login = BrokerLoginRequest(sessionID: UUID(), shell: nil, directory: nil, environment: [:], integration: nil, columns: 80, rows: 24, command: "exec claude", agentHooks: true)
        let decoded = try JSONDecoder().decode(BrokerLoginRequest.self, from: JSONEncoder().encode(login))
        XCTAssertEqual(decoded, login)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(login)) as? [String: Any])
        object.removeValue(forKey: "agentHooks")
        XCTAssertNil(try JSONDecoder().decode(BrokerLoginRequest.self, from: JSONSerialization.data(withJSONObject: object)).agentHooks)
        let event = BrokerEnvelope(requestID: nil, message: .agentEvent(sessionID: UUID(), event: "done"))
        XCTAssertEqual(try JSONDecoder().decode(BrokerEnvelope.self, from: JSONEncoder().encode(event)), event)
    }

    private func ownerOnlyDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "trellis-agent-\(UUID().uuidString.prefix(8))"
        guard mkdir(path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return path
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ value: String) { lock.withLock { items.append(value) } }
        var values: [String] { lock.withLock { items } }
    }
}
