import Foundation
import TrellisCore

/// What a subscription or poll asks for: topics, and optionally resources and spaces (events.md).
public struct EventFilterV2: Sendable, Equatable {
    public var topics: Set<EventTopicV2>
    /// Matches the event's resource, its pane's session or tab, or its space.
    public var resourceIDs: Set<UUID>
    /// Matches the event's space; events without one (hosts, projects, appearance, grant) never match a space filter.
    public var spaceIDs: Set<UUID>

    public init(topics: Set<EventTopicV2>, resourceIDs: Set<UUID> = [], spaceIDs: Set<UUID> = []) {
        self.topics = topics; self.resourceIDs = resourceIDs; self.spaceIDs = spaceIDs
    }

    func matches(_ event: EventDraftV2) -> Bool {
        guard topics.contains(event.topic) else { return false }
        if !spaceIDs.isEmpty { guard let space = event.spaceID, spaceIDs.contains(space) else { return false } }
        if !resourceIDs.isEmpty { guard !resourceIDs.isDisjoint(with: event.matchIDs) else { return false } }
        return true
    }
}

/// Protocol 2's typed event stream (docs/api/v2/events.md): its own sequence and a replay ring of 2,000, separate from
/// protocol 1's `EventHub`, so v1 subscribers see exactly what they did before. Subscriptions are pushed on the socket as
/// `events.event`; `events.poll` long-polls on any transport. Every delivery re-reads the grant and redacts per event, so
/// a narrowing edit or a revocation applies to the next event. Live status is coalesced per resource and type.
public actor EventHubV2 {
    public static let ringCapacity = 2_000
    public static let maximumSubscriptions = 16
    /// Concurrent waiting polls per grant; more is LIMIT_EXCEEDED, so a client can't park unbounded work.
    public static let maximumPollsPerGrant = 4
    public static let maximumTimeoutMs = 25_000
    public static let defaultPollLimit = 100

    struct Stored: Sendable {
        let sequence: UInt64
        let at: Date
        let draft: EventDraftV2
        /// Grants that had created the event's space when it happened: a closed space leaves their `created` scope once
        /// its `space.deleted` was published, yet a later poll or replay still shows them that space's last events.
        var createdBy: Set<UUID> = []

        func data(for grant: AutomationGrant) -> [String: JSONValue]? { draft.data(for: grant, createdBy: createdBy) }
    }

    struct Subscription: Sendable {
        let id: UUID
        let connectionID: UUID
        let grantID: UUID
        let filter: EventFilterV2
        /// The sequence when it subscribed: replay covers up to it, live delivery what comes after.
        let start: UInt64
    }

    /// Delivery work in arrival order, drained by one loop so concurrent publishers never reorder what a client sees.
    private enum Work: Sendable {
        case event(Stored)
        case output(session: UUID, spaceID: UUID?, data: Data, next: OutputCursor, gap: Bool, at: Date)
        case revalidate(AutomationGrant)
    }

    private struct Slot {
        var emitted: ContinuousClock.Instant
        var data: [String: JSONValue]?
        var pending: EventDraftV2?
    }

    public nonisolated let instanceID: UUID
    private let grants: GrantStore
    private let now: @Sendable () -> Date
    private let window: Duration
    private var ring: [Stored] = []
    private var sequence: UInt64 = 0
    private var subscriptions: [UUID: Subscription] = [:]
    private var deliver: @Sendable (UUID, Data) -> Bool = { _, _ in false }
    private var queue: [Work] = []
    private var draining = false
    /// Publishers whose work another drain picked up: they return once it was delivered, so a caller that publishes and
    /// then prunes (`created` scopes after `space.deleted`) never prunes first.
    private var drained: [CheckedContinuation<Void, Never>] = []
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var polls: [UUID: Int] = [:]
    private var slots: [String: Slot] = [:]
    private var flushTask: Task<Void, Never>?
    private var flushAt: ContinuousClock.Instant?
    private let outputFlag = OutputFlag()

    /// `coalesceWindow`: live status is reported at most once per window per resource and type (events.md).
    public init(instanceID: UUID, grants: GrantStore, now: @escaping @Sendable () -> Date = { Date() }, coalesceWindow: Duration = .milliseconds(250)) {
        self.instanceID = instanceID; self.grants = grants; self.now = now; window = coalesceWindow
    }

    public func setDelivery(_ deliver: @escaping @Sendable (UUID, Data) -> Bool) { self.deliver = deliver }

    public var currentSequence: UInt64 { sequence }
    public var subscriptionCount: Int { subscriptions.count }
    /// Lets the output path skip the actor hop when nobody follows output.
    public nonisolated var hasOutputSubscribers: Bool { outputFlag.value }

    // MARK: Publishing

    /// Numbers the events, keeps them in the ring and delivers them. Live status (`EventTopicV2.coalescedTypes`) is
    /// coalesced: the first change goes out at once, later ones within the window wait and only the latest is sent.
    public func publish(_ drafts: [EventDraftV2]) async {
        var stored: [Stored] = []
        for draft in drafts {
            if draft.isCoalesced {
                if let event = coalesce(draft) { stored.append(append(event)) }
            } else {
                // A resource's last live status goes out before the event that ends it, never after.
                if Self.endingTypes.contains(draft.type), let id = ConventionsV2.parseID(draft.resourceID) { stored += flushPending(about: id).map { append($0) } }
                stored.append(append(draft))
            }
        }
        guard !stored.isEmpty else { return }
        queue.append(contentsOf: stored.map(Work.event))
        await drain()
    }

    /// Raw output is never kept in the ring and has no sequence; it carries stream cursors (`session.readOutput`).
    public func publishOutput(session: UUID, spaceID: UUID?, data: Data, next: OutputCursor, gap: Bool = false) async {
        guard !data.isEmpty, outputFlag.value else { return }
        queue.append(.output(session: session, spaceID: spaceID, data: data, next: next, gap: gap, at: now()))
        await drain()
    }

    private func append(_ draft: EventDraftV2) -> Stored {
        sequence += 1
        let createdBy = draft.spaceID.map { grants.createdSpaceLedger.grants(creating: $0) } ?? []
        let event = Stored(sequence: sequence, at: now(), draft: draft, createdBy: createdBy)
        ring.append(event)
        // Trimmed in batches, so appending stays cheap.
        if ring.count > Self.ringCapacity + 256 { ring.removeFirst(ring.count - Self.ringCapacity) }
        for waiter in waiters.values { waiter.resume() }
        waiters.removeAll()
        return event
    }

    private var oldestRetained: UInt64 {
        let floor = sequence > UInt64(Self.ringCapacity) ? sequence - UInt64(Self.ringCapacity) + 1 : 1
        return max(ring.first?.sequence ?? sequence + 1, floor)
    }

    // MARK: Coalescing

    /// The event to send now, or nil when it waits for the window (or changes nothing since the last one sent).
    private func coalesce(_ draft: EventDraftV2) -> EventDraftV2? {
        let key = draft.coalesceKey, clock = ContinuousClock.now
        if var slot = slots[key] {
            if slot.pending != nil || clock < slot.emitted.advanced(by: window) {
                slot.pending = draft
                slots[key] = slot
                scheduleFlush(at: slot.emitted.advanced(by: window))
                return nil
            }
        }
        return emit(draft, key: key, at: clock)
    }

    private func emit(_ draft: EventDraftV2, key: String, at clock: ContinuousClock.Instant) -> EventDraftV2? {
        var draft = draft
        let last = slots[key]?.data
        if draft.type == "agent.state", let previous = last?["state"] {
            // Clients see transitions between the states they were sent, never intermediate ones they weren't.
            guard previous != draft.data["state"] else { return nil }
            draft.data["previous"] = previous
        } else if let last, last == draft.data {
            return nil
        }
        slots[key] = Slot(emitted: clock, data: draft.data, pending: nil)
        if slots.count > 4_096 { slots = slots.filter { $0.value.pending != nil || clock < $0.value.emitted.advanced(by: .seconds(1)) } }
        return draft
    }

    static let endingTypes: Set<String> = ["space.deleted", "tab.deleted", "pane.deleted", "session.replaced", "session.exited", "agent.ended"]

    /// Pending live status about this resource (its pane, session, tab or space), sent now ahead of the event that ends it.
    private func flushPending(about id: UUID) -> [EventDraftV2] {
        let clock = ContinuousClock.now
        var due: [EventDraftV2] = []
        for (key, slot) in slots.sorted(by: { $0.value.emitted < $1.value.emitted }) {
            guard let pending = slot.pending, pending.matchIDs.contains(id) else { continue }
            slots[key]?.pending = nil
            if let event = emit(pending, key: key, at: clock) { due.append(event) }
        }
        return due
    }

    /// One timer for every key, set for the earliest window that ends.
    private func scheduleFlush(at deadline: ContinuousClock.Instant) {
        if let flushAt, flushTask != nil, flushAt <= deadline { return }
        flushTask?.cancel()
        flushAt = deadline
        flushTask = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Sends what waited for its window; the final state is never dropped.
    private func flush() async {
        flushTask = nil; flushAt = nil
        let clock = ContinuousClock.now
        var due: [EventDraftV2] = []
        var next: ContinuousClock.Instant?
        for (key, slot) in slots.sorted(by: { $0.value.emitted < $1.value.emitted }) {
            guard let pending = slot.pending else { continue }
            let at = slot.emitted.advanced(by: window)
            if at <= clock {
                slots[key]?.pending = nil
                if let event = emit(pending, key: key, at: clock) { due.append(event) }
            } else {
                next = min(next ?? at, at)
            }
        }
        if let next { scheduleFlush(at: next) }
        guard !due.isEmpty else { return }
        queue.append(contentsOf: due.map { Work.event(append($0)) })
        await drain()
    }

    // MARK: Delivery

    private func drain() async {
        guard !draining else {
            await withCheckedContinuation { drained.append($0) }
            return
        }
        draining = true
        defer {
            draining = false
            for waiter in drained { waiter.resume() }
            drained.removeAll()
        }
        while !queue.isEmpty {
            let batch = queue
            queue.removeAll()
            // One grant read per grant per batch: revocation, expiry and narrowing apply to the next event.
            var current: [UUID: AutomationGrant?] = [:]
            for grantID in Set(subscriptions.values.map(\.grantID)) where current[grantID] == nil { current[grantID] = await grants.activeGrant(id: grantID) }
            for work in batch {
                switch work {
                case .event(let event):
                    for subscription in subscriptions.values where event.sequence > subscription.start && subscription.filter.matches(event.draft) {
                        // Not read in this batch: it subscribed meanwhile, after this event (its replay covered it).
                        guard let fetched = current[subscription.grantID] else { continue }
                        guard let grant = fetched else {
                            subscriptions.removeValue(forKey: subscription.id)
                            continue
                        }
                        guard let data = event.data(for: grant) else { continue }
                        send(subscription, method: "events.event", params: envelope(event, data: data, subscription: subscription.id))
                    }
                case .output(let session, let spaceID, let data, let next, let gap, let at):
                    for subscription in subscriptions.values where subscription.filter.topics.contains(.output) {
                        guard let grant = current[subscription.grantID] ?? nil, grant.holds(.sessionOutputRead), spaceID.map(grant.reaches) ?? false,
                            subscription.filter.resourceIDs.isEmpty || subscription.filter.resourceIDs.contains(session) || spaceID.map(subscription.filter.resourceIDs.contains) == true,
                            subscription.filter.spaceIDs.isEmpty || spaceID.map(subscription.filter.spaceIDs.contains) == true
                        else { continue }
                        let start = OutputCursor(instanceID: next.instanceID, sessionID: next.sessionID, offset: next.offset - UInt64(data.count))
                        var params: [String: JSONValue] = [
                            "subscriptionId": ConventionsV2.idJSON(subscription.id), "instanceId": ConventionsV2.idJSON(instanceID), "type": .string("session.output"),
                            "topic": .string("output"), "at": .string(ConventionsV2.timestamp(at)),
                            "resource": .object(["kind": .string("session"), "id": ConventionsV2.idJSON(session)]),
                            "data": .object([
                                "base64": .string(data.base64EncodedString()), "cursor": .string(start.token), "nextCursor": .string(next.token), "gap": .bool(gap)
                            ])
                        ]
                        if let spaceID { params["spaceId"] = ConventionsV2.idJSON(spaceID) }
                        send(subscription, method: "events.event", params: params)
                    }
                case .revalidate(let grant):
                    subscriptions = subscriptions.filter { $0.value.grantID != grant.id || Self.allowed($0.value.filter.topics, grant) }
                }
            }
            updateOutputFlag()
        }
    }

    func envelope(_ event: Stored, data: [String: JSONValue], subscription: UUID? = nil) -> [String: JSONValue] {
        var resource: [String: JSONValue] = ["kind": .string(event.draft.resourceKind)]
        if !event.draft.resourceID.isEmpty { resource["id"] = .string(event.draft.resourceID) }
        var envelope: [String: JSONValue] = [
            "sequence": .number(Double(event.sequence)), "instanceId": ConventionsV2.idJSON(instanceID), "type": .string(event.draft.type),
            "topic": .string(event.draft.topic.rawValue), "at": .string(ConventionsV2.timestamp(event.at)), "resource": .object(resource), "data": .object(data)
        ]
        if let space = event.draft.spaceID { envelope["spaceId"] = ConventionsV2.idJSON(space) }
        if let subscription { envelope["subscriptionId"] = ConventionsV2.idJSON(subscription) }
        return envelope
    }

    private func send(_ subscription: Subscription, method: String, params: [String: JSONValue]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(JSONValue.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params)])) else { return }
        data.append(0x0A)
        // A connection whose outbound queue is over budget or gone loses every subscription (the server disconnects it).
        if !deliver(subscription.connectionID, data) { subscriptions = subscriptions.filter { $0.value.connectionID != subscription.connectionID } }
    }

    private func updateOutputFlag() { outputFlag.value = subscriptions.values.contains { $0.filter.topics.contains(.output) } }

    /// Whether a grant may follow these topics at all (what `events.subscribe` checks).
    static func allowed(_ topics: Set<EventTopicV2>, _ grant: AutomationGrant) -> Bool {
        topics.allSatisfy { $0.capabilities.isSubset(of: grant.capabilitiesV2) }
    }

    // MARK: Subscriptions (socket)

    /// Subscribes and replays retained matching events after `afterSequence`; when that was evicted, an `events.gap`
    /// notification asks the client to resnapshot before anything else.
    public func subscribe(
        connectionID: UUID, grant: AutomationGrant, filter: EventFilterV2, afterSequence: UInt64?, instanceID requested: UUID?
    ) -> Result<(id: UUID, sequence: UInt64), ControlError> {
        if let error = cursorError(afterSequence: afterSequence, instanceID: requested) { return .failure(error) }
        guard subscriptions.values.filter({ $0.connectionID == connectionID }).count < Self.maximumSubscriptions else {
            return .failure(.api(.limitExceeded, "Use at most 16 subscriptions per connection."))
        }
        let subscription = Subscription(id: UUID(), connectionID: connectionID, grantID: grant.id, filter: filter, start: sequence)
        subscriptions[subscription.id] = subscription
        updateOutputFlag()
        if let after = afterSequence {
            if after + 1 < oldestRetained {
                send(
                    subscription, method: "events.gap",
                    params: [
                        "subscriptionId": ConventionsV2.idJSON(subscription.id), "instanceId": ConventionsV2.idJSON(instanceID),
                        "oldestSequence": .number(Double(oldestRetained)), "action": .string("resnapshot")
                    ])
            } else {
                for event in ring where event.sequence > after && filter.matches(event.draft) {
                    guard let data = event.data(for: grant) else { continue }
                    send(subscription, method: "events.event", params: envelope(event, data: data, subscription: subscription.id))
                }
            }
        }
        return .success((subscription.id, sequence))
    }

    public func unsubscribe(_ id: UUID, connectionID: UUID) -> Bool {
        guard subscriptions[id]?.connectionID == connectionID else { return false }
        subscriptions.removeValue(forKey: id)
        updateOutputFlag()
        return true
    }

    public func removeConnection(_ connectionID: UUID) {
        subscriptions = subscriptions.filter { $0.value.connectionID != connectionID }
        updateOutputFlag()
    }

    /// A revoked grant: its subscriptions end and its waiting polls return AUTH_REQUIRED.
    public func removeGrant(_ grantID: UUID) {
        subscriptions = subscriptions.filter { $0.value.grantID != grantID }
        updateOutputFlag()
        for waiter in waiters.values { waiter.resume() }
        waiters.removeAll()
    }

    /// After an edit: `grant.changed` reaches the grant's own subscribers first, then subscriptions `events.subscribe` would
    /// now refuse end (in delivery order, so the event isn't lost to the removal).
    public func grantEdited(_ grant: AutomationGrant, narrowed: Bool) async {
        queue.append(.event(append(.grantChanged(grant))))
        if narrowed { queue.append(.revalidate(grant)) }
        await drain()
    }

    // MARK: Polling (any transport)

    /// Waits up to `timeoutMs` for the first event matching `filter` that the grant may see, then returns what is available
    /// up to `limit`. Never output. Waiting suspends only this call: the hub, other calls and the main actor carry on.
    public func poll(grantID: UUID, filter: EventFilterV2, afterSequence: UInt64?, instanceID requested: UUID?, timeoutMs: Int, limit: Int) async -> Result<
        JSONValue, ControlError
    > {
        if let error = cursorError(afterSequence: afterSequence, instanceID: requested) { return .failure(error) }
        let timeout = min(max(timeoutMs, 0), Self.maximumTimeoutMs)
        let limit = min(max(limit, 1), PageV2.maximumLimit)
        if timeout > 0 {
            guard polls[grantID, default: 0] < Self.maximumPollsPerGrant else {
                return .failure(.api(.limitExceeded, "Too many events.poll calls are waiting for this grant. Wait for one to return.", retryable: true))
            }
            polls[grantID, default: 0] += 1
        }
        defer {
            if timeout > 0 {
                let remaining = (polls[grantID] ?? 1) - 1
                polls[grantID] = remaining > 0 ? remaining : nil
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeout))
        var cursor = afterSequence ?? sequence
        while true {
            guard let grant = await grants.activeGrant(id: grantID) else {
                return .failure(.api(.authRequired, "This grant expired or was revoked. Authenticate again with a valid grant."))
            }
            if cursor + 1 < oldestRetained {
                return .success(
                    .object([
                        "events": .array([]), "nextSequence": .number(Double(sequence)), "instanceId": ConventionsV2.idJSON(instanceID),
                        "gap": .object(["oldestSequence": .number(Double(oldestRetained)), "action": .string("resnapshot")])
                    ]))
            }
            var events: [JSONValue] = []
            var scanned = cursor
            for event in ring where event.sequence > cursor {
                scanned = event.sequence
                if filter.matches(event.draft), let data = event.data(for: grant) {
                    events.append(.object(envelope(event, data: data)))
                    if events.count == limit { break }
                }
            }
            cursor = max(cursor, scanned)
            if !events.isEmpty || timeout == 0 || ContinuousClock.now >= deadline || Task.isCancelled {
                return .success(.object(["events": .array(events), "nextSequence": .number(Double(cursor)), "instanceId": ConventionsV2.idJSON(instanceID)]))
            }
            await waitForEvent(until: deadline)
        }
    }

    private func cursorError(afterSequence: UInt64?, instanceID requested: UUID?) -> ControlError? {
        // Sequences belong to one app instance; another instance's are never reinterpreted.
        if let requested, requested != instanceID {
            return .api(
                .invalidCursor, "These sequences belong to a previous app instance. Read workspace.get and start again without afterSequence.",
                details: .object(["instanceId": ConventionsV2.idJSON(instanceID)]))
        }
        if let after = afterSequence, after > sequence {
            return .api(.invalidCursor, "afterSequence is newer than this instance's events. Read workspace.get and start again without it.")
        }
        return nil
    }

    /// Returns at the next published event, the deadline, a revocation or cancellation, whichever is first.
    private func waitForEvent(until deadline: ContinuousClock.Instant) async {
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            await self?.wake(id)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { [weak self] in await self?.wake(id) }
        }
        timer.cancel()
    }

    private func wake(_ id: UUID) { waiters.removeValue(forKey: id)?.resume() }

    var waitingPolls: Int { waiters.count }
}

private final class OutputFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}
