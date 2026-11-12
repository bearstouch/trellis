import Foundation
import TrellisCore

/// Workspace, selection and session events for the transition `old → new` (events.md): typed data, updates naming their
/// `changed` fields, a restart (`session.replaced`) and a reconfigured stopped pane (`session.launchChanged`). Pure, so it
/// runs off the main actor.
public enum WorkspaceDiffV2 {
    public static func diff(_ old: WorkspaceSnapshot, _ new: WorkspaceSnapshot) -> [EventDraftV2] {
        guard old != new else { return [] }
        var events: [EventDraftV2] = []
        let oldSpaces = Dictionary(old.spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newSpaces = Dictionary(new.spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func ordered<Value>(_ items: [UUID: Value]) -> [(UUID, Value)] {
            guard items.count > 1 else { return items.map { ($0.key, $0.value) } }
            return items.map { (key: $0.key.uuidString, id: $0.key, value: $0.value) }.sorted { $0.key < $1.key }.map { ($0.id, $0.value) }
        }
        func number(_ value: UInt64) -> JSONValue { .number(Double(value)) }
        func id(_ value: UUID) -> JSONValue { ConventionsV2.idJSON(value) }
        func names(_ fields: [String]) -> JSONValue { .array(fields.map(JSONValue.string)) }
        func ref(_ snapshot: WorkspaceSnapshot, pane: UUID) -> PaneRefV2? { PaneRefV2(pane: pane, in: snapshot) }

        // Removals first, so a client never sees a child outlive its container.
        for space in old.spaces where newSpaces[space.id] == nil {
            events.append(EventDraftV2("space.deleted", kind: "space", id: space.id, spaceID: space.id))
        }
        for (tabID, tab) in ordered(old.tabs.filter { new.tabs[$0.key] == nil }) {
            events.append(EventDraftV2("tab.deleted", kind: "tab", id: tabID, spaceID: tab.spaceID))
        }
        for (paneID, pane) in ordered(old.panes.filter { new.panes[$0.key] == nil }) {
            guard let space = old.tabs[pane.tabID]?.spaceID else { continue }
            events.append(
                EventDraftV2("pane.deleted", kind: "pane", id: paneID, spaceID: space, data: ["tabId": id(pane.tabID)], related: [pane.sessionID, pane.tabID]))
        }

        // Spaces: creation, then updates with the fields that changed.
        for space in new.spaces {
            guard let previous = oldSpaces[space.id] else {
                events.append(EventDraftV2("space.created", kind: "space", id: space.id, spaceID: space.id, data: ["revision": number(space.revision)]))
                continue
            }
            var changed: [String] = []
            if previous.name != space.name { changed.append("name") }
            if previous.tabIDs != space.tabIDs { changed.append("tabIds") }
            if previous.activeTabID != space.activeTabID { changed.append("activeTabId") }
            if previous.projectID != space.projectID { changed.append("project") }
            if previous.remoteHostID != space.remoteHostID { changed.append("machine") }
            guard !changed.isEmpty || previous.revision != space.revision else { continue }
            events.append(
                EventDraftV2("space.updated", kind: "space", id: space.id, spaceID: space.id, data: ["revision": number(space.revision), "changed": names(changed)]))
            if Set(previous.tabIDs) == Set(space.tabIDs), previous.tabIDs != space.tabIDs {
                events.append(EventDraftV2("tab.reordered", kind: "space", id: space.id, spaceID: space.id, data: ["revision": number(space.revision)]))
            }
        }
        // Only a pure reorder of the same spaces; it reveals every space's place, so it needs all-spaces scope.
        if Set(old.spaces.map(\.id)) == Set(new.spaces.map(\.id)), old.spaces.map(\.id) != new.spaces.map(\.id) {
            var event = EventDraftV2("space.reordered", kind: "workspace", id: "", data: ["revision": number(new.revision)])
            event.allSpaces = true
            events.append(event)
        }

        // Tabs: a layout change is its own event; other fields are a tab.updated.
        for (tabID, tab) in ordered(new.tabs.filter { old.tabs[$0.key] != $0.value }) {
            let revision = number(tab.revision)
            guard let previous = old.tabs[tabID] else {
                events.append(EventDraftV2("tab.created", kind: "tab", id: tabID, spaceID: tab.spaceID, data: ["revision": revision]))
                continue
            }
            if previous.root != tab.root { events.append(EventDraftV2("tab.layoutChanged", kind: "tab", id: tabID, spaceID: tab.spaceID, data: ["revision": revision])) }
            var changed: [String] = []
            if previous.title != tab.title { changed.append("title") }
            if previous.color != tab.color { changed.append("color") }
            if previous.activePaneID != tab.activePaneID { changed.append("activePaneId") }
            if previous.projectKey != tab.projectKey { changed.append("projectKey") }
            if !changed.isEmpty || (previous.root == tab.root && previous.revision != tab.revision) {
                events.append(EventDraftV2("tab.updated", kind: "tab", id: tabID, spaceID: tab.spaceID, data: ["revision": revision, "changed": names(changed)]))
            }
        }

        // Panes: created, or updated with what changed (maximizing is reported by the app, which holds it).
        for (paneID, pane) in ordered(new.panes.filter { old.panes[$0.key] != $0.value || old.tabs[$0.value.tabID]?.activePaneID != new.tabs[$0.value.tabID]?.activePaneID }) {
            guard let space = new.tabs[pane.tabID]?.spaceID else { continue }
            let related: Set<UUID> = [pane.sessionID, pane.tabID]
            guard let previous = old.panes[paneID] else {
                events.append(
                    EventDraftV2(
                        "pane.created", kind: "pane", id: paneID, spaceID: space, data: ["tabId": id(pane.tabID), "sessionId": id(pane.sessionID)], related: related))
                continue
            }
            var changed: [String] = []
            if previous.title != pane.title { changed.append("title") }
            if previous.sessionID != pane.sessionID { changed.append("sessionId") }
            if (old.tabs[pane.tabID]?.activePaneID == paneID) != (new.tabs[pane.tabID]?.activePaneID == paneID) { changed.append("focused") }
            guard !changed.isEmpty else { continue }
            events.append(EventDraftV2("pane.updated", kind: "pane", id: paneID, spaceID: space, data: ["tabId": id(pane.tabID), "changed": names(changed)], related: related))
        }

        // Sessions: a restart replaces the pane's session; otherwise state and launch changes of the same session.
        for (paneID, pane) in ordered(new.panes) {
            guard let ref = ref(new, pane: paneID), let session = new.sessions[pane.sessionID] else { continue }
            func event(_ type: String, _ data: [String: JSONValue]) -> EventDraftV2 {
                var data = data
                data["paneId"] = id(paneID)
                return EventDraftV2(type, kind: "session", id: session.id, spaceID: ref.space, data: data, related: [paneID, ref.tab])
            }
            let previousSessionID = old.panes[paneID]?.sessionID
            if let previousSessionID, previousSessionID != session.id {
                events.append(event("session.replaced", ["previousId": id(previousSessionID)]))
            }
            guard let previous = old.sessions[session.id] else {
                // A new stopped session is announced by pane.created or session.replaced; report real transitions only.
                if session.state != .stopped { events.append(contentsOf: transition(of: session, from: nil, event)) }
                continue
            }
            if previous.launch != session.launch { events.append(event("session.launchChanged", ["launch": .object(["kind": .string(Self.kind(of: session.launch))])])) }
            if previous.state != session.state { events.append(contentsOf: transition(of: session, from: previous.state, event)) }
        }

        if old.activeSpaceID != new.activeSpaceID, let active = new.activeSpaceID {
            events.append(EventDraftV2("selection.space", kind: "space", id: active, spaceID: active))
        }
        for space in new.spaces where oldSpaces[space.id] != nil && oldSpaces[space.id]?.activeTabID != space.activeTabID {
            events.append(EventDraftV2("selection.tab", kind: "tab", id: space.activeTabID, spaceID: space.id))
        }
        for (tabID, tab) in ordered(new.tabs.filter { old.tabs[$0.key] != nil && old.tabs[$0.key]?.activePaneID != $0.value.activePaneID }) {
            events.append(EventDraftV2("selection.pane", kind: "pane", id: tab.activePaneID, spaceID: tab.spaceID, data: ["tabId": id(tabID)], related: [tabID]))
        }
        return events
    }

    private static func transition(
        of session: WorkspaceSession, from previous: SessionState?, _ event: (String, [String: JSONValue]) -> EventDraftV2
    ) -> [EventDraftV2] {
        var data: [String: JSONValue] = ["state": .string(session.state.rawValue)]
        if let previous { data["previous"] = .string(previous.rawValue) }
        var events = [event("session.state", data)]
        if session.state == .exited || session.state == .failed {
            var exit: [String: JSONValue] = ["state": .string(session.state.rawValue)]
            if let code = session.exitCode { exit["exitCode"] = .number(Double(code)) }
            events.append(event("session.exited", exit))
        }
        return events
    }

    /// `launch.kind` as resources.md names it; a login shell recorded as its program is a shell.
    public static func kind(of launch: SessionLaunch) -> String {
        switch launch {
        case .shell: "shell"
        case .process(_, let arguments, _) where arguments == ["-l"]: "shell"
        case .process: "process"
        case .host: "ssh"
        case .remoteShell: "remoteShell"
        case .agent: "agent"
        }
    }
}
