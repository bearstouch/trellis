import AppKit
import Foundation
import TrellisCore

/// A view of the right sidebar, chosen from the dock (FR-SB01, FR-SB02).
public enum SidebarView: String, CaseIterable, Sendable {
    case files, changes, scratchpad, tasks, agents

    public var title: String {
        switch self {
        case .files: "Files"
        case .changes: "Changes"
        case .scratchpad: "Scratchpad"
        case .tasks: "Tasks"
        case .agents: "Agents"
        }
    }

    public var symbol: String {
        switch self {
        case .files: "folder"
        case .changes: "arrow.triangle.branch"
        case .scratchpad: "chevron.left.forwardslash.chevron.right"
        case .tasks: "play"
        case .agents: "sparkles"
        }
    }

    public var shortcut: ShortcutAction {
        switch self {
        case .files: .toggleFiles
        case .changes: .toggleChanges
        case .scratchpad: .toggleScratchpad
        case .tasks: .toggleTasks
        case .agents: .toggleAgents
        }
    }

    public init?(shortcut: ShortcutAction) {
        guard let view = Self.allCases.first(where: { $0.shortcut == shortcut }) else { return nil }
        self = view
    }
}

/// One agent pane, in any window, for the Agents view's Running list (FR-AG16).
public struct AgentSessionRow: Identifiable, Equatable, Sendable {
    /// The pane.
    public let id: UUID
    public let agent: AgentDefinition
    public let tabTitle: String
    public let windowName: String
    /// The agent's state while its session runs; nil otherwise, and `status` names the session's state.
    public let state: AgentState?
    public let status: String
}

extension AppWorkspaceModel {
    /// Why the focused pane can't use a view; nil when it can (FR-SB04). Plain SSH sessions have no verified folder or
    /// machine to act on; the scratchpad runs only on this Mac.
    public func sidebarUnavailableReason(_ view: SidebarView) -> String? {
        guard let paneID = presentation.activePane?.id, snapshot.panes[paneID] != nil else { return "Open a pane first." }
        let machine = paneContext(paneID).machine
        if machine == .ssh { return "\(view.title) isn't available in SSH panes." }
        if view == .scratchpad, machine != .local { return "The scratchpad runs only in panes on this Mac." }
        // The remote helper reads only allow-listed files; it can't list folders (FR-FB01).
        if view == .files, machine != .local { return "Files shows only folders on this Mac." }
        if view == .changes, machine != .local { return "Changes reads git only in panes on this Mac." }
        return nil
    }

    /// The view the sidebar shows: the chosen one while the focused pane can use it, so it hides on an SSH pane and
    /// comes back with focus (FR-SB04).
    public var visibleSidebarView: SidebarView? { sidebarView.flatMap { sidebarUnavailableReason($0) == nil ? $0 : nil } }

    public var scratchpadVisible: Bool { visibleSidebarView == .scratchpad }

    /// Shows a view, or hides the sidebar when it is the one shown (FR-SB02). A view the focused pane can't use does nothing.
    public func toggleSidebarView(_ view: SidebarView) {
        guard sidebarUnavailableReason(view) == nil else { return }
        if visibleSidebarView == view {
            closeSidebar()
        } else {
            let leavingEditor = visibleSidebarView == .scratchpad || visibleSidebarView == .files || visibleSidebarView == .changes
            sidebarView = view
            if view == .scratchpad {
                scratchpadFocusRequest &+= 1
            } else if view == .files {
                // Showing Files puts the keyboard in its search field, so ⌥⌘F, a few letters and Return opens a file (FR-FB04).
                filesFocusRequest &+= 1
            } else if view == .changes {
                gitChangesFocusRequest &+= 1
            } else if leavingEditor, let terminal = activeTerminal {
                // The editor that had the keyboard is gone; give it back to the terminal rather than to nothing.
                DispatchQueue.main.async { terminal.view.window?.makeFirstResponder(terminal.view) }
            }
        }
    }

    /// Hides the sidebar and gives the keyboard back to the focused terminal.
    public func closeSidebar() {
        sidebarView = nil
        if let terminal = activeTerminal { DispatchQueue.main.async { terminal.view.window?.makeFirstResponder(terminal.view) } }
    }

    // MARK: Badges (FR-SB05)

    /// Task runs starting or running, in every pane.
    public var activeTaskCount: Int { taskRuns.values.filter(\.isActive).count }

    /// The focused pane's changed files, from its header git status (FR-GC01).
    public var changedFileCount: Int { presentation.activePane.flatMap { gitStatuses[$0.id]?.changes } ?? 0 }

    /// Running agent panes whose state is Needs you, in every window.
    public var agentsNeedingYouCount: Int {
        agentStates.filter { $0.value.state == .needsInput && terminals[$0.key]?.sessionState == .running && agentDefinition(paneID: $0.key) != nil }.count
    }

    // MARK: Agents view (FR-AG16)

    /// Every agent pane, in window and tab order.
    public var agentSessionRows: [AgentSessionRow] {
        snapshot.windows.flatMap { window in
            window.tabIDs.compactMap { snapshot.tabs[$0] }.flatMap { tab in
                tab.root.paneIDs.compactMap { id -> AgentSessionRow? in
                    guard let agent = agentDefinition(paneID: id) else { return nil }
                    let terminal = terminals[id]
                    let state: AgentState? = terminal?.sessionState == .running ? agentStates[id]?.state ?? .ready : nil
                    let status = state?.label ?? SessionStatusText.describe(terminal?.sessionState ?? .stopped, exitCode: terminal?.exitCode)
                    return AgentSessionRow(id: id, agent: agent, tabTitle: displayTitle(tab), windowName: window.name, state: state, status: status)
                }
            }
        }
    }

    /// Where the Agents view opens an agent for the focused pane, in words: its folder and machine.
    public var agentTarget: (directory: String?, machine: String)? {
        guard let paneID = presentation.activePane?.id, snapshot.panes[paneID] != nil else { return nil }
        let context = paneContext(paneID)
        return (context.directory, context.machine == .local ? "this Mac" : context.machine.name)
    }

    /// An agent's install status on the focused pane's machine, in words; nil when it is installed or unknown (FR-AG07).
    public func agentStatusText(_ agent: AgentDefinition) -> String? {
        guard let paneID = presentation.activePane?.id else { return nil }
        if isRemoteWorkspace(paneID: paneID) {
            let host = snapshot.panes[paneID].flatMap { snapshot.sessions[$0.sessionID]?.launch.remoteHostID }
            return host.flatMap { remoteMissingAgents[$0]?.contains(agent.id) == true ? "Not installed on \(remoteHostName($0))" : nil }
        }
        switch agentAvailability[agent.id] {
        case .missing?: return "Not installed on this Mac"
        case .checking?: return "Checking…"
        default: return nil
        }
    }

    /// FR-AG17: **This Tab** is offered while no agent runs in the focused pane's tab.
    public var canLaunchAgentInFocusedTab: Bool {
        guard let paneID = presentation.activePane?.id, let tabID = snapshot.panes[paneID]?.tabID else { return false }
        return !agentRunning(inTab: tabID)
    }

    /// The chosen placement, with New Tab standing in for This Tab while the focused tab already has an agent.
    public var effectiveAgentPlacement: AgentPlacement { agentPlacement == .currentTab && !canLaunchAgentInFocusedTab ? .tab : agentPlacement }

    /// Opens an agent for the focused pane, with the view's placement; `flipPlacement` (⌥) uses the other one: Split for
    /// New Tab, New Tab for the others (FR-AG07).
    public func launchAgentFromSidebar(_ agentID: String, resume: Bool, flipPlacement: Bool = false) async {
        guard let paneID = presentation.activePane?.id, sidebarUnavailableReason(.agents) == nil else { return }
        let chosen = effectiveAgentPlacement
        let placement: AgentPlacement = flipPlacement ? (chosen == .tab ? .split : .tab) : chosen
        await launchAgent(agentID, from: paneID, placement: placement, resume: resume)
    }
}
