import Foundation

/// A task Run typed into a pane, followed through the shell's marks (FR-TK07). Runtime only: never Codable,
/// persisted or logged.
///
/// bash reports only the first simple command of a line, so the run is matched by order, not by text: Trellis types
/// only at an idle prompt, so the next command start is the task's.
public struct TaskRun: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case submitted(at: Date)
        case running(since: Date)
        case finished(exitCode: Int32?, duration: TimeInterval)
    }

    public let taskID: String
    public let name: String
    public private(set) var phase: Phase
    /// The first Stop, which starts the wait before Force Stop (FR-TK08).
    public var stopRequestedAt: Date?

    public init(taskID: String, name: String, at now: Date) { self.taskID = taskID; self.name = name; phase = .submitted(at: now) }

    /// Submitted or running: the pane can't take another task.
    public var isActive: Bool {
        if case .finished = phase { return false }
        return true
    }

    public var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// Advances on a shell mark. Returns false when the run should be forgotten: the shell came back without starting
    /// it (an empty or rejected line), or a later command started after it finished.
    public mutating func apply(_ event: ShellIntegrationEvent, now: Date) -> Bool {
        switch (phase, event) {
        case (.submitted, .commandStart): phase = .running(since: now)
        case (.submitted, .promptStart): return false
        case (.running(let since), .commandFinished(let code)): phase = .finished(exitCode: code, duration: now.timeIntervalSince(since))
        case (.running(let since), .promptStart): phase = .finished(exitCode: nil, duration: now.timeIntervalSince(since))
        case (.finished, .commandStart): return false
        default: break
        }
        return true
    }

    /// The button's words, never color alone: "Running: test", "test: done", "test: exit 2", "test: stopped".
    public func statusText(now: Date) -> String {
        switch phase {
        case .submitted: "Starting: \(name)"
        case .running(let since): "Running: \(name) · \(ShellIntegrationState.durationText(now.timeIntervalSince(since)))"
        case .finished(let code?, _) where code == 0: "\(name): done"
        case .finished(let code?, _): "\(name): exit \(code)"
        case .finished(nil, _): "\(name): ended"
        }
    }

    /// Whether the run ended in failure; nil while active.
    public var failed: Bool? {
        guard case .finished(let code, _) = phase else { return nil }
        return code.map { $0 != 0 } ?? false
    }
}
