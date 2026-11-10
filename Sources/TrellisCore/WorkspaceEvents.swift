import Foundation

/// A metadata change derived from two snapshots. Data never includes launch
/// details, terminal text, or input.
public struct WorkspaceEvent: Equatable, Sendable {
    public let type: String
    public let resourceID: UUID
    /// Owning space, used for grant scoping (nil only for removed spaces' children).
    public let spaceID: UUID?
    public let data: [String: String]

    public init(type: String, resourceID: UUID, spaceID: UUID?, data: [String: String] = [:]) {
        self.type = type; self.resourceID = resourceID; self.spaceID = spaceID; self.data = data
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
        let oldSpaces = Dictionary(uniqueKeysWithValues: old.spaces.map { ($0.id, $0) })
        let newSpaces = Dictionary(uniqueKeysWithValues: new.spaces.map { ($0.id, $0) })
        func paneSpace(_ snapshot: WorkspaceSnapshot, _ pane: UUID) -> UUID? {
            snapshot.panes[pane].flatMap { snapshot.tabs[$0.tabID]?.spaceID }
        }

        for space in old.spaces where newSpaces[space.id] == nil {
            events.append(WorkspaceEvent(type: "space.deleted", resourceID: space.id, spaceID: space.id))
        }
        for (id, tab) in old.tabs.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where new.tabs[id] == nil {
            events.append(WorkspaceEvent(type: "tab.deleted", resourceID: id, spaceID: tab.spaceID))
        }
        for (id, pane) in old.panes.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where new.panes[id] == nil {
            events.append(WorkspaceEvent(type: "pane.deleted", resourceID: id, spaceID: old.tabs[pane.tabID]?.spaceID))
        }
        for space in new.spaces {
            let revision = String(space.revision)
            if let previous = oldSpaces[space.id] {
                if previous.name != space.name || previous.revision != space.revision {
                    events.append(WorkspaceEvent(type: "space.updated", resourceID: space.id, spaceID: space.id, data: ["revision": revision]))
                }
            } else {
                events.append(WorkspaceEvent(type: "space.created", resourceID: space.id, spaceID: space.id, data: ["revision": revision]))
            }
        }
        // Only a pure reorder of the same spaces; creation/deletion has its own events.
        if Set(old.spaces.map(\.id)) == Set(new.spaces.map(\.id)), old.spaces.map(\.id) != new.spaces.map(\.id), !new.spaces.isEmpty {
            events.append(WorkspaceEvent(type: "space.reordered", resourceID: new.spaces[0].id, spaceID: nil, data: ["revision": String(new.revision)]))
        }
        for (id, tab) in new.tabs.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let data = ["revision": String(tab.revision)]
            if let previous = old.tabs[id] {
                if previous.root != tab.root {
                    events.append(WorkspaceEvent(type: "tab.layoutChanged", resourceID: id, spaceID: tab.spaceID, data: data))
                } else if previous.title != tab.title || previous.revision != tab.revision {
                    events.append(WorkspaceEvent(type: "tab.updated", resourceID: id, spaceID: tab.spaceID, data: data))
                }
            } else {
                events.append(WorkspaceEvent(type: "tab.created", resourceID: id, spaceID: tab.spaceID, data: data))
            }
        }
        for (id, pane) in new.panes.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where old.panes[id] == nil {
            events.append(WorkspaceEvent(type: "pane.created", resourceID: id, spaceID: new.tabs[pane.tabID]?.spaceID, data: ["sessionId": pane.sessionID.uuidString]))
        }
        for (id, session) in new.sessions.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let previous = old.sessions[id]
            // A new stopped session is announced by pane.created; report real transitions.
            guard previous?.state != session.state, previous != nil || session.state != .stopped else { continue }
            let pane = new.panes.values.first { $0.sessionID == id }
            let space = pane.flatMap { paneSpace(new, $0.id) }
            var data = ["state": session.state.rawValue]
            if let pane { data["paneId"] = pane.id.uuidString }
            events.append(WorkspaceEvent(type: "session.state", resourceID: id, spaceID: space, data: data))
            if session.state == .exited || session.state == .failed {
                var exit = data
                if let code = session.exitCode { exit["exitCode"] = String(code) }
                events.append(WorkspaceEvent(type: "session.exit", resourceID: id, spaceID: space, data: exit))
            }
        }
        if old.activeSpaceID != new.activeSpaceID, let active = new.activeSpaceID {
            events.append(WorkspaceEvent(type: "selection.space", resourceID: active, spaceID: active))
        }
        for space in new.spaces where oldSpaces[space.id]?.activeTabID != space.activeTabID && oldSpaces[space.id] != nil {
            events.append(WorkspaceEvent(type: "selection.tab", resourceID: space.activeTabID, spaceID: space.id))
        }
        for (id, tab) in new.tabs.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where old.tabs[id] != nil && old.tabs[id]?.activePaneID != tab.activePaneID {
            events.append(WorkspaceEvent(type: "selection.pane", resourceID: tab.activePaneID, spaceID: tab.spaceID, data: ["tabId": id.uuidString]))
        }
        return events
    }
}
