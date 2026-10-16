import Foundation

/// A metadata change derived from two snapshots. Data never includes launch
/// details, terminal text, or input.
public struct WorkspaceEvent: Equatable, Sendable {
    public let type: String
    public let resourceID: UUID
    /// Owning window, used for grant scoping (nil only for removed windows' children).
    public let windowID: UUID?
    public let data: [String: String]

    public init(type: String, resourceID: UUID, windowID: UUID?, data: [String: String] = [:]) {
        self.type = type; self.resourceID = resourceID; self.windowID = windowID; self.data = data
    }

    /// The subscription topic this event belongs to.
    public var topic: String {
        if type.hasPrefix("selection.") { return "selection" }
        if type.hasPrefix("appearance.") { return "appearance" }
        if type.hasPrefix("session.") { return "session" }
        return "resources"
    }
}

public enum WorkspaceEvents {
    /// Ordered events for the transition `old → new`: removals, creations and
    /// updates, layout, sessions, then selection.
    public static func diff(_ old: WorkspaceSnapshot, _ new: WorkspaceSnapshot) -> [WorkspaceEvent] {
        guard old != new else { return [] }
        var events: [WorkspaceEvent] = []
        let oldWindows = Dictionary(uniqueKeysWithValues: old.windows.map { ($0.id, $0) })
        let newWindows = Dictionary(uniqueKeysWithValues: new.windows.map { ($0.id, $0) })
        func paneWindow(_ snapshot: WorkspaceSnapshot, _ pane: UUID) -> UUID? {
            snapshot.panes[pane].flatMap { snapshot.tabs[$0.tabID]?.windowID }
        }

        for window in old.windows where newWindows[window.id] == nil {
            events.append(WorkspaceEvent(type: "window.deleted", resourceID: window.id, windowID: window.id))
        }
        for (id, tab) in old.tabs.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where new.tabs[id] == nil {
            events.append(WorkspaceEvent(type: "tab.deleted", resourceID: id, windowID: tab.windowID))
        }
        for (id, pane) in old.panes.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where new.panes[id] == nil {
            events.append(WorkspaceEvent(type: "pane.deleted", resourceID: id, windowID: old.tabs[pane.tabID]?.windowID))
        }
        for window in new.windows {
            let revision = String(window.revision)
            if let previous = oldWindows[window.id] {
                if previous.name != window.name || previous.revision != window.revision {
                    events.append(WorkspaceEvent(type: "window.updated", resourceID: window.id, windowID: window.id, data: ["revision": revision]))
                }
            } else {
                events.append(WorkspaceEvent(type: "window.created", resourceID: window.id, windowID: window.id, data: ["revision": revision]))
            }
        }
        // Only a pure reorder of the same windows; creation/deletion has its own events.
        if Set(old.windows.map(\.id)) == Set(new.windows.map(\.id)), old.windows.map(\.id) != new.windows.map(\.id), !new.windows.isEmpty {
            events.append(WorkspaceEvent(type: "window.reordered", resourceID: new.windows[0].id, windowID: nil, data: ["revision": String(new.revision)]))
        }
        for (id, tab) in new.tabs.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let data = ["revision": String(tab.revision)]
            if let previous = old.tabs[id] {
                if previous.root != tab.root {
                    events.append(WorkspaceEvent(type: "tab.layoutChanged", resourceID: id, windowID: tab.windowID, data: data))
                } else if previous.title != tab.title || previous.revision != tab.revision {
                    events.append(WorkspaceEvent(type: "tab.updated", resourceID: id, windowID: tab.windowID, data: data))
                }
            } else {
                events.append(WorkspaceEvent(type: "tab.created", resourceID: id, windowID: tab.windowID, data: data))
            }
        }
        for (id, pane) in new.panes.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where old.panes[id] == nil {
            events.append(WorkspaceEvent(type: "pane.created", resourceID: id, windowID: new.tabs[pane.tabID]?.windowID, data: ["sessionId": pane.sessionID.uuidString]))
        }
        for (id, session) in new.sessions.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let previous = old.sessions[id]
            // A new stopped session is announced by pane.created; report real transitions.
            guard previous?.state != session.state, previous != nil || session.state != .stopped else { continue }
            let pane = new.panes.values.first { $0.sessionID == id }
            let window = pane.flatMap { paneWindow(new, $0.id) }
            var data = ["state": session.state.rawValue]
            if let pane { data["paneId"] = pane.id.uuidString }
            events.append(WorkspaceEvent(type: "session.state", resourceID: id, windowID: window, data: data))
            if session.state == .exited || session.state == .failed {
                var exit = data
                if let code = session.exitCode { exit["exitCode"] = String(code) }
                events.append(WorkspaceEvent(type: "session.exit", resourceID: id, windowID: window, data: exit))
            }
        }
        if old.activeWindowID != new.activeWindowID, let active = new.activeWindowID {
            events.append(WorkspaceEvent(type: "selection.window", resourceID: active, windowID: active))
        }
        for window in new.windows where oldWindows[window.id]?.activeTabID != window.activeTabID && oldWindows[window.id] != nil {
            events.append(WorkspaceEvent(type: "selection.tab", resourceID: window.activeTabID, windowID: window.id))
        }
        for (id, tab) in new.tabs.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where old.tabs[id] != nil && old.tabs[id]?.activePaneID != tab.activePaneID {
            events.append(WorkspaceEvent(type: "selection.pane", resourceID: tab.activePaneID, windowID: tab.windowID, data: ["tabId": id.uuidString]))
        }
        return events
    }
}
