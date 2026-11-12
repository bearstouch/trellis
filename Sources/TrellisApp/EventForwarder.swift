import Foundation
import TrellisControl
import TrellisCore

/// Feeds the event hub from one FIFO consumer, so workspace, live-state and output events
/// reach subscribers in the order the workspace produced them.
final class EventForwarder: @unchecked Sendable {
    enum Item: Sendable {
        case output(session: UUID, space: UUID?, data: Data, next: UInt64, gap: Bool = false)
        /// A published transition, diffed here, off the main actor.
        case transition(WorkspaceSnapshot, WorkspaceSnapshot)
        /// Live-state and library events.
        case live([EventDraftV2])
    }

    /// Pending raw output allowed in flight; beyond it output events are
    /// skipped (readers recover through stream cursors). Other events are never
    /// dropped, so event sequences stay gap-free.
    static let outputBudget = 8 * 1_048_576
    private let continuation: AsyncStream<Item>.Continuation
    private let lock = NSLock()
    private var pendingOutput = 0
    /// Sessions whose output was skipped; their next event is flagged as a gap.
    private var skipped = Set<UUID>()

    /// `delivered` gets the spaces a transition closed once its events reached subscribers (closed spaces leave `created`
    /// scopes only then, so their grants still get the `space.deleted` event).
    init(hub: EventHubV2, instanceID: UUID, delivered: @escaping @Sendable (Set<UUID>) async -> Void = { _ in }) {
        let (stream, continuation) = AsyncStream<Item>.makeStream()
        self.continuation = continuation
        Task.detached { [self] in
            for await item in stream {
                switch item {
                case .output(let session, let space, let data, let next, let gap):
                    if hub.hasOutputSubscribers {
                        let cursor = OutputCursor(instanceID: instanceID, sessionID: session, offset: next)
                        await hub.publishOutput(session: session, spaceID: space, data: data, next: cursor, gap: gap)
                    }
                    lock.withLock { pendingOutput -= data.count }
                case .transition(let old, let new):
                    let events = WorkspaceDiffV2.diff(old, new)
                    guard !events.isEmpty else { continue }
                    await hub.publish(events)
                    let closed = Set(events.filter { $0.type == "space.deleted" }.compactMap(\.spaceID))
                    if !closed.isEmpty { await delivered(closed) }
                case .live(let events):
                    if !events.isEmpty { await hub.publish(events) }
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
