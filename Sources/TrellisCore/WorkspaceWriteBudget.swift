import Foundation

/// FR-R06: how much the workspace file and its backup may write in an hour. Past it, ordinary changes are saved
/// together once per `throttledInterval` instead of 300 ms after each change; ⌘S and Quit still save at once.
public struct WorkspaceWriteBudget: Equatable, Sendable {
    public static let choices = [10, 25, 50, 100, 250]
    public static let defaultMegabytesPerHour = 50
    public static let window: TimeInterval = 3600
    public static let throttledInterval: TimeInterval = 300

    private struct Write: Equatable, Sendable { let at: Date; let bytes: Int }

    public var megabytesPerHour: Int
    private var writes: [Write] = []

    public init(megabytesPerHour: Int = Self.defaultMegabytesPerHour) {
        self.megabytesPerHour = Self.choices.contains(megabytesPerHour) ? megabytesPerHour : Self.defaultMegabytesPerHour
    }

    public var limitBytes: Int { megabytesPerHour * 1_000_000 }

    public mutating func record(_ bytes: Int, at now: Date) {
        writes.removeAll { $0.at <= now.addingTimeInterval(-Self.window) }
        if bytes > 0 { writes.append(Write(at: now, bytes: bytes)) }
    }

    /// Bytes written in the hour before `now`.
    public func written(at now: Date) -> Int {
        let start = now.addingTimeInterval(-Self.window)
        return writes.reduce(0) { $1.at > start ? $0 + $1.bytes : $0 }
    }

    public func isExhausted(at now: Date) -> Bool { written(at: now) >= limitBytes }
}
