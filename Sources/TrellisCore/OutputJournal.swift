import Foundation

/// In-memory raw PTY output for automation readers. Bytes keep absolute
/// per-session offsets; one global budget evicts the oldest chunks first,
/// across all sessions. Nothing here is ever persisted.
public struct OutputJournal: Sendable {
    public static let defaultBudget = 8 * 1_048_576
    /// Small reads coalesce up to this size, so chunk count (and per-chunk
    /// overhead) stays proportional to retained bytes, not to read count.
    static let coalesceLimit = 16_384
    private struct Stream: Sendable {
        var base: UInt64 = 0
        var chunks: [Data] = []
        /// Index of the oldest retained chunk; evicted slots are compacted lazily.
        var head = 0
        var bytes = 0
        var end: UInt64 { base + UInt64(bytes) }

        /// True when a new chunk was started (it then needs an eviction-order entry).
        mutating func append(_ chunk: Data) -> Bool {
            bytes += chunk.count
            if head < chunks.count, chunks[chunks.count - 1].count + chunk.count <= OutputJournal.coalesceLimit {
                chunks[chunks.count - 1].append(chunk)
                return false
            }
            chunks.append(chunk)
            return true
        }

        mutating func evictOldest() -> Int {
            guard head < chunks.count else { return 0 }
            let count = chunks[head].count
            chunks[head] = Data()
            head += 1
            base += UInt64(count)
            bytes -= count
            if head > 64, head * 2 > chunks.count { chunks.removeFirst(head); head = 0 }
            return count
        }
    }
    public let budget: Int
    private var streams: [UUID: Stream] = [:]
    /// Arrival order of retained chunks, for global oldest-first eviction.
    private var order: [UUID] = []
    private var orderStart = 0
    public private(set) var retainedBytes = 0

    public init(budget: Int = OutputJournal.defaultBudget) { self.budget = budget }

    public enum ReadError: Error, Equatable, Sendable { case unknownSession, offsetBeyondEnd }

    public struct Read: Equatable, Sendable {
        public let data: Data
        public let start: UInt64
        public let next: UInt64
        /// Bytes between the requested offset and `start` were evicted.
        public let gap: Bool
        /// More retained bytes follow `next`.
        public let truncated: Bool
    }

    public mutating func append(_ data: Data, session: UUID) {
        guard !data.isEmpty else { return }
        var offset = 0
        while offset < data.count {
            // Bounded chunks keep eviction granular.
            let chunk = data.subdata(in: offset..<min(offset + 65_536, data.count))
            offset += chunk.count
            retainedBytes += chunk.count
            // Mutated in place: copying a stream out would copy its chunk array.
            if streams[session, default: Stream()].append(chunk) { order.append(session) }
        }
        while retainedBytes > budget, orderStart < order.count {
            let victim = order[orderStart]
            orderStart += 1
            retainedBytes -= streams[victim]?.evictOldest() ?? 0
        }
        if orderStart > 4096, orderStart * 2 > order.count {
            order.removeFirst(orderStart)
            orderStart = 0
        }
    }

    /// Ends tracking for a replaced or closed session; its cursors become invalid.
    public mutating func remove(session: UUID) {
        guard let stream = streams.removeValue(forKey: session) else { return }
        retainedBytes -= stream.bytes
        // Compact before filtering so the eviction cursor stays aligned.
        order = order[orderStart...].filter { $0 != session }
        orderStart = 0
    }

    public func contains(session: UUID) -> Bool { streams[session] != nil }

    /// Absolute offset after the newest byte of a session (0 before any output).
    public func end(session: UUID) -> UInt64 { streams[session]?.end ?? 0 }

    /// Reads up to `maxBytes` from `offset` (nil = oldest retained byte).
    public func read(session: UUID, from offset: UInt64?, maxBytes: Int) throws(ReadError) -> Read {
        guard let stream = streams[session] else { throw .unknownSession }
        let end = stream.end
        let requested = offset ?? stream.base
        guard requested <= end else { throw .offsetBeyondEnd }
        let start = max(requested, stream.base)
        var data = Data()
        var position = stream.base
        for chunk in stream.chunks[stream.head...] where data.count < maxBytes {
            let chunkEnd = position + UInt64(chunk.count)
            defer { position = chunkEnd }
            guard chunkEnd > start else { continue }
            let from = Int(max(start, position) - position)
            let take = min(chunk.count - from, maxBytes - data.count)
            data.append(chunk.subdata(in: from..<(from + take)))
        }
        let next = start + UInt64(data.count)
        return Read(data: data, start: start, next: next, gap: offset.map { $0 < stream.base } ?? (stream.base > 0), truncated: next < end)
    }
}
