import Foundation
import TrellisCore

/// Protocol 2 event topics (docs/api/v2/events.md). Each topic is gated by the capabilities a grant needs to receive it at
/// all; space, host and project scope and per-field rules are checked per event on top.
public enum EventTopicV2: String, CaseIterable, Sendable, Comparable {
    case workspace, selection, session, attention, shell, agent, remote, project, task, host, appearance, grant, output

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var capabilities: Set<CapabilityV2> {
        switch self {
        case .workspace, .selection, .session, .attention, .shell, .agent: [.workspaceRead]
        case .remote, .host: [.hostRead]
        case .project: [.projectRead]
        case .task: [.taskRead]
        case .appearance: [.themeRead]
        case .grant: []
        case .output: [.sessionOutputRead]
        }
    }

    /// Every event type and its topic: the table in events.md, which a test compares with the page.
    public static let types: [String: EventTopicV2] = {
        var types: [String: EventTopicV2] = [:]
        let table: [(EventTopicV2, [String])] = [
            (
                .workspace,
                [
                    "space.created", "space.updated", "space.deleted", "space.reordered", "tab.created", "tab.updated", "tab.deleted", "tab.reordered", "tab.layoutChanged",
                    "pane.created", "pane.updated", "pane.deleted"
                ]
            ),
            (.selection, ["selection.space", "selection.tab", "selection.pane"]),
            (.session, ["session.state", "session.exited", "session.replaced", "session.launchChanged"]),
            (.attention, ["pane.needsInput", "pane.progress", "tab.busy"]),
            (.shell, ["command.started", "command.finished", "folder.changed"]),
            (.agent, ["agent.state", "agent.settings", "agent.started", "agent.ended", "agent.availability"]),
            (.remote, ["remote.link", "remote.helper"]),
            (.project, ["project.created", "project.updated", "project.deleted", "project.launched"]),
            (.task, ["task.run"]),
            (.host, ["host.created", "host.updated", "host.deleted"]),
            (.appearance, ["appearance.changed"]),
            (.grant, ["grant.changed"]),
            (.output, ["session.output"])
        ]
        for (topic, names) in table { for name in names { types[name] = topic } }
        return types
    }()

    /// Live status reported at most once per window per resource and type (the latest state wins).
    public static let coalescedTypes: Set<String> = ["pane.needsInput", "pane.progress", "tab.busy", "agent.state", "agent.settings"]
}

/// A host an event concerns. Remote link and helper events need the host's current approval (`connectionRevision`);
/// host library events only need the host to be approved at all, as host methods answer PERMISSION_DENIED rather than
/// NOT_FOUND for a stale approval.
public struct EventHostV2: Sendable, Equatable {
    public let id: UUID
    public let connectionRevision: UInt64?
    public init(id: UUID, connectionRevision: UInt64?) { self.id = id; self.connectionRevision = connectionRevision }

    func allowed(for grant: AutomationGrant) -> Bool {
        guard grant.holds(.hostRead) else { return false }
        switch grant.hostScope {
        case .all: return true
        case .approved(let approvals):
            return approvals.contains { $0.hostID == id && (connectionRevision == nil || $0.connectionRevision == connectionRevision) }
        }
    }
}

/// A `data` field shown only to grants that pass the rule; without it the field is omitted.
public enum FieldRuleV2: Sendable, Equatable {
    case capability(CapabilityV2)
    case host(EventHostV2)

    func allows(_ grant: AutomationGrant) -> Bool {
        switch self {
        case .capability(let capability): grant.holds(capability)
        case .host(let host): host.allowed(for: grant)
        }
    }
}

/// Where a pane-level event happened, resolved on the main actor when it is emitted. An event whose pane is already gone
/// is never built, so nothing is delivered without a space to scope it.
public struct PaneRefV2: Sendable, Equatable {
    public let pane: UUID
    public let session: UUID
    public let tab: UUID
    public let space: UUID
    public init(pane: UUID, session: UUID, tab: UUID, space: UUID) { self.pane = pane; self.session = session; self.tab = tab; self.space = space }

    public init?(pane id: UUID, in snapshot: WorkspaceSnapshot) {
        guard let pane = snapshot.panes[id], let tab = snapshot.tabs[pane.tabID] else { return nil }
        self.init(pane: id, session: pane.sessionID, tab: tab.id, space: tab.spaceID)
    }
}

/// One event before the hub numbers it: what it is, where it lives and who may see which parts. Data never holds
/// terminal output (only `session.output`), typed input, command text, environment values or secrets.
public struct EventDraftV2: Sendable, Equatable {
    public var type: String
    /// `resource.kind`; the id is a UUID (written lowercase), an agent or task ID, or empty (workspace, appearance).
    public var resourceKind: String
    public var resourceID: String
    public var spaceID: UUID?
    public var data: [String: JSONValue]
    /// Other IDs `resourceIds` matches: the pane, its session and tab.
    public var related: Set<UUID>
    /// Needs all-spaces scope (`space.reordered`).
    public var allSpaces = false
    public var host: EventHostV2?
    /// Needs project.read and the project in project scope.
    public var projectID: UUID?
    public var fieldRules: [String: FieldRuleV2] = [:]
    /// Only this grant receives it (`grant.changed`).
    public var audience: UUID?

    public init(_ type: String, kind: String, id: String, spaceID: UUID? = nil, data: [String: JSONValue] = [:], related: Set<UUID> = []) {
        self.type = type; resourceKind = kind; resourceID = id; self.spaceID = spaceID; self.data = data; self.related = related
    }

    public init(_ type: String, kind: String, id: UUID, spaceID: UUID? = nil, data: [String: JSONValue] = [:], related: Set<UUID> = []) {
        self.init(type, kind: kind, id: ConventionsV2.id(id), spaceID: spaceID, data: data, related: related)
    }

    public var topic: EventTopicV2 { EventTopicV2.types[type] ?? .workspace }
    var isCoalesced: Bool { EventTopicV2.coalescedTypes.contains(type) }
    var coalesceKey: String { type + "\u{0}" + resourceID }

    /// Every ID `resourceIds` and `spaceIds` can name for this event.
    var matchIDs: Set<UUID> {
        var ids = related
        if let id = ConventionsV2.parseID(resourceID) { ids.insert(id) }
        if let spaceID { ids.insert(spaceID) }
        return ids
    }

    /// The data this grant may see, or nil when the event isn't for it at all (events.md, Delivery and redaction).
    /// `createdBy`: the grants that had created the event's space when it was published (see `EventHubV2`).
    public func data(for grant: AutomationGrant, createdBy: Set<UUID> = []) -> [String: JSONValue]? {
        if let audience, audience != grant.id { return nil }
        guard topic.capabilities.isSubset(of: grant.capabilitiesV2) else { return nil }
        if let spaceID {
            guard grant.reaches(space: spaceID) || (grant.spaceScope == .created && createdBy.contains(grant.id)) else { return nil }
        } else if allSpaces {
            guard grant.spaceScope == .all else { return nil }
        }
        if let host, !host.allowed(for: grant) { return nil }
        if let projectID {
            guard grant.holds(.projectRead) else { return nil }
            if case .projects(let ids) = grant.projectScope, !ids.contains(projectID) { return nil }
        }
        var data = self.data
        for (field, rule) in fieldRules where !rule.allows(grant) { data.removeValue(forKey: field) }
        return data
    }
}

// MARK: - Builders for the live-state sources (events.md, Topics and types)

extension EventDraftV2 {
    private static func pane(_ type: String, _ ref: PaneRefV2, _ data: [String: JSONValue] = [:]) -> Self {
        var data = data
        data["sessionId"] = ConventionsV2.idJSON(ref.session)
        return Self(type, kind: "pane", id: ref.pane, spaceID: ref.space, data: data, related: [ref.session, ref.tab])
    }

    /// Agent and shell events are about the program in the pane's session.
    private static func session(_ type: String, _ ref: PaneRefV2, _ data: [String: JSONValue] = [:]) -> Self {
        var data = data
        data["paneId"] = ConventionsV2.idJSON(ref.pane)
        return Self(type, kind: "session", id: ref.session, spaceID: ref.space, data: data, related: [ref.pane, ref.tab])
    }

    private static func milliseconds(_ interval: TimeInterval) -> JSONValue { .number((max(0, interval) * 1_000).rounded()) }

    /// `pane.needsInput`: a password prompt or a bell or notification while out of view (FR-T06); nil clears it.
    public static func needsInput(_ ref: PaneRefV2, reason: InputWaitReason?) -> Self {
        pane("pane.needsInput", ref, reason.map { ["reason": .string($0.rawValue)] } ?? ["cleared": .bool(true)])
    }

    /// `pane.progress`: OSC 9;4 (FR-T09); nil clears it.
    public static func progress(_ ref: PaneRefV2, _ progress: TerminalProgress?) -> Self {
        guard let progress else { return pane("pane.progress", ref, ["cleared": .bool(true)]) }
        var data: [String: JSONValue] = ["state": .string(progress.state.rawValue)]
        if let percent = progress.percent { data["percent"] = .number(Double(percent)) }
        return pane("pane.progress", ref, data)
    }

    public static func tabBusy(tab: UUID, space: UUID, busy: Bool) -> Self {
        Self("tab.busy", kind: "tab", id: tab, spaceID: space, data: ["busy": .bool(busy)])
    }

    /// One per shell-integration mark; never the command line or the program's name.
    public static func commandStarted(_ ref: PaneRefV2) -> Self { session("command.started", ref) }

    public static func commandFinished(_ ref: PaneRefV2, exitCode: Int32?, duration: TimeInterval?) -> Self {
        var data: [String: JSONValue] = [:]
        if let exitCode { data["exitCode"] = .number(Double(exitCode)) }
        if let duration { data["durationMs"] = milliseconds(duration) }
        return session("command.finished", ref, data)
    }

    /// The path is shown only with session.execute, like a pane's `folder`.
    public static func folderChanged(_ ref: PaneRefV2, path: String) -> Self {
        var event = session("folder.changed", ref, ["path": .string(path)])
        event.fieldRules["path"] = .capability(.sessionExecute)
        return event
    }

    public static func agentState(_ ref: PaneRefV2, agentID: String, state: AgentState, previous: AgentState?) -> Self {
        var data: [String: JSONValue] = ["agentId": .string(agentID), "state": .string(state.rawValue)]
        if let previous { data["previous"] = .string(previous.rawValue) }
        return session("agent.state", ref, data)
    }

    /// Agent-reported model names are untrusted text, returned as data.
    public static func agentSettings(_ ref: PaneRefV2, agentID: String, settings: AgentSettings) -> Self {
        var data: [String: JSONValue] = ["agentId": .string(agentID)]
        if let model = settings.model, !model.isEmpty { data["model"] = .string(model) }
        if let effort = settings.effort, !effort.isEmpty { data["effort"] = .string(effort) }
        return session("agent.settings", ref, data)
    }

    public static func agentStarted(_ ref: PaneRefV2, agentID: String) -> Self { session("agent.started", ref, ["agentId": .string(agentID)]) }
    public static func agentEnded(_ ref: PaneRefV2, agentID: String) -> Self { session("agent.ended", ref, ["agentId": .string(agentID)]) }

    /// `status`: installed, missing or checking on this Mac; on a host (`host`), missing or unknown. A host's availability
    /// needs host.read and the host in scope.
    public static func agentAvailability(agentID: String, status: String, host: EventHostV2? = nil) -> Self {
        var event = Self("agent.availability", kind: "agent", id: agentID, data: ["status": .string(status)])
        if let host {
            event.data["hostId"] = ConventionsV2.idJSON(host.id)
            event.host = host
        }
        return event
    }

    /// A remote workspace host's link (FR-RW07). `reason` is the stable code, never the words the app shows.
    public static func remoteLink(host: EventHostV2, state: String, attempt: Int? = nil, nextAttemptAt: Date? = nil, reason: RemoteLinkReason? = nil) -> Self {
        var event = Self("remote.link", kind: "host", id: host.id, data: ["state": .string(state)])
        if let attempt { event.data["attempt"] = .number(Double(attempt)) }
        if let nextAttemptAt { event.data["nextAttemptAt"] = .string(ConventionsV2.timestamp(nextAttemptAt)) }
        if let reason { event.data["reason"] = .string(reason.rawValue) }
        event.host = host
        return event
    }

    public static func remoteHelper(host: EventHostV2, status: String) -> Self {
        var event = Self("remote.helper", kind: "host", id: host.id, data: ["status": .string(status)])
        event.host = host
        return event
    }

    /// `host.created/updated/deleted` (`changed` on updates).
    public static func host(_ type: String, id: UUID, revision: UInt64?, connectionRevision: UInt64, changed: [String]? = nil) -> Self {
        var event = Self(type, kind: "host", id: id, data: ["connectionRevision": .number(Double(connectionRevision))])
        if let revision { event.data["revision"] = .number(Double(revision)) }
        if let changed { event.data["changed"] = .array(changed.map(JSONValue.string)) }
        event.host = EventHostV2(id: id, connectionRevision: nil)
        return event
    }

    public static func project(_ type: String, id: UUID, revision: UInt64?, changed: [String]? = nil) -> Self {
        var event = Self(type, kind: "project", id: id)
        if let revision { event.data["revision"] = .number(Double(revision)) }
        if let changed { event.data["changed"] = .array(changed.map(JSONValue.string)) }
        event.projectID = id
        return event
    }

    /// The launched space and target; a host target's ID needs the host in scope and the folder needs session.execute.
    public static func projectLaunched(id: UUID, space: UUID, target: ProjectTarget, folder: String?, hostConnectionRevision: UInt64?) -> Self {
        var event = Self("project.launched", kind: "project", id: id, spaceID: space, data: ["spaceId": ConventionsV2.idJSON(space)])
        event.projectID = id
        switch target {
        case .local: event.data["target"] = .object(["kind": .string("local")])
        case .host(let host):
            event.data["target"] = .object(["kind": .string("host")])
            event.data["hostId"] = ConventionsV2.idJSON(host)
            event.fieldRules["hostId"] = .host(EventHostV2(id: host, connectionRevision: hostConnectionRevision))
        }
        if let folder, !folder.isEmpty {
            event.data["folder"] = .string(folder)
            event.fieldRules["folder"] = .capability(.sessionExecute)
        }
        return event
    }

    /// `task.run` phases: submitted, running, finished (`exitCode?`, `durationMs`), cancelled (the shell came back without
    /// running it, or the session ended first). Never the task's command.
    public static func taskRun(_ ref: PaneRefV2, taskID: String, run: TaskRun?) -> Self {
        var data: [String: JSONValue] = ["paneId": ConventionsV2.idJSON(ref.pane), "sessionId": ConventionsV2.idJSON(ref.session)]
        switch run?.phase {
        case .submitted?: data["phase"] = .string("submitted")
        case .running?: data["phase"] = .string("running")
        case .finished(let code, let duration)?:
            data["phase"] = .string("finished")
            if let code { data["exitCode"] = .number(Double(code)) }
            data["durationMs"] = milliseconds(duration)
        case nil: data["phase"] = .string("cancelled")
        }
        return Self("task.run", kind: "task", id: taskID, spaceID: ref.space, data: data, related: [ref.pane, ref.session, ref.tab])
    }

    public static func appearance(mode: String, lightThemeID: String, darkThemeID: String, effectiveThemeID: String, revision: UInt64) -> Self {
        Self(
            "appearance.changed", kind: "appearance", id: "",
            data: [
                "mode": .string(mode), "lightThemeId": .string(lightThemeID), "darkThemeId": .string(darkThemeID), "effectiveThemeId": .string(effectiveThemeID),
                "revision": .number(Double(revision))
            ])
    }

    /// Only to the edited grant's own subscribers and pollers.
    public static func grantChanged(_ grant: AutomationGrant) -> Self {
        var event = Self("grant.changed", kind: "grant", id: grant.id, data: ["revision": .number(Double(grant.revision))])
        event.audience = grant.id
        return event
    }
}

// MARK: - Library changes

extension EventDraftV2 {
    /// `host.created/updated/deleted` between two committed host lists, with the fields that changed on updates.
    public static func hostChanges(_ old: [SavedHost], _ new: [SavedHost]) -> [Self] {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Set(new.map(\.id))
        var events = old.filter { !after.contains($0.id) }.map { host("host.deleted", id: $0.id, revision: nil, connectionRevision: $0.connectionRevision) }
        for host in new {
            guard let previous = before[host.id] else {
                events.append(Self.host("host.created", id: host.id, revision: host.revision, connectionRevision: host.connectionRevision))
                continue
            }
            guard previous != host else { continue }
            var changed: [String] = []
            if previous.name != host.name { changed.append("name") }
            if previous.destination != host.destination { changed.append("destination") }
            if previous.user != host.user { changed.append("user") }
            if previous.port != host.port { changed.append("port") }
            if previous.identityFile != host.identityFile { changed.append("identityFile") }
            if previous.tags != host.tags { changed.append("tags") }
            if previous.savedPassword != host.savedPassword { changed.append("password") }
            events.append(Self.host("host.updated", id: host.id, revision: host.revision, connectionRevision: host.connectionRevision, changed: changed))
        }
        return events
    }

    /// `project.created/updated/deleted` between two committed project lists. Field names only: a project's commands,
    /// folders and repositories are never in an event.
    public static func projectChanges(_ old: [ProjectDefinition], _ new: [ProjectDefinition]) -> [Self] {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Set(new.map(\.id))
        var events = old.filter { !after.contains($0.id) }.map { project("project.deleted", id: $0.id, revision: nil) }
        for project in new {
            guard let previous = before[project.id] else {
                events.append(Self.project("project.created", id: project.id, revision: project.revision))
                continue
            }
            guard previous != project else { continue }
            var changed: [String] = []
            if previous.name != project.name { changed.append("name") }
            if previous.notes != project.notes { changed.append("notes") }
            if previous.repository != project.repository { changed.append("repository") }
            if previous.tabs != project.tabs { changed.append("tabs") }
            if previous.lastFolders != project.lastFolders { changed.append("lastFolders") }
            events.append(Self.project("project.updated", id: project.id, revision: project.revision, changed: changed))
        }
        return events
    }
}
