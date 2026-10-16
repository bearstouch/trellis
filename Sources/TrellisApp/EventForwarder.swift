import Foundation
import TrellisControl
import TrellisCore

/// Feeds the event hub from one FIFO consumer, so metadata and output events
/// reach subscribers in the order the workspace produced them.
final class EventForwarder: @unchecked Sendable {
    enum Item: Sendable {
        case metadata([WorkspaceEvent])
        case output(session: UUID, window: UUID?, data: Data, next: UInt64, gap: Bool = false)
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

    init(hub: EventHub, instanceID: UUID) {
        let (stream, continuation) = AsyncStream<Item>.makeStream()
        self.continuation = continuation
        Task.detached { [self] in
            for await item in stream {
                switch item {
                case .metadata(let events): await hub.publish(events)
                case .output(let session, let window, let data, let next, let gap):
                    await hub.publishOutput(
                        session: session, windowID: window, data: data, next: OutputCursor(instanceID: instanceID, sessionID: session, offset: next), gap: gap)
                    lock.withLock { pendingOutput -= data.count }
                }
            }
        }
    }

    func send(_ item: Item) {
        guard case .output(let session, let window, let data, let next, _) = item else {
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
        continuation.yield(.output(session: session, window: window, data: data, next: next, gap: gap))
    }
}
