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
        case .ready: L("Ready")
        case .working: L("Working")
        case .needsInput: L("Needs you")
        case .done: L("Done")
        case .error: L("Error")
        }
    }

    /// The words VoiceOver reads after the agent's name.
    public var spokenText: String {
        switch self {
        case .ready: L("ready")
        case .working: L("working")
        case .needsInput: L("needs your input")
        case .done: L("finished")
        case .error: L("stopped with an error")
        }
    }
}

/// The model and reasoning effort an agent's hooks reported (FR-AG19). Runtime only, never saved; a value never
/// reported stays nil and the row shows what it showed before.
public struct AgentSettings: Equatable, Sendable {
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]
    public var model: String?
    public var effort: String?
    public init(model: String? = nil, effort: String? = nil) { self.model = model; self.effort = effort }

    /// Reads the hook channel's `info [effort=…] [model=…]` event; nil for anything else or a value outside the lists.
    public init?(infoEvent: String) {
        let parts = infoEvent.split(separator: " ").map(String.init)
        guard parts.first == "info", (2...3).contains(parts.count) else { return nil }
        for field in parts.dropFirst() {
            if field.hasPrefix("effort="), Self.efforts.contains(String(field.dropFirst(7))) {
                effort = String(field.dropFirst(7))
            } else if field.hasPrefix("model="), let id = Optional(String(field.dropFirst(6))), Self.isModel(id) {
                model = id
            } else {
                return nil
            }
        }
    }

    static func isModel(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._[]".contains($0)) }
    }

    /// Reported values replace older ones; one that wasn't reported keeps the last.
    public func merged(_ newer: AgentSettings) -> AgentSettings { AgentSettings(model: newer.model ?? model, effort: newer.effort ?? effort) }

    /// `claude-opus-5-5` reads "Opus 5.5" and `claude-sonnet-5-5[1m]` "Sonnet 5.5 1M"; an ID in any other shape shows as is.
    public var modelName: String? {
        guard var id = model else { return nil }
        var suffix = ""
        if let open = id.firstIndex(of: "["), id.hasSuffix("]") {
            suffix = " " + id[id.index(after: open)..<id.index(before: id.endIndex)].uppercased()
            id = String(id[..<open])
        }
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() } else if parts.count == 1, parts[0].allSatisfy(\.isLetter) { return parts[0].capitalized + suffix }
        guard parts.count >= 2, parts[0].allSatisfy(\.isLetter), parts.dropFirst().allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return model }
        var version = Array(parts.dropFirst())
        if version.count > 1, version.last?.count == 8 { version.removeLast() }  // a dated snapshot
        guard (1...2).contains(version.count), version.allSatisfy({ $0.count <= 2 }) else { return model }
        return parts[0].capitalized + " " + version.joined(separator: ".") + suffix
    }
}

/// Everything that moves an agent pane's state. Hook events are the agent's own word; the terminal's signals fill in for
/// agents without hooks (FR-AG11).
public enum AgentSignal: Equatable, Sendable {
    case hook(AgentEvent)
    /// The agent's model or effort (FR-AG19); changes no state.
    case settings(AgentSettings)
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
    public private(set) var settings = AgentSettings()
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
        case .settings(let newer):
            settings = settings.merged(newer)
        }
        if state != before.state { unseen = state == .done && !visible }
        return badge != before.badge || state != before.state || settings != before.settings
    }
}
