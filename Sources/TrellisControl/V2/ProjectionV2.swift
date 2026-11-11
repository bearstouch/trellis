import Foundation
import TrellisCore

// Live state the app shows but the store doesn't hold, captured on the main actor in one pass so a projection is built
// from one consistent moment (docs/api/v2/resources.md). Plain values: projection tests build them by hand.

/// The agent a pane runs (resources.md#agent-run); its pane's `agent` field is the summary of this.
public struct AgentSummaryV2: Sendable, Equatable {
    public var agentID: String
    public var state: AgentState
    /// Started as an agent pane; otherwise typed in a shell and recognised (FR-AG15).
    public var managed: Bool
    /// When the run entered its current state.
    public var since: Date?
    /// A Done the user hasn't seen (FR-AG10).
    public var unseen: Bool
    /// As the agent reported them (FR-AG19): untrusted text.
    public var settings: AgentSettings
    public init(agentID: String, state: AgentState, managed: Bool = true, since: Date? = nil, unseen: Bool = false, settings: AgentSettings = AgentSettings()) {
        self.agentID = agentID; self.state = state; self.managed = managed; self.since = since; self.unseen = unseen; self.settings = settings
    }
}

public struct PaneRuntimeV2: Sendable, Equatable {
    public var revision: UInt64 = 0
    public var maximized = false
    /// The terminal's state and exit code, when the terminal belongs to the pane's current session.
    public var liveState: SessionState?
    public var liveExitCode: Int32?
    /// The session runs in the broker and survives quitting (FR-R03).
    public var kept = false
    public var sessionRevision: UInt64 = 0
    /// The shell's current directory (authenticated marks, or a remote workspace pane's own); else the launch's.
    public var folder: String?
    public var shell: ShellIntegrationState?
    public var needsInput: InputWaitReason?
    public var progress: TerminalProgress?
    public var agent: AgentSummaryV2?
    /// The task Run typed into the pane, active or just finished (FR-TK07).
    public var task: TaskRun?
    public init() {}
}

public struct TabRuntimeV2: Sendable, Equatable {
    /// What the tab shows: the custom title, or the automatic one (program, agent, folder).
    public var title: String
    public var busy = false
    public var progress: TerminalProgress?
    public var needsInput: InputWaitReason?
    public var agent: AgentState?
    public var linkDown = false
    public var maximizedPaneID: UUID?
    public init(title: String) { self.title = title }
}

public struct SpaceRuntimeV2: Sendable, Equatable {
    public enum Activity: String, Sendable { case output, exit }
    /// The space's project was deleted from the library (known only once the library loaded).
    public var projectMissing = false
    /// The project's name, and the folder the space was launched in as the launch remembers it (absolute on this Mac,
    /// relative to home on a host), when known.
    public var projectName: String?
    public var projectFolder: String?
    public var activity: Activity?
    public init() {}
}

/// A remote workspace host's link (FR-RW07), with reason codes rather than the words the app shows.
public enum RemoteLinkV2: Sendable, Equatable {
    case connecting, connected, offline
    case needsInput(reason: RemoteLinkReason)
    case disconnected(reason: RemoteLinkReason)
    case reconnecting(attempt: Int, at: Date)
}

public struct HostRuntimeV2: Sendable, Equatable {
    public var helper: RemoteHelperRecord?
    public var autoInstall = false
    public var link: RemoteLinkV2?
    public init(helper: RemoteHelperRecord? = nil, autoInstall: Bool = false, link: RemoteLinkV2? = nil) { self.helper = helper; self.autoInstall = autoInstall; self.link = link }
}

public struct RuntimeV2: Sendable, Equatable {
    public var panes: [UUID: PaneRuntimeV2] = [:]
    public var tabs: [UUID: TabRuntimeV2] = [:]
    public var spaces: [UUID: SpaceRuntimeV2] = [:]
    public init() {}
}

/// Builds v2 resources (resources.md) for one grant: out-of-scope resources never appear, fields marked with a
/// capability are omitted without it, host IDs need host.read and the host in scope, absent values are omitted.
public struct ProjectionV2: Sendable {
    public let snapshot: WorkspaceSnapshot
    public let runtime: RuntimeV2
    /// Saved hosts, for host scope checks on host IDs.
    public let hosts: [UUID: SavedHost]
    public let access: GrantAccess
    public let capabilities: Set<CapabilityV2>

    public init(snapshot: WorkspaceSnapshot, runtime: RuntimeV2, hosts: [UUID: SavedHost], grant: AutomationGrant) {
        self.snapshot = snapshot; self.runtime = runtime; self.hosts = hosts
        access = GrantAccess(grant: grant, snapshot: snapshot); capabilities = CapabilityV2.granted(by: grant)
    }

    var executes: Bool { capabilities.contains(.sessionExecute) }

    // MARK: Visibility

    public func visibleSpaces() -> [Space] { snapshot.spaces.filter { access.canSee(space: $0.id) } }
    public func canSee(_ kind: ResourceKind, _ id: UUID) -> Bool { access.owningSpace(kind, id).map { access.canSee(space: $0) } ?? false }

    /// A host ID is shown only with host.read and the host in scope (resources.md#machine).
    public func showsHost(_ id: UUID) -> Bool { capabilities.contains(.hostRead) && access.hostAccess(hosts[id]) == .allowed }

    // MARK: Machine

    public func machine(kind: String, hostID: UUID?) -> JSONValue {
        var object = ResultObjectV2()
        object.set("kind", kind)
        if let hostID, showsHost(hostID) { object.set("hostId", hostID) }
        return object.json
    }

    /// Where a session runs: an SSH pane, a remote workspace's host, or this Mac.
    public func machine(of launch: SessionLaunch) -> JSONValue {
        switch launch {
        case .host(let id): machine(kind: "ssh", hostID: id)
        case .remoteShell(let id, _): machine(kind: "remote", hostID: id)
        case .agent(let agent): agent.hostID.map { machine(kind: "remote", hostID: $0) } ?? machine(kind: "local", hostID: nil)
        case .shell, .process: machine(kind: "local", hostID: nil)
        }
    }

    // MARK: Space

    public func space(_ space: Space) -> JSONValue {
        var object = ResultObjectV2()
        let live = runtime.spaces[space.id] ?? SpaceRuntimeV2()
        object.set("id", space.id)
        object.set("name", space.name)
        object.set("revision", space.revision)
        object.set("machine", machine(kind: space.remoteHostID == nil ? "local" : "remote", hostID: space.remoteHostID))
        // Project scope covers a project space's `project` field (permissions.md#scopes); the space itself follows space scope.
        if let projectID = space.projectID, access.reaches(project: projectID) {
            // name and target need project.read; folder also session.execute (resources.md#space).
            var project = ResultObjectV2()
            project.set("id", projectID)
            if capabilities.contains(.projectRead) {
                project.set("name", live.projectName)
                project.set("target", projectTarget(space.remoteHostID.map { .host($0) } ?? .local))
                if executes { project.set("folder", live.projectFolder) }
            }
            if live.projectMissing { project.set("missing", true) }
            object.set("project", project.json)
        }
        object.set("tabIds", space.tabIDs)
        object.set("activeTabId", space.activeTabID)
        object.set("active", snapshot.activeSpaceID == space.id)
        var attention = ResultObjectV2()
        let waiting = space.tabIDs.flatMap { snapshot.tabs[$0]?.root.paneIDs ?? [] }.filter { runtime.panes[$0]?.needsInput != nil }.count
        if waiting > 0 { attention.set("needsInput", waiting) }
        if snapshot.activeSpaceID != space.id { attention.set("activity", live.activity?.rawValue) }
        object.set("attention", attention.json)
        return object.json
    }

    // MARK: Tab

    public func tab(_ tab: WorkspaceTab, layout: Bool) -> JSONValue {
        var object = ResultObjectV2()
        let live = runtime.tabs[tab.id] ?? TabRuntimeV2(title: tab.title)
        let projectSpace = snapshot.spaces.first { $0.id == tab.spaceID }.map { $0.projectID != nil && runtime.spaces[$0.id]?.projectMissing != true } ?? false
        object.set("id", tab.id)
        object.set("spaceId", tab.spaceID)
        object.set("revision", tab.revision)
        // FR-W08: a project space's tabs come from the project or are temporary; a deleted project leaves standard tabs.
        object.set("role", tab.projectKey != nil ? "project" : projectSpace ? "temporary" : "standard")
        object.set("projectKey", tab.projectKey)
        object.set("title", live.title)
        object.set("customTitle", tab.title != WorkspaceTab.defaultTitle)
        object.set("color", tab.color?.rawValue)
        object.set("activePaneId", tab.activePaneID)
        object.set("paneIds", tab.root.paneIDs)
        object.set("maximizedPaneId", live.maximizedPaneID)
        var status = ResultObjectV2()
        if live.busy { status.set("busy", true) }
        status.set("progress", live.progress.map(progress))
        status.set("needsInput", live.needsInput?.rawValue)
        status.set("agent", live.agent?.rawValue)
        if live.linkDown { status.set("linkDown", true) }
        object.set("status", status.json)
        if layout { object.set("layout", self.layout(tab.root)) }
        return object.json
    }

    public func layout(_ node: PaneLayout) -> JSONValue {
        switch node {
        case .pane(let id): .object(["type": .string("pane"), "id": ConventionsV2.idJSON(id)])
        case .split(let id, let axis, let ratio, let children):
            .object([
                "type": .string("split"), "id": ConventionsV2.idJSON(id), "axis": .string(axis.rawValue), "ratio": .number(ratio), "children": .array(children.map(layout))
            ])
        }
    }

    private func progress(_ progress: TerminalProgress) -> JSONValue {
        var object = ResultObjectV2()
        object.set("state", progress.state.rawValue)
        object.set("percent", progress.percent)
        return object.json
    }

    // MARK: Pane

    public func pane(_ pane: WorkspacePane) -> JSONValue {
        var object = ResultObjectV2()
        let live = runtime.panes[pane.id] ?? PaneRuntimeV2()
        let tab = snapshot.tabs[pane.tabID]
        let launch = snapshot.sessions[pane.sessionID]?.launch
        object.set("id", pane.id)
        object.set("tabId", pane.tabID)
        object.set("spaceId", tab?.spaceID)
        object.set("revision", live.revision)
        object.set("title", pane.title)
        object.set("machine", launch.map(machine(of:)) ?? machine(kind: "local", hostID: nil))
        object.set("sessionId", pane.sessionID)
        object.set("focused", tab?.activePaneID == pane.id)
        object.set("maximized", live.maximized)
        if executes { object.set("folder", live.folder ?? launch.flatMap(Self.directory)) }
        var shell = ResultObjectV2()
        if let state = live.shell {
            shell.set("integration", state.origin == .remote ? "remote" : "authenticated")
            shell.set("commandRunning", state.commandRunning)
            if state.commandRunning { shell.set("commandStartedAt", state.commandStartedAt) }
            shell.set("lastExitCode", state.lastExitCode)
            shell.set("lastDurationMs", state.lastDuration.map { Int64(($0 * 1_000).rounded()) })
        } else {
            shell.set("integration", "none")
        }
        object.set("shell", shell.json)
        var attention = ResultObjectV2()
        attention.set("needsInput", live.needsInput?.rawValue)
        attention.set("progress", live.progress.map(progress))
        object.set("attention", attention.json)
        if let agent = live.agent { object.set("agent", JSONValue.object(["agentId": .string(agent.agentID), "state": .string(agent.state.rawValue)])) }
        if let task = live.task { object.set("task", JSONValue.object(["taskId": .string(task.taskID), "phase": .string(Self.phase(task))])) }
        return object.json
    }

    /// The directory a launch starts in, when it names one.
    static func directory(_ launch: SessionLaunch) -> String? {
        switch launch {
        case .shell(let directory), .process(_, _, let directory), .remoteShell(_, let directory): directory
        case .agent(let agent): agent.directory
        case .host: nil
        }
    }

    // MARK: Session

    public func session(_ session: WorkspaceSession, paneID: UUID) -> JSONValue {
        var object = ResultObjectV2()
        let live = runtime.panes[paneID] ?? PaneRuntimeV2()
        object.set("id", session.id)
        object.set("paneId", paneID)
        object.set("revision", live.sessionRevision)
        object.set("state", (live.liveState ?? session.state).rawValue)
        object.set("kept", live.kept)
        object.set("launch", launch(session.launch))
        object.set("createdAt", session.createdAt)
        object.set("startedAt", session.startedAt)
        object.set("endedAt", session.endedAt)
        object.set("exitCode", live.liveExitCode ?? session.exitCode)
        object.set("failureMessage", session.failureMessage)
        return object.json
    }

    /// resources.md#session: details marked (execute) need session.execute, host IDs need host.read; never an environment.
    public func launch(_ launch: SessionLaunch) -> JSONValue {
        var object = ResultObjectV2()
        switch launch {
        case .shell(let directory):
            object.set("kind", "shell")
            if executes { object.set("directory", directory) }
        case .process(_, let arguments, let directory) where arguments == ["-l"]:
            // A login shell is recorded as its resolved program; it is reported as the shell it is.
            object.set("kind", "shell")
            if executes { object.set("directory", directory) }
        case .process(let executable, let arguments, let directory):
            object.set("kind", "process")
            if executes {
                object.set("executable", executable)
                object.set("arguments", JSONValue.array(arguments.map(JSONValue.string)))
                object.set("directory", directory)
            }
        case .host(let id):
            object.set("kind", "ssh")
            if showsHost(id) { object.set("hostId", id) }
        case .remoteShell(let id, let directory):
            object.set("kind", "remoteShell")
            if showsHost(id) { object.set("hostId", id) }
            if executes { object.set("directory", directory) }
        case .agent(let agent):
            // FR-AG13: the agent, never the command line Trellis builds for it.
            object.set("kind", "agent")
            object.set("agentId", agent.agentID)
            object.set("machine", machine(of: launch))
            if executes { object.set("directory", agent.directory) }
        }
        return object.json
    }

    // MARK: Host

    public func host(_ host: SavedHost, remote: HostRuntimeV2?) -> JSONValue {
        var object = ResultObjectV2()
        object.set("id", host.id)
        object.set("name", host.name)
        object.set("destination", host.destination)
        object.set("user", host.user)
        object.set("port", host.port)
        object.set("identityFile", host.identityFile)
        object.set("tags", JSONValue.array(host.tags.map(JSONValue.string)))
        object.set("revision", host.revision)
        object.set("connectionRevision", host.connectionRevision)
        var password = ResultObjectV2()
        password.set("saved", host.savedPassword != nil)
        if let policy = host.savedPassword { password.set("requiresUserPresence", policy.requiresUserPresence) }
        object.set("password", password.json)
        // Present once the host has been used as a remote workspace: a helper check or a link.
        if let remote, remote.helper != nil || remote.link != nil { object.set("remote", Self.remote(remote)) }
        return object.json
    }

    /// A host's helper and link (resources.md#host): `remote.*` results always carry it, `helper` `unknown` before any check.
    public static func remote(_ remote: HostRuntimeV2) -> JSONValue {
        var state = ResultObjectV2()
        state.set("helper", remote.helper?.state.rawValue ?? "unknown")
        state.set("checkedAt", remote.helper?.checkedAt)
        state.set("autoInstall", remote.autoInstall)
        if let link = remote.link { state.set("link", Self.link(link)) }
        return state.json
    }

    static func link(_ link: RemoteLinkV2) -> JSONValue {
        switch link {
        case .connecting: .object(["state": .string("connecting")])
        case .connected: .object(["state": .string("connected")])
        case .offline: .object(["state": .string("offline")])
        case .needsInput(let reason): .object(["state": .string("needsInput"), "reason": .string(reason.rawValue)])
        case .disconnected(let reason): .object(["state": .string("disconnected"), "reason": .string(reason.rawValue)])
        case .reconnecting(let attempt, let at):
            .object(["state": .string("reconnecting"), "attempt": .number(Double(attempt)), "nextAttemptAt": .string(ConventionsV2.timestamp(at))])
        }
    }
}
