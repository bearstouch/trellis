import Foundation
import TrellisCore

/// Opaque stream cursor: instance + session + absolute byte offset.
/// A cursor from another session or app instance is rejected, never reinterpreted.
public struct OutputCursor: Equatable, Sendable {
    public let instanceID: UUID
    public let sessionID: UUID
    public let offset: UInt64

    public init(instanceID: UUID, sessionID: UUID, offset: UInt64) {
        self.instanceID = instanceID; self.sessionID = sessionID; self.offset = offset
    }

    public var token: String {
        var bytes = [UInt8]()
        withUnsafeBytes(of: instanceID.uuid) { bytes += $0 }
        withUnsafeBytes(of: sessionID.uuid) { bytes += $0 }
        withUnsafeBytes(of: offset.bigEndian) { bytes += $0 }
        return "oc1_"
            + Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(token: String) {
        guard token.hasPrefix("oc1_"), token.utf8.count <= 64 else { return nil }
        var text = String(token.dropFirst(4)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text), data.count == 40 else { return nil }
        let bytes = [UInt8](data)
        func uuid(_ at: Int) -> UUID {
            UUID(
                uuid: (
                    bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3], bytes[at + 4], bytes[at + 5], bytes[at + 6], bytes[at + 7],
                    bytes[at + 8], bytes[at + 9], bytes[at + 10], bytes[at + 11], bytes[at + 12], bytes[at + 13], bytes[at + 14], bytes[at + 15]
                ))
        }
        instanceID = uuid(0)
        sessionID = uuid(16)
        offset = bytes[32..<40].reduce(0) { $0 << 8 | UInt64($1) }
    }
}

/// Ordered metadata events with a bounded replay ring, plus separately bounded
/// raw output delivery. Every delivery re-checks the subscriber's grant.
public actor EventHub {
    public static let ringCapacity = 1_000
    public static let topics: Set<String> = ["resources", "selection", "session", "output", "appearance"]

    struct Event: Sendable {
        let sequence: UInt64
        let timestamp: Date
        let event: WorkspaceEvent
    }

    struct Subscription: Sendable {
        let id: UUID
        let connectionID: UUID
        let grantID: UUID
        let topics: Set<String>
        let resourceIDs: Set<UUID>
    }

    public let instanceID: UUID
    private let grants: GrantStore
    private let now: @Sendable () -> Date
    private var ring: [Event] = []
    private var sequence: UInt64 = 0
    private var subscriptions: [UUID: Subscription] = [:]
    /// Returns false when the connection's outbound queue is over budget or gone;
    /// the subscription is then dropped (the server disconnects slow clients).
    private var deliver: @Sendable (UUID, Data) -> Bool = { _, _ in false }

    public init(instanceID: UUID, grants: GrantStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.instanceID = instanceID; self.grants = grants; self.now = now
    }

    public func setDelivery(_ deliver: @escaping @Sendable (UUID, Data) -> Bool) { self.deliver = deliver }

    public var currentSequence: UInt64 { sequence }
    public var subscriptionCount: Int { subscriptions.count }

    /// Subscribes and replays retained events after `afterSequence`. When that
    /// sequence was already evicted, an `events.gap` notification asks the
    /// client to resnapshot before any replay.
    public func subscribe(
        connectionID: UUID, grant: AutomationGrant, topics: Set<String>, resourceIDs: Set<UUID>, afterSequence: UInt64?
    ) -> Result<(id: UUID, sequence: UInt64), ControlError> {
        guard !topics.isEmpty, topics.isSubset(of: Self.topics) else {
            return .failure(.invalidParams("topics must be a non-empty subset of resources, selection, session, output.", fields: ["topics": "resources, selection, session, output"]))
        }
        guard subscriptions.values.filter({ $0.connectionID == connectionID }).count < 16 else {
            return .failure(.application("LIMIT_EXCEEDED", "Use at most 16 subscriptions per connection."))
        }
        let subscription = Subscription(id: UUID(), connectionID: connectionID, grantID: grant.id, topics: topics, resourceIDs: resourceIDs)
        subscriptions[subscription.id] = subscription
        if let after = afterSequence {
            let oldest = ring.first?.sequence ?? sequence + 1
            if after > sequence {
                subscriptions.removeValue(forKey: subscription.id)
                return .failure(.application("INVALID_CURSOR", "afterSequence is newer than this instance's events. Resnapshot and subscribe without it."))
            }
            if after + 1 < oldest {
                send(
                    subscription, method: "events.gap",
                    params: ["subscriptionId": .string(subscription.id.uuidString), "instanceId": .string(instanceID.uuidString), "oldestSequence": .number(Double(oldest)), "action": .string("resnapshot")])
            } else {
                for event in ring where event.sequence > after && topics.contains(event.event.topic) { deliverEvent(event, to: subscription, grant: grant) }
            }
        }
        return .success((subscription.id, sequence))
    }

    public func unsubscribe(_ id: UUID, connectionID: UUID) -> Bool {
        guard subscriptions[id]?.connectionID == connectionID else { return false }
        subscriptions.removeValue(forKey: id)
        return true
    }

    public func removeConnection(_ connectionID: UUID) { subscriptions = subscriptions.filter { $0.value.connectionID != connectionID } }

    public func removeGrant(_ grantID: UUID) { subscriptions = subscriptions.filter { $0.value.grantID != grantID } }

    /// Records metadata events in the ring and delivers them in order.
    public func publish(_ events: [WorkspaceEvent]) async {
        for workspaceEvent in events {
            sequence += 1
            let event = Event(sequence: sequence, timestamp: now(), event: workspaceEvent)
            ring.append(event)
            if ring.count > Self.ringCapacity { ring.removeFirst(ring.count - Self.ringCapacity) }
            for subscription in subscriptions.values where subscription.topics.contains(workspaceEvent.topic) {
                guard let grant = await activeGrant(subscription) else { continue }
                deliverEvent(event, to: subscription, grant: grant)
            }
        }
    }

    /// Raw output is never stored in the metadata ring; it carries a stream cursor.
    /// `gap` marks output skipped since the previous event for this session; each
    /// event also carries its start `cursor`, so readers can detect and backfill holes.
    public func publishOutput(session: UUID, windowID: UUID?, data: Data, next: OutputCursor, gap: Bool = false) async {
        guard !data.isEmpty else { return }
        for subscription in subscriptions.values where subscription.topics.contains("output") {
            guard let grant = await activeGrant(subscription), grant.allows(.sessionOutputRead), visible(windowID, grant),
                subscription.resourceIDs.isEmpty || subscription.resourceIDs.contains(session)
            else { continue }
            send(
                subscription, method: "event",
                params: [
                    "subscriptionId": .string(subscription.id.uuidString), "instanceId": .string(instanceID.uuidString),
                    "timestamp": .string(ISO8601DateFormatter().string(from: now())), "type": .string("session.output"),
                    "resourceId": .string(session.uuidString),
                    "data": .object([
                        "base64": .string(data.base64EncodedString()), "nextCursor": .string(next.token), "gap": .bool(gap),
                        "cursor": .string(OutputCursor(instanceID: next.instanceID, sessionID: next.sessionID, offset: next.offset - UInt64(data.count)).token)
                    ])
                ])
        }
    }

    /// Expired or revoked grants end observation at the next event.
    private func activeGrant(_ subscription: Subscription) async -> AutomationGrant? {
        guard let grant = await grants.activeGrant(id: subscription.grantID) else {
            subscriptions.removeValue(forKey: subscription.id)
            return nil
        }
        // Reentrancy: an unsubscribe, disconnect or revocation during the await wins.
        return subscriptions[subscription.id] == nil ? nil : grant
    }

    private func visible(_ windowID: UUID?, _ grant: AutomationGrant) -> Bool {
        switch grant.windowScope {
        case .all: true
        case .windows(let ids): windowID.map(ids.contains) ?? false
        }
    }

    private func deliverEvent(_ event: Event, to subscription: Subscription, grant: AutomationGrant) {
        let workspace = event.event
        if workspace.topic == "appearance" {
            // Appearance is global: it needs theme.read, independent of window scope.
            guard grant.allows(.themeRead) else { return }
        } else {
            guard visible(workspace.windowID, grant) || (workspace.type == "window.reordered" && grant.windowScope == .all) else { return }
        }
        guard
            subscription.resourceIDs.isEmpty || subscription.resourceIDs.contains(workspace.resourceID)
                || workspace.windowID.map(subscription.resourceIDs.contains) == true
        else { return }
        send(
            subscription, method: "event",
            params: [
                "subscriptionId": .string(subscription.id.uuidString), "sequence": .number(Double(event.sequence)),
                "instanceId": .string(instanceID.uuidString), "timestamp": .string(ISO8601DateFormatter().string(from: event.timestamp)),
                "type": .string(workspace.type), "resourceId": .string(workspace.resourceID.uuidString),
                "data": .object(workspace.data.mapValues(JSONValue.string))
            ])
    }

    private func send(_ subscription: Subscription, method: String, params: [String: JSONValue]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(JSONValue.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params)])) else { return }
        data.append(0x0A)
        if !deliver(subscription.connectionID, data) { subscriptions = subscriptions.filter { $0.value.connectionID != subscription.connectionID } }
    }
}
