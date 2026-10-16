import Foundation

public struct AccessibilityDescriptor: Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let value: String
    public let isSelected: Bool
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
        public init(state: SessionState, exitCode: Int32? = nil) { self.state = state; self.exitCode = exitCode }
    }

    public let windows: [AccessibilityDescriptor]
    public let tabs: [AccessibilityDescriptor]
    public let panes: [AccessibilityDescriptor]
    /// Status of the focused pane, shown in the status bar.
    public let status: String

    /// `live` overrides stored session state with the running terminal's state,
    /// keyed by pane ID. Window attention sets come from activity tracking.
    public init(
        snapshot: WorkspaceSnapshot, live: [UUID: LiveSession] = [:],
        windowsWithOutput: Set<UUID> = [], windowsWithExit: Set<UUID> = []
    ) {
        let presentation = WorkspacePresentation(snapshot: snapshot)
        func session(_ pane: WorkspacePane) -> LiveSession? {
            live[pane.id] ?? snapshot.sessions[pane.sessionID].map { LiveSession(state: $0.state, exitCode: $0.exitCode) }
        }
        windows = snapshot.windows.map { window in
            var parts = ["\(window.tabIDs.count) \(window.tabIDs.count == 1 ? "tab" : "tabs")"]
            if windowsWithExit.contains(window.id) { parts.append("a session exited") } else if windowsWithOutput.contains(window.id) { parts.append("new output") }
            return AccessibilityDescriptor(id: window.id, label: "Window \(window.name)", value: parts.joined(separator: ", "), isSelected: window.id == snapshot.activeWindowID)
        }
        let visible = presentation.visibleTabs
        tabs = visible.enumerated().map { index, tab in
            AccessibilityDescriptor(
                id: tab.id, label: "Tab \(tab.title)", value: "\(index + 1) of \(visible.count)",
                isSelected: tab.id == presentation.selectedTab?.id)
        }
        let paneIDs = presentation.selectedTab?.root.paneIDs ?? []
        panes = paneIDs.enumerated().compactMap { index, id in
            guard let pane = snapshot.panes[id] else { return nil }
            let state = session(pane).map { SessionStatusText.describe($0.state, exitCode: $0.exitCode) } ?? "No session"
            let focused = id == presentation.selectedTab?.activePaneID
            return AccessibilityDescriptor(
                id: id, label: "Terminal \(pane.title ?? "pane \(index + 1)")",
                value: focused && paneIDs.count > 1 ? "\(state), focused" : state, isSelected: focused)
        }
        status = presentation.activePane.flatMap(session).map { SessionStatusText.describe($0.state, exitCode: $0.exitCode) } ?? "No session"
    }
}
