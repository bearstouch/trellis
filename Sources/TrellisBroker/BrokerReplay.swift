#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Tracks the DEC private modes a replay must restore: alternate screens, bracketed paste,
/// application cursor keys, mouse reporting and cursor visibility. A streaming parser, so
/// sequences split across chunks are still seen.
public struct ModeTracker: Equatable, Sendable {
    public static let tracked: Set<Int> = [1, 25, 47, 1000, 1001, 1002, 1003, 1004, 1005, 1006, 1047, 1049, 2004]
    public private(set) var enabled: Set<Int> = [25]
    private enum State: Equatable, Sendable { case ground, escape, csi, privateParameters }
    private var state = State.ground
    private var parameters: [Int] = []
    private var current: Int?

    public init() {}

    public mutating func feed(_ bytes: some Sequence<UInt8>) {
        for byte in bytes { step(byte) }
    }

    private mutating func step(_ byte: UInt8) {
        switch state {
        case .ground: if byte == 0x1b { state = .escape }
        case .escape:
            if byte == 0x63 { enabled = [25] }  // RIS resets every mode
            state = byte == 0x5b ? .csi : (byte == 0x1b ? .escape : .ground)
        case .csi:
            if byte == 0x3f { state = .privateParameters; parameters = []; current = nil } else { state = byte == 0x1b ? .escape : .ground }
        case .privateParameters:
            switch byte {
            case 0x30...0x39: current = min(99_999, (current ?? 0) * 10 + Int(byte - 0x30))
            case 0x3b: parameters.append(current ?? 0); current = nil
            case 0x68, 0x6c:
                parameters.append(current ?? 0)
                for mode in parameters where Self.tracked.contains(mode) {
                    if byte == 0x68 { enabled.insert(mode) } else { enabled.remove(mode) }
                }
                state = .ground
            case 0x1b: state = .escape
            default: if byte < 0x20 || byte > 0x3f { state = .ground }
            }
        }
    }

    /// Sequences that bring a fresh terminal to these modes; empty at the defaults.
    public var assertion: Data {
        var text = ""
        for mode in [1049, 1047, 47] where enabled.contains(mode) { text += "\u{1b}[?\(mode)h"; break }
        for mode in Self.tracked.sorted() where ![25, 47, 1047, 1049].contains(mode) && enabled.contains(mode) { text += "\u{1b}[?\(mode)h" }
        if !enabled.contains(25) { text += "\u{1b}[?25l" }
        return Data(text.utf8)
    }
}

/// One session's retained output for replay. Evicted bytes still pass through `baseline`,
/// so a truncated replay can first restore the modes in force where it starts.
public struct OutputRing: Sendable {
    public static let sessionLimit = 4 * 1_048_576
    public static let totalLimit = 64 * 1_048_576
    public let limit: Int
    public private(set) var bytes = Data()
    public private(set) var truncated = false
    /// Every byte ever appended, including evicted ones: the session's output position (protocol v2).
    public private(set) var appendedTotal: UInt64 = 0
    private var baseline = ModeTracker()

    public init(limit: Int = OutputRing.sessionLimit) { self.limit = max(1, limit) }

    public var count: Int { bytes.count }

    public mutating func append(_ data: Data) {
        bytes.append(data)
        appendedTotal += UInt64(data.count)
        // Trim in steps so a steady stream doesn't copy the whole ring on every read.
        if bytes.count > limit + limit / 8 { evict(bytes.count - limit) }
    }

    public mutating func evict(_ count: Int) {
        let count = min(count, bytes.count)
        guard count > 0 else { return }
        baseline.feed(bytes.prefix(count))
        bytes = Data(bytes.dropFirst(count))
        truncated = true
    }

    /// Everything still held, or after truncation: a reset, the modes in force at the first
    /// whole line, then output from that line on. At most `limit` bytes of output.
    public var replay: Data {
        // The ring trims in steps; a replay never exceeds the limit.
        if bytes.count > limit {
            var trimmed = self
            trimmed.evict(bytes.count - limit)
            return trimmed.replay
        }
        guard truncated else { return bytes }
        var modes = baseline
        var tail = bytes[...]
        // Output without line breaks (a redrawn progress line) is kept from the cut rather than dropped.
        if let newline = tail.prefix(BrokerProtocol.chunkLimit).firstIndex(of: 0x0a) {
            modes.feed(tail[...newline])
            tail = tail[(newline + 1)...]
        }
        return Data("\u{1b}c".utf8) + modes.assertion + Data(tail)
    }
}

extension OutputRing {
    /// The output after position `since` when the ring still holds all of it (`resumed`), otherwise the full `replay`.
    /// A `since` past the end (a client that counted wrong) gets the full replay too, never a guess.
    public func replay(since: UInt64?) -> (data: Data, resumed: Bool) {
        let held = UInt64(bytes.count)
        guard let since, since <= appendedTotal, appendedTotal - since <= min(held, UInt64(limit)) else { return (replay, false) }
        return (Data(bytes.suffix(Int(appendedTotal - since))), true)
    }
}

/// Keeps every session's ring within the broker-wide limit by trimming the largest first.
public enum OutputBudget {
    public static func enforce<Key: Hashable>(_ rings: inout [Key: OutputRing], total: Int = OutputRing.totalLimit) {
        var used = rings.values.reduce(0) { $0 + $1.count }
        while used > total, let largest = rings.max(by: { $0.value.count < $1.value.count }) {
            let excess = min(largest.value.count, max(used - total, 65_536))
            rings[largest.key]?.evict(excess)
            used -= excess
        }
    }
}
