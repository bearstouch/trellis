import Foundation
import TrellisControl
import TrellisCore

/// Feeds the event hub from one FIFO consumer, so metadata and output events
/// reach subscribers in the order the workspace produced them.
final class EventForwarder: @unchecked Sendable {
    enum Item: Sendable {
        case metadata([WorkspaceEvent])
        case output(session: UUID, space: UUID?, data: Data, next: UInt64, gap: Bool = false)
        /// Protocol 2: a published transition, diffed here, off the main actor.
        case transition(WorkspaceSnapshot, WorkspaceSnapshot)
        /// Protocol 2 live-state and library events.
        case live([EventDraftV2])
    }

    /// Pending raw output allowed in flight; beyond it output events are
    /// skipped (readers recover through stream cursors). Metadata is never
    /// dropped, so event sequences stay gap-free.
    static let outputBudget = 8 * 1_048_576
    private let continuation: AsyncStream<Item>.Continuation
    private let lock = NSLock()
    private var pendingOutput = 0
    /// Sessions whose output was skipped; their next event is flagged as a gap.
    private var skipped = Set<UUID>()

    /// `delivered` runs after each metadata batch reached subscribers (closed spaces leave `created` scopes only then, so
    /// their grants still get the `space.deleted` event).
    init(hub: EventHub, hubV2: EventHubV2? = nil, instanceID: UUID, delivered: @escaping @Sendable ([WorkspaceEvent]) async -> Void = { _ in }) {
        let (stream, continuation) = AsyncStream<Item>.makeStream()
        self.continuation = continuation
        Task.detached { [self] in
            for await item in stream {
                switch item {
                case .metadata(let events):
                    await hub.publish(events)
                    await delivered(events)
                case .output(let session, let space, let data, let next, let gap):
                    let cursor = OutputCursor(instanceID: instanceID, sessionID: session, offset: next)
                    await hub.publishOutput(session: session, spaceID: space, data: data, next: cursor, gap: gap)
                    if let hubV2, hubV2.hasOutputSubscribers { await hubV2.publishOutput(session: session, spaceID: space, data: data, next: cursor, gap: gap) }
                    lock.withLock { pendingOutput -= data.count }
                case .transition(let old, let new):
                    let events = WorkspaceDiffV2.diff(old, new)
                    if let hubV2, !events.isEmpty { await hubV2.publish(events) }
                case .live(let events):
                    if let hubV2, !events.isEmpty { await hubV2.publish(events) }
                }
            }
        }
    }

    func send(_ item: Item) {
        guard case .output(let session, let space, let data, let next, _) = item else {
            continuation.yield(item)
            return
        }
        let gap = lock.withLock { () -> Bool? in
            guard pendingOutput + data.count <= Self.outputBudget else {
                skipped.insert(session)
                return nil
            }
            pendingOutput += data.count
            return skipped.remove(session) != nil
        }
        guard let gap else { return }
        continuation.yield(.output(session: session, space: space, data: data, next: next, gap: gap))
    }
}
