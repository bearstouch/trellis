import Foundation

/// Decides whether a pane is busy printing output (FR-T05). Time is passed in, so the rules are deterministic.
public struct PaneOutputActivity: Sendable {
    /// Output this soon after a keystroke is treated as the shell echoing it.
    public static let echoWindow: TimeInterval = 0.15
    public static let quietInterval: TimeInterval = 0.8

    private var lastInput: [UUID: Date] = [:]
    private var lastOutput: [UUID: Date] = [:]

    public init() {}

    public mutating func recordInput(_ pane: UUID, at now: Date) { lastInput[pane] = now }

    /// `commandRunning` is nil without shell integration. With it, output at the prompt is line editing and never
    /// counts. Echo of a keystroke never counts either, so an interactive program redrawing as you type stays calm.
    /// Returns whether the output made the pane busy.
    @discardableResult
    public mutating func recordOutput(_ pane: UUID, at now: Date, commandRunning: Bool?) -> Bool {
        if commandRunning == false { return false }
        if let input = lastInput[pane], now.timeIntervalSince(input) < Self.echoWindow { return false }
        lastOutput[pane] = now
        return true
    }

    public func isBusy(_ pane: UUID, at now: Date) -> Bool {
        guard let output = lastOutput[pane] else { return false }
        return now.timeIntervalSince(output) < Self.quietInterval
    }

    /// Ends the busy state at once, for example when a command finishes.
    public mutating func settle(_ pane: UUID) { lastOutput.removeValue(forKey: pane) }

    public mutating func remove(_ pane: UUID) { lastInput.removeValue(forKey: pane); lastOutput.removeValue(forKey: pane) }

    public mutating func retain(_ panes: Set<UUID>) {
        lastInput = lastInput.filter { panes.contains($0.key) }
        lastOutput = lastOutput.filter { panes.contains($0.key) }
    }
}
