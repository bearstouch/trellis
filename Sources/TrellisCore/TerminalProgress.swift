import Foundation

/// One OSC 9;4 report as the program sent it (ConEmu/Windows Terminal), before resolution (FR-T09).
public struct TerminalProgressReport: Equatable, Sendable {
    public enum Kind: Int, Sendable { case remove = 0, set, error, indeterminate, pause }
    public var kind: Kind
    /// 0-100 when the report carried one.
    public var value: Int?
    public init(kind: Kind, value: Int? = nil) { self.kind = kind; self.value = value.map { min(100, max(0, $0)) } }
}

/// A pane's shown progress (FR-T09). Runtime-only, never persisted.
public struct TerminalProgress: Equatable, Sendable {
    public enum State: String, Sendable { case normal, error, paused, indeterminate }
    public var state: State
    /// 0-100; nil while indeterminate, or for an error with no known value.
    public var percent: Int?
    public init(state: State, percent: Int? = nil) { self.state = state; self.percent = percent }

    /// Shown beside the bar, so the state never relies on color alone.
    public var visibleText: String {
        switch state {
        case .normal: "\(percent ?? 0)%"
        case .paused: percent.map { L("Paused %d%%", $0) } ?? L("Paused")
        case .error: L("Error")
        case .indeterminate: L("Working")
        }
    }

    public var spokenText: String {
        switch state {
        case .normal: L("progress %d percent", percent ?? 0)
        case .paused: percent.map { L("progress paused at %d percent", $0) } ?? L("progress paused")
        case .error: percent.map { L("progress error at %d percent", $0) } ?? L("progress error")
        case .indeterminate: L("progress, amount unknown")
        }
    }

    /// The most urgent of several panes: an error, then a pause, then the lowest percentage, then indeterminate.
    public static func aggregate(_ items: some Sequence<TerminalProgress>) -> TerminalProgress? {
        func rank(_ p: TerminalProgress) -> (Int, Int) {
            let order: Int =
                switch p.state {
                case .error: 0
                case .paused: 1
                case .normal: 2
                case .indeterminate: 3
                }
            return (order, p.percent ?? 101)
        }
        return items.min { rank($0) < rank($1) }
    }
}

/// Resolves one pane's reports the way the engine's own bar does, and drops progress nobody updated for 15 s.
public struct PaneProgressTracker: Sendable {
    public static let staleInterval: TimeInterval = 15
    public private(set) var progress: TerminalProgress?
    private var lastPercent: Int?
    private var updatedAt = Date.distantPast
    public init() {}

    public var expiresAt: Date? { progress == nil ? nil : updatedAt.addingTimeInterval(Self.staleInterval) }

    @discardableResult
    public mutating func apply(_ report: TerminalProgressReport, at now: Date) -> TerminalProgress? {
        let next: TerminalProgress?
        switch report.kind {
        case .remove: next = nil
        case .set: next = TerminalProgress(state: .normal, percent: report.value ?? 0)
        case .error: next = TerminalProgress(state: .error, percent: report.value ?? lastPercent)
        case .indeterminate: next = TerminalProgress(state: .indeterminate)
        case .pause: next = TerminalProgress(state: .paused, percent: report.value ?? lastPercent ?? 100)
        }
        if next == nil { lastPercent = nil } else if let percent = next?.percent { lastPercent = percent }
        progress = next; updatedAt = now
        return next
    }

    /// Clears stale progress; returns whether it did.
    public mutating func expire(at now: Date) -> Bool {
        guard let expiresAt, now >= expiresAt else { return false }
        progress = nil; lastPercent = nil
        return true
    }
}
