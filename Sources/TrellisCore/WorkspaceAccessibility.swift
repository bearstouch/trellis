import Foundation

public struct AccessibilityDescriptor: Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let value: String
    public let isSelected: Bool
}

/// Why a pane's program is waiting for the user (FR-T06). Runtime-only, never persisted.
public enum InputWaitReason: String, Sendable {
    /// The PTY has echo off with line editing on, as a password prompt does.
    case password
    /// The program rang the bell or posted a notification while the pane was not in view.
    case attention

    public var text: String { self == .password ? "Waiting for a password" : "Waiting for input" }
}

public enum SessionStatusText {
    /// Words, never color alone, describe each lifecycle state.
    public static func describe(_ state: SessionState, exitCode: Int32?) -> String {
        switch state {
        case .exited: exitCode.map { "Exited (\($0))" } ?? "Exited"
        case .failed: "Failed to start"
        default: state.rawValue.capitalized
        }
    }
}

/// Pure projection of the workspace into VoiceOver labels, values, and selected
/// states. Views render these strings so spoken and visible status agree.
public struct WorkspaceAccessibility: Sendable {
    public struct LiveSession: Equatable, Sendable {
        public var state: SessionState
        public var exitCode: Int32?
        /// Exit status of the shell's last command, from shell integration; nil when unknown or zero.
        public var failedCommandExit: Int32?
        public var inputWait: InputWaitReason?
        public init(state: SessionState, exitCode: Int32? = nil, failedCommandExit: Int32? = nil, inputWait: InputWaitReason? = nil) {
            self.state = state; self.exitCode = exitCode; self.failedCommandExit = failedCommandExit; self.inputWait = inputWait
        }
    }

    public static func commandFailureText(_ code: Int32) -> String { "Last command failed (exit \(code))" }

    public let windows: [AccessibilityDescriptor]
    public let tabs: [AccessibilityDescriptor]
    public let panes: [AccessibilityDescriptor]
    /// Status of the focused pane, shown in the status bar.
    public let status: String

    /// `live` overrides stored session state with the running terminal's state,
    /// keyed by pane ID. Window attention sets come from activity tracking.
    public init(
        snapshot: WorkspaceSnapshot, live: [UUID: LiveSession] = [:],
        windowsWithOutput: Set<UUID> = [], windowsWithExit: Set<UUID> = [], windowsNeedingInput: Set<UUID> = [], titles: [UUID: String] = [:]
    ) {
        let presentation = WorkspacePresentation(snapshot: snapshot)
        func session(_ pane: WorkspacePane) -> LiveSession? {
            live[pane.id] ?? snapshot.sessions[pane.sessionID].map { LiveSession(state: $0.state, exitCode: $0.exitCode) }
        }
        windows = snapshot.windows.map { window in
            var parts = ["\(window.tabIDs.count) \(window.tabIDs.count == 1 ? "tab" : "tabs")"]
            if windowsNeedingInput.contains(window.id) { parts.append("waiting for input") }
            if windowsWithExit.contains(window.id) { parts.append("a session exited") } else if windowsWithOutput.contains(window.id) { parts.append("new output") }
            return AccessibilityDescriptor(id: window.id, label: "Window \(window.name)", value: parts.joined(separator: ", "), isSelected: window.id == snapshot.activeWindowID)
        }
        let visible = presentation.visibleTabs
        tabs = visible.enumerated().map { index, tab in
            AccessibilityDescriptor(
                // The label is spoken too, so it never relies on color alone.
                id: tab.id, label: "Tab \(titles[tab.id] ?? tab.title)",
                value: "\(index + 1) of \(visible.count)" + (tab.color.map { ", \($0.displayName.lowercased()) label" } ?? ""),
                isSelected: tab.id == presentation.selectedTab?.id)
        }
        let paneIDs = presentation.selectedTab?.root.paneIDs ?? []
        panes = paneIDs.enumerated().compactMap { index, id in
            guard let pane = snapshot.panes[id] else { return nil }
            var state = session(pane).map { SessionStatusText.describe($0.state, exitCode: $0.exitCode) } ?? "No session"
            if let code = live[pane.id]?.failedCommandExit { state += ", " + Self.commandFailureText(code) }
            if let wait = live[pane.id]?.inputWait { state += ", " + wait.text }
            let focused = id == presentation.selectedTab?.activePaneID
            return AccessibilityDescriptor(
                id: id, label: "Terminal \(pane.title ?? titles[id] ?? "pane \(index + 1)")",
                value: focused && paneIDs.count > 1 ? "\(state), focused" : state, isSelected: focused)
        }
        status = presentation.activePane.flatMap(session).map { SessionStatusText.describe($0.state, exitCode: $0.exitCode) } ?? "No session"
    }
}

extension WorkspaceAccessibility {
    /// Short label for the collapsed sidebar: first letters of the first two words,
    /// or the first two characters of a single word. Graphemes, so emoji stay whole.
    public static func initials(for name: String) -> String {
        let words = name.split { $0.isWhitespace || "-_.".contains($0) }
        guard let first = words.first else { return "?" }
        let letters = words.count > 1 ? [first.first, words[1].first].compactMap { $0 }.map(String.init).joined() : String(first.prefix(2))
        return letters.uppercased()
    }
}
