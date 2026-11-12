import Darwin
import XCTest
import TrellisCore
@testable import TrellisControl

final class DeliveryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [[String: Any]] = []
    private var _bytes = 0
    var budget = Int.max
    var messages: [[String: Any]] { lock.withLock { _messages } }
    func deliver(_ data: Data) -> Bool {
        lock.withLock {
            guard _bytes + data.count <= budget else { return false }
            _bytes += data.count
            if let object = try? JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any] { _messages.append(object) }
            return true
        }
    }
}

/// What the event hub shares with every transport: the delivery budget, revocation, output cursors and the socket's
/// outbound limit. Typed events, replay, polling and redaction are in `EventsV2Tests`.
final class EventHubTests: XCTestCase {
    private let clock = TestClock()
    private let secrets = MemorySecrets()

    private func ref(_ space: UUID) -> PaneRefV2 { PaneRefV2(pane: UUID(), session: UUID(), tab: UUID(), space: space) }

    func testSlowOrRevokedSubscriberStops() async throws {
        let store = GrantStore(url: nil, secrets: secrets, now: { [clock] in clock.now })
        let (grant, _) = try await store.create(
            name: "r", capabilities: [.workspaceRead, .sessionOutputRead], spaceScope: .all, hostScope: .all, lifetime: 3600)
        let hub = EventHubV2(instanceID: UUID(), grants: store, now: { [clock] in clock.now })
        let slow = DeliveryLog()
        slow.budget = 2_000
        await hub.setDelivery { _, data in slow.deliver(data) }
        _ = await hub.subscribe(connectionID: UUID(), grant: grant, filter: EventFilterV2(topics: [.shell, .output]), afterSequence: nil, instanceID: nil)
        let space = UUID()
        for _ in 0..<50 { await hub.publish([.commandStarted(ref(space))]) }
        let delivered = slow.messages.count
        XCTAssertLessThan(delivered, 50, "Delivery stopped at the queue budget")
        let remaining = await hub.subscriptionCount
        XCTAssertEqual(remaining, 0, "The slow subscriber was dropped, retaining nothing")
        await hub.publishOutput(session: UUID(), spaceID: space, data: Data(repeating: 1, count: 10), next: OutputCursor(instanceID: UUID(), sessionID: UUID(), offset: 10))
        XCTAssertEqual(slow.messages.count, delivered)

        // A sequence ahead of now is refused rather than waited for.
        guard case .failure(let future) = await hub.subscribe(connectionID: UUID(), grant: grant, filter: EventFilterV2(topics: [.shell]), afterSequence: 5_000, instanceID: nil)
        else { return XCTFail("Accepted a future sequence") }
        XCTAssertEqual(future.appCode, "INVALID_CURSOR")

        // Revocation ends observation at the next event.
        let log = DeliveryLog()
        await hub.setDelivery { _, data in log.deliver(data) }
        _ = await hub.subscribe(connectionID: UUID(), grant: grant, filter: EventFilterV2(topics: [.shell]), afterSequence: nil, instanceID: nil)
        await hub.publish([.commandStarted(ref(space))])
        XCTAssertEqual(log.messages.count, 1)
        try await store.revoke(grant.id)
        await hub.publish([.commandStarted(ref(space))])
        XCTAssertEqual(log.messages.count, 1)
    }

    func testOutputEventsCarryStartCursorAndGap() async throws {
        let store = GrantStore(url: nil, secrets: secrets, now: { [clock] in clock.now })
        let (grant, _) = try await store.create(
            name: "o", capabilities: [.workspaceRead, .sessionOutputRead], spaceScope: .all, hostScope: .all, lifetime: 3600)
        let instance = UUID()
        let hub = EventHubV2(instanceID: instance, grants: store, now: { [clock] in clock.now })
        let log = DeliveryLog()
        await hub.setDelivery { _, data in log.deliver(data) }
        let connection = UUID()
        _ = await hub.subscribe(connectionID: connection, grant: grant, filter: EventFilterV2(topics: [.shell]), afterSequence: nil, instanceID: nil)
        guard case .success(let (subscription, _)) = await hub.subscribe(connectionID: connection, grant: grant, filter: EventFilterV2(topics: [.output]), afterSequence: nil, instanceID: nil)
        else { return XCTFail("Subscribe failed") }
        let session = UUID()
        await hub.publishOutput(session: session, spaceID: UUID(), data: Data("abc".utf8), next: OutputCursor(instanceID: instance, sessionID: session, offset: 10), gap: true)
        let data = try XCTUnwrap((log.messages.last?["params"] as? [String: Any])?["data"] as? [String: Any])
        XCTAssertEqual(data["cursor"] as? String, OutputCursor(instanceID: instance, sessionID: session, offset: 7).token)
        XCTAssertEqual(data["gap"] as? Bool, true)
        // Unsubscribed (or disconnected) subscribers receive nothing further.
        let removed = await hub.unsubscribe(subscription, connectionID: connection)
        XCTAssertTrue(removed)
        await hub.publishOutput(session: session, spaceID: nil, data: Data("d".utf8), next: OutputCursor(instanceID: instance, sessionID: session, offset: 11))
        XCTAssertEqual(log.messages.count, 1)
        let remaining = await hub.subscriptionCount
        XCTAssertEqual(remaining, 1, "The other subscription stays")
        XCTAssertFalse(hub.hasOutputSubscribers)
    }

    func testCursorTokenRoundTripAndRejectsGarbage() {
        let cursor = OutputCursor(instanceID: UUID(), sessionID: UUID(), offset: 1 << 40 | 7)
        XCTAssertEqual(OutputCursor(token: cursor.token), cursor)
        XCTAssertNil(OutputCursor(token: "oc1_short"))
        XCTAssertNil(OutputCursor(token: "x" + cursor.token))
    }

    func testServerDisconnectsAClientThatStopsReading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("te-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(mkdir(root.path, 0o700), 0)
        XCTAssertEqual(mkdir(root.appendingPathComponent("r").path, 0o700), 0)
        let handler = ConnectionCapture()
        let server = ControlServer(endpoint: ControlEndpoint(stateDirectory: root, runtimeRoot: root.appendingPathComponent("r")), handler: handler)
        let discovery = try server.start()
        defer { server.stop() }
        let client = try SocketClient(path: discovery.socketPath)
        defer { client.close() }
        _ = try client.request(#"{"jsonrpc":"2.0","id":1,"method":"auth.authenticate","params":{}}"#)
        let connection = try XCTUnwrap(handler.connectionID)
        // The client never reads; pushes fail once the 1 MiB outbound budget is exceeded.
        let chunk = Data(repeating: 0x20, count: 65_536) + Data([0x0A])
        var accepted = 0
        for _ in 0..<200 {
            guard server.push(chunk, to: connection) else { break }
            accepted += 1
        }
        XCTAssertLessThan(accepted, 200)
        XCTAssertFalse(server.push(chunk, to: connection), "The slow client was disconnected")
    }
}

/// Records the connection ID of the first authentication.
final class ConnectionCapture: ControlHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var _id: UUID?
    var connectionID: UUID? { lock.withLock { _id } }
    func authenticate(_ params: JSONValue?, connectionID: UUID, peerUID: uid_t) async -> Result<(ControlIdentity, JSONValue), ControlError> {
        lock.withLock { _id = connectionID }
        return .success((ControlIdentity(connectionID: connectionID, peerUID: peerUID), .object([:])))
    }
    func dispatch(_ method: String, params: JSONValue?, identity: ControlIdentity) async -> Result<JSONValue, ControlError> { .failure(.methodNotFound) }
}
