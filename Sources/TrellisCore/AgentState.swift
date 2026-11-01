import Foundation

/// What an agent's hook reported (FR-AG08); the wire names are `AgentHook.events`.
public enum AgentEvent: String, CaseIterable, Sendable {
    case start, working, done, error, end
    case needsInput = "needs-input"
}

/// What a tab shows for the agent in it (FR-AG10). Runtime only, never saved.
public enum AgentState: String, Equatable, Sendable {
    /// Started and waiting for a first prompt, or seen after it finished.
    case ready, working, needsInput, done, error

    public var label: String {
        switch self {
        case .ready: "Ready"
        case .working: "Working"
        case .needsInput: "Needs you"
        case .done: "Done"
        case .error: "Error"
        }
    }

    /// The words VoiceOver reads after the agent's name.
    public var spokenText: String {
        switch self {
        case .ready: "ready"
        case .working: "working"
        case .needsInput: "needs your input"
        case .done: "finished"
        case .error: "stopped with an error"
        }
    }
}

/// Everything that moves an agent pane's state. Hook events are the agent's own word; the terminal's signals fill in for
/// agents without hooks (FR-AG11).
public enum AgentSignal: Equatable, Sendable {
    case hook(AgentEvent)
    /// BEL, OSC 9 / 777 / 99, or a password prompt.
    case attention
    /// OSC 9;4 progress started or ended.
    case progress(active: Bool)
    /// The user pressed Return in the pane.
    case inputSubmitted
    /// The pane was shown to the user.
    case viewed
}

/// One agent pane's state. Hook events win; terminal signals apply only where hooks say nothing, so a Codex approval
/// (a bell) still reads as "Needs you" and a pi turn without hooks still finishes.
public struct AgentStateReducer: Equatable, Sendable {
    public private(set) var state: AgentState = .ready
    /// Hooks have spoken at least once in this session.
    public private(set) var hooked = false
    /// A Done the user hasn't looked at yet.
    public private(set) var unseen = false
    public let integration: AgentIntegration

    public init(integration: AgentIntegration) { self.integration = integration }

    /// Whether the tab shows a badge: Done only until it has been seen.
    public var badge: AgentState? {
        switch state {
        case .ready: nil
        case .done: unseen ? .done : nil
        default: state
        }
    }

    /// Returns whether anything visible changed.
    @discardableResult
    public mutating func apply(_ signal: AgentSignal, visible: Bool = false) -> Bool {
        let before = self
        switch signal {
        case .hook(let event):
            hooked = true
            switch event {
            case .start, .end: state = .ready
            case .working: state = .working
            case .needsInput: state = .needsInput
            case .done: state = .done
            case .error: state = .error
            }
        case .attention:
            // A finished turn's own bell (Codex) never turns Done back into a question.
            if state != .done { state = .needsInput }
        case .progress(let active):
            if active, state != .needsInput { state = .working } else if !active, !hooked, state == .working { state = .done }
        case .inputSubmitted:
            // Agents that report their prompts say this themselves; Return in a menu would otherwise read as working.
            if !(integration.reportsPrompts && hooked), state != .working { state = .working }
        case .viewed:
            unseen = false
        }
        if state != before.state { unseen = state == .done && !visible }
        return badge != before.badge || state != before.state
    }
}
