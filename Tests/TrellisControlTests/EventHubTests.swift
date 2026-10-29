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

final class EventHubTests: XCTestCase {
    private let clock = TestClock()
    private let secrets = MemorySecrets()

    private func event(_ window: UUID, _ type: String = "window.updated") -> WorkspaceEvent {
        WorkspaceEvent(type: type, resourceID: window, windowID: window, data: ["revision": "1"])
    }

    func testMetadataReplayGap() async throws {
        let store = GrantStore(url: nil, secrets: secrets, now: { [clock] in clock.now })
        let (grant, _) = try await store.create(name: "r", capabilities: [.metadataRead], windowScope: .all, hostScope: .all, lifetime: 3600)
        let hub = EventHub(instanceID: UUID(), grants: store, now: { [clock] in clock.now })
        let log = DeliveryLog()
        await hub.setDelivery { _, data in log.deliver(data) }
        let window = UUID()
        await hub.publish((0..<1_001).map { _ in event(window) })
        let current = await hub.currentSequence
        XCTAssertEqual(current, 1_001)

        // Sequence 1 was evicted: the client is told to resnapshot, nothing is replayed.
        let gapped = await hub.subscribe(connectionID: UUID(), grant: grant, topics: ["resources"], resourceIDs: [], afterSequence: 0)
        XCTAssertNotNil(try? gapped.get())
        XCTAssertEqual(log.messages.map { $0["method"] as? String }, ["events.gap"])
        XCTAssertEqual((log.messages[0]["params"] as? [String: Any])?["oldestSequence"] as? Int, 2)
        XCTAssertEqual((log.messages[0]["params"] as? [String: Any])?["action"] as? String, "resnapshot")

        // From the oldest retained sequence, all 1,000 retained events replay in order.
        _ = await hub.subscribe(connectionID: UUID(), grant: grant, topics: ["resources"], resourceIDs: [], afterSequence: 1)
        let replayed = log.messages.dropFirst().compactMap { ($0["params"] as? [String: Any])?["sequence"] as? Int }
        XCTAssertEqual(replayed, Array(2...1_001))
        let future = await hub.subscribe(connectionID: UUID(), grant: grant, topics: ["resources"], resourceIDs: [], afterSequence: 5_000)
        guard case .failure(let error) = future else { return XCTFail("Accepted a future sequence") }
        XCTAssertEqual(error.appCode, "INVALID_CURSOR")
    }

    func testReplayKeepsToTheSubscribedTopics() async throws {
        let store = GrantStore(url: nil, secrets: secrets, now: { [clock] in clock.now })
        let (grant, _) = try await store.create(name: "r", capabilities: [.metadataRead], windowScope: .all, hostScope: .all, lifetime: 3600)
        let hub = EventHub(instanceID: UUID(), grants: store, now: { [clock] in clock.now })
        let log = DeliveryLog()
        await hub.setDelivery { _, data in log.deliver(data) }
        let window = UUID()
        await hub.publish([event(window), event(window, "selection.changed"), event(window, "session.state"), event(window, "selection.changed")])
        _ = await hub.subscribe(connectionID: UUID(), grant: grant, topics: ["selection"], resourceIDs: [], afterSequence: 0)
        let replayed = log.messages.compactMap { ($0["params"] as? [String: Any])?["sequence"] as? Int }
        XCTAssertEqual(replayed, [2, 4], "Only selection events replay, as they would have been delivered live")
    }

    func testSlowOrRevokedSubscriberStops() async throws {
        let store = GrantStore(url: nil, secrets: secrets, now: { [clock] in clock.now })
        let (grant, _) = try await store.create(name: "r", capabilities: [.metadataRead, .sessionOutputRead], windowScope: .all, hostScope: .all, lifetime: 3600)
        let hub = EventHub(instanceID: UUID(), grants: store, now: { [clock] in clock.now })
        let slow = DeliveryLog()
        slow.budget = 2_000
        let slowConnection = UUID()
        await hub.setDelivery { _, data in slow.deliver(data) }
        _ = await hub.subscribe(connectionID: slowConnection, grant: grant, topics: ["resources", "output"], resourceIDs: [], afterSequence: nil)
        let window = UUID()
        for _ in 0..<50 { await hub.publish([event(window)]) }
        let delivered = slow.messages.count
        XCTAssertLessThan(delivered, 50, "Delivery stopped at the queue budget")
        let remaining = await hub.subscriptionCount
        XCTAssertEqual(remaining, 0, "The slow subscriber was dropped, retaining nothing")
        await hub.publishOutput(session: UUID(), windowID: window, data: Data(repeating: 1, count: 10), next: OutputCursor(instanceID: UUID(), sessionID: UUID(), offset: 10))
        XCTAssertEqual(slow.messages.count, delivered)

        // Revocation ends observation at the next event.
        let log = DeliveryLog()
        await hub.setDelivery { _, data in log.deliver(data) }
        _ = await hub.subscribe(connectionID: UUID(), grant: grant, topics: ["resources"], resourceIDs: [], afterSequence: nil)
        await hub.publish([event(window)])
        XCTAssertEqual(log.messages.count, 1)
        try await store.revoke(grant.id)
        await hub.publish([event(window)])
        XCTAssertEqual(log.messages.count, 1)
        let afterRevoke = await hub.subscriptionCount
        XCTAssertEqual(afterRevoke, 0)
    }

    func testRedactionByScopeAndOutputCapability() async throws {
        let store = GrantStore(url: nil, secrets: secrets, now: { [clock] in clock.now })
        let visible = UUID(), hidden = UUID()
        let (scoped, _) = try await store.create(name: "s", capabilities: [.metadataRead], windowScope: .windows([visible]), hostScope: .all, lifetime: 3600)
        let hub = EventHub(instanceID: UUID(), grants: store, now: { [clock] in clock.now })
        let log = DeliveryLog()
        await hub.setDelivery { _, data in log.deliver(data) }
        _ = await hub.subscribe(connectionID: UUID(), grant: scoped, topics: ["resources", "session", "output"], resourceIDs: [], afterSequence: nil)
        await hub.publish([event(hidden), event(visible), WorkspaceEvent(type: "session.state", resourceID: UUID(), windowID: hidden, data: ["state": "running"])])
        await hub.publishOutput(session: UUID(), windowID: visible, data: Data("secret".utf8), next: OutputCursor(instanceID: UUID(), sessionID: UUID(), offset: 6))
        XCTAssertEqual(log.messages.compactMap { ($0["params"] as? [String: Any])?["resourceId"] as? String }, [visible.uuidString])
        XCTAssertFalse(log.messages.description.contains(hidden.uuidString))
    }

    func testOutputEventsCarryStartCursorAndGap() async throws {
        let store = GrantStore(url: nil, secrets: secrets, now: { [clock] in clock.now })
        let (grant, _) = try await store.create(name: "o", capabilities: [.metadataRead, .sessionOutputRead], windowScope: .all, hostScope: .all, lifetime: 3600)
        let instance = UUID()
        let hub = EventHub(instanceID: instance, grants: store, now: { [clock] in clock.now })
        let log = DeliveryLog()
        await hub.setDelivery { _, data in log.deliver(data) }
        let connection = UUID()
        guard case .success(let subscription) = await hub.subscribe(connectionID: connection, grant: grant, topics: ["output"], resourceIDs: [], afterSequence: nil) else {
            return XCTFail("Subscribe failed")
        }
        let session = UUID()
        await hub.publishOutput(session: session, windowID: UUID(), data: Data("abc".utf8), next: OutputCursor(instanceID: instance, sessionID: session, offset: 10), gap: true)
        let data = try XCTUnwrap((log.messages.last?["params"] as? [String: Any])?["data"] as? [String: Any])
        XCTAssertEqual(data["cursor"] as? String, OutputCursor(instanceID: instance, sessionID: session, offset: 7).token)
        XCTAssertEqual(data["gap"] as? Bool, true)
        // Unsubscribed (or disconnected) subscribers receive nothing further.
        let removed = await hub.unsubscribe(subscription.id, connectionID: connection)
        XCTAssertTrue(removed)
        await hub.publishOutput(session: session, windowID: nil, data: Data("d".utf8), next: OutputCursor(instanceID: instance, sessionID: session, offset: 11))
        XCTAssertEqual(log.messages.count, 1)
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
