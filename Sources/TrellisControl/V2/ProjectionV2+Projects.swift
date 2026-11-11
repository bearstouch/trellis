import Foundation
import TrellisCore

/// A task in a pane's project (resources.md#task), as the app's Tasks view lists it: from `.trellis/launch.json` or
/// detected from a manifest. Built by the adapter from the same catalog the view reads.
public struct TaskEntryV2: Sendable, Equatable {
    public var id: String
    public var task: LaunchTask
    public var source: TaskSource
    /// A launch.json task whose file version the user trusted in the app; detected tasks come from fixed templates.
    public var trusted: Bool
    /// The variables the task runs with (names only are ever returned).
    public var environment: [String]
    public init(id: String, task: LaunchTask, source: TaskSource, trusted: Bool, environment: [String] = []) {
        self.id = id; self.task = task; self.source = source; self.trusted = trusted; self.environment = environment
    }
}

/// Projects, launch plans and tasks (resources.md#project, #task, #task-run). What a definition runs and where (commands,
/// repositories, folders, task commands) needs session.execute; agent IDs and names don't.
extension ProjectionV2 {
    // MARK: Project

    /// `spaces` are the open spaces bound to the project; only those in scope are listed.
    public func project(_ project: ProjectDefinition) -> JSONValue {
        var object = ResultObjectV2()
        object.set("id", project.id)
        object.set("name", project.name)
        object.set("revision", project.revision)
        object.set("notes", project.notes)
        if executes, let repository = project.repository { object.set("repository", self.repository(repository)) }
        object.set(
            "tabs",
            JSONValue.array(
                project.tabs.enumerated().map { index, tab in
                    var entry = ResultObjectV2()
                    entry.set("key", "t\(index + 1)")
                    entry.set("title", tab.title)
                    entry.set("color", tab.color?.rawValue)
                    if executes {
                        entry.set("directory", tab.directory)
                        if let repository = tab.repository { entry.set("repository", self.repository(repository)) }
                    }
                    entry.set("layout", node(tab.root, tab: index, path: []))
                    return entry.json
                }))
        if executes {
            let keys = project.lastFolders.keys.sorted { a, b in a == "local" || (b != "local" && a < b) }
            object.set(
                "lastFolders",
                JSONValue.array(
                    keys.compactMap { key in
                        guard let target = ProjectTarget(key: key), let folder = project.lastFolders[key] else { return nil }
                        return .object(["target": projectTarget(target), "folder": .string(folder)])
                    }))
        }
        object.set("spaces", visibleSpaces().filter { $0.projectID == project.id }.map(\.id))
        return object.json
    }

    /// `t1-12`: the layout key a launch gives the pane (ProjectLaunch.resolve), so plans and spaces name the same panes.
    static func paneKey(tab: Int, path: [Int]) -> String { "t\(tab + 1)-" + (path.isEmpty ? "0" : path.map { String($0 + 1) }.joined()) }

    private func node(_ node: ProjectNode, tab: Int, path: [Int]) -> JSONValue {
        switch node {
        case .pane(let pane):
            var object = ResultObjectV2()
            object.set("type", "pane")
            object.set("key", Self.paneKey(tab: tab, path: path))
            object.set("title", pane.title)
            object.set("agent", pane.agent)
            if executes {
                object.set("directory", pane.directory)
                object.set("command", pane.command)
                if let repository = pane.repository { object.set("repository", self.repository(repository)) }
            }
            return object.json
        case .split(let axis, let ratio, let first, let second):
            return .object([
                "type": .string("split"), "axis": .string(axis.rawValue), "ratio": .number(ratio),
                "children": .array([self.node(first, tab: tab, path: path + [0]), self.node(second, tab: tab, path: path + [1])])
            ])
        }
    }

    private func repository(_ repository: ProjectRepository) -> JSONValue {
        var object = ResultObjectV2()
        object.set("url", repository.url)
        object.set("branch", repository.branch)
        return object.json
    }

    /// `{"kind": "local"}` or `{"kind": "host", "hostId"}`; the host's ID needs host.read and the host in scope.
    public func projectTarget(_ target: ProjectTarget) -> JSONValue {
        switch target {
        case .local: return .object(["kind": .string("local")])
        case .host(let id):
            var object = ResultObjectV2()
            object.set("kind", "host")
            if showsHost(id) { object.set("hostId", id) }
            return object.json
        }
    }

    // MARK: Launch plan

    /// What launching would do (FR-PL06): the folder and whether it exists, each checkout's state, the panes that run a
    /// command or an agent, and the project revision it was made from (project.launch's expectedRevision).
    public func plan(_ launch: ProjectLaunch) -> JSONValue {
        var object = ResultObjectV2()
        object.set("revision", launch.project.revision)
        object.set("target", projectTarget(launch.target))
        if executes { object.set("folder", launch.folder) }
        object.set("folderExists", launch.rootExists)
        object.set("needsSetup", launch.needsSetup)
        object.set(
            "checkouts",
            JSONValue.array(
                launch.checkouts.map { checkout in
                    var entry = ResultObjectV2()
                    entry.set("state", Self.state(checkout.state))
                    if executes {
                        entry.set("folder", checkout.folder.isEmpty ? "." : checkout.folder)
                        entry.set("repository", repository(checkout.repository))
                    }
                    return entry.json
                }))
        object.set(
            "commands",
            JSONValue.array(
                launch.commands.keys.sorted().map { key in
                    var entry = ResultObjectV2()
                    entry.set("paneKey", key)
                    if executes { entry.set("command", launch.commands[key]) }
                    return entry.json
                }))
        object.set(
            "agents", JSONValue.array(launch.agents.keys.sorted().map { .object(["paneKey": .string($0), "agentId": .string(launch.agents[$0] ?? "")]) }))
        return object.json
    }

    static func state(_ state: ProjectLaunch.Checkout.State) -> String {
        switch state {
        case .clone: "clone"
        case .present: "present"
        case .blocked: "blocked"
        }
    }

    // MARK: Tasks

    public func task(_ entry: TaskEntryV2) -> JSONValue {
        var object = ResultObjectV2()
        object.set("id", entry.id)
        object.set("name", entry.task.name)
        object.set("source", entry.source.rawValue)
        object.set("group", entry.task.group?.rawValue)
        object.set("trusted", entry.trusted)
        if executes {
            object.set("command", entry.task.command)
            object.set("cwd", entry.task.cwd)
            if !entry.environment.isEmpty { object.set("env", JSONValue.array(entry.environment.map(JSONValue.string))) }
        }
        return object.json
    }

    /// A run as the Tasks button follows it (FR-TK07). Runtime only: it lives in its pane until the pane runs something else.
    public func taskRun(_ run: TaskRun, paneID: UUID) -> JSONValue {
        var object = ResultObjectV2()
        object.set("paneId", paneID)
        object.set("taskId", run.taskID)
        object.set("name", run.name)
        object.set("phase", Self.phase(run))
        switch run.phase {
        case .submitted(let at): object.set("submittedAt", at)
        case .running(let since): object.set("startedAt", since)
        case .finished(let code, let duration):
            object.set("exitCode", code)
            object.set("durationMs", Int64((duration * 1_000).rounded()))
        }
        object.set("stopRequested", run.stopRequestedAt != nil)
        return object.json
    }

    public static func phase(_ run: TaskRun) -> String {
        switch run.phase {
        case .submitted: "submitted"
        case .running: "running"
        case .finished: "finished"
        }
    }
}
