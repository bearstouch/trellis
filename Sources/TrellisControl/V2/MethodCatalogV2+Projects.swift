import Foundation
import TrellisCore

/// The catalog's projects and tasks (docs/api/methods.md#projects, #tasks): the project library, launching projects, and a
/// pane's tasks. Project definitions and task files are untrusted: what they run needs session.execute to write or read.
extension MethodCatalogV2 {
    private static let projectID = ParamV2("id", .uuid, required: true, "The project's ID.")
    private static let projectRule = ResourceRuleV2(.project, "id")
    private static let document = ParamV2(
        "document", .object, required: true, "The project in the library's JSON form (FR-PL03): name, notes, repository and tabs; at most 256 KiB.")

    /// Where a project runs: this Mac, or a saved host (as a remote workspace, FR-PL06).
    static let projectTarget = ParamV2(
        "target",
        .structure(
            ObjectSchemaV2(
                [
                    ParamV2("kind", .string(values: ["local", "host"]), "This Mac, or a saved host."),
                    ParamV2("hostId", .uuid, "The host; it must be in the grant's host scope at its current connection.")
                ], tag: "kind", variants: [.init("local"), .init("host", allowed: ["hostId"], required: ["hostId"])])), required: true,
        "Where the project runs.")
    private static let targetRule = ResourceRuleV2(.host, "target.hostId")
    private static let onHost = ConditionV2.equals("target.kind", .string("host"))
    private static let folder = ParamV2(
        "folder", .string(maxBytes: 4_096), "The project folder: absolute (or ~/…) on this Mac, relative to home on a host; default the last one used there, else ~/<name>.")
    private static let projectErrors: Set<APIErrorCode> = [.invalidState, .remoteDisconnected, .confirmationRequired]

    static let projects: [MethodSpecV2] = [
        MethodSpecV2(
            "project.list", "Library projects in scope, by name; query matches names, notes and repository URLs.",
            params: [ParamV2("query", .string(maxBytes: 200), "Every word must match a name, notes or a repository URL.")], capabilities: [.projectRead],
            errors: [.invalidState], paginated: true),
        MethodSpecV2("project.get", "One library project.", params: [projectID], capabilities: [.projectRead], resources: [projectRule], errors: [.invalidState]),
        MethodSpecV2(
            "project.create", "Add a project to the library from its JSON form; it gets a new ID.", params: [document], capabilities: [.projectWrite, .sessionExecute],
            effect: .mutating(revision: .exempt(reason: "A new project conflicts with none; the library's own revision moves with every launch record.")),
            errors: [.invalidState]),
        MethodSpecV2(
            "project.update", "Replace a project's definition with a JSON document; changing commands, agents, repositories or folders needs session.execute.",
            params: [projectID, document], capabilities: [.projectWrite], resources: [projectRule], effect: .mutating(revision: .resource(param: "id")),
            errors: [.invalidState]),
        MethodSpecV2(
            "project.delete", "Delete a project from the library; spaces launched from it stay open.", params: [projectID], capabilities: [.projectWrite],
            resources: [projectRule], effect: .mutating(revision: .resource(param: "id"), destructive: true), errors: [.invalidState]),
        MethodSpecV2(
            "project.capture", "Make a library project from an open space, as New from Space… does; commands are never captured.",
            params: [ParamV2("spaceId", .uuid, required: true, "The space."), ParamV2("name", .string(maxBytes: 800), required: true, "The project's name, 1–200 characters.")],
            capabilities: [.projectWrite, .workspaceRead], resources: [ResourceRuleV2(.space, "spaceId")],
            effect: .mutating(revision: .exempt(reason: "A new project conflicts with none; the space is only read.")), errors: [.invalidState]),
        MethodSpecV2(
            "project.check", "What launching a project on a target would do there: the folder, checkouts to clone, commands and agents, and the revision to launch.",
            params: [projectID, projectTarget, folder], capabilities: [.projectRead], conditional: [ConditionalCapabilityV2(.remoteConnect, if: onHost)],
            resources: [projectRule, targetRule], errors: projectErrors, waitsIf: onHost),
        MethodSpecV2(
            "project.launch", "Launch a project as the app's launch sheet does: set up what's missing (with setup), open its space bound to the project and start it.",
            params: [projectID, projectTarget, folder, ParamV2("setup", .boolean, "Create the folder and clone what's missing first (needs session.execute).")],
            capabilities: [.projectLaunch, .sessionStart],
            conditional: [
                ConditionalCapabilityV2(.sessionExecute, if: .anyOf([.present("setup"), .present("folder")])), ConditionalCapabilityV2(.remoteConnect, if: onHost)
            ], resources: [projectRule, targetRule], createsSpace: true, effect: .mutating(revision: .resource(param: "id"), destructive: true),
            errors: projectErrors.union([.setupRequired, .launchFailed]), waitsIf: .anyOf([onHost, .present("setup")]))
    ]

    private static let paneID = ParamV2("paneId", .uuid, required: true, "The pane: its shell's folder decides the project.")
    private static let paneRule = ResourceRuleV2(.pane, "paneId")

    static let tasks: [MethodSpecV2] = [
        MethodSpecV2(
            "task.list", "The tasks of a pane's project: .trellis/launch.json and those detected from its manifests.", params: [paneID], capabilities: [.taskRead],
            resources: [paneRule], errors: [.invalidState], paginated: true),
        MethodSpecV2("task.get", "The pane's current or last task run.", params: [paneID], capabilities: [.taskRead], resources: [paneRule]),
        MethodSpecV2(
            "task.run", "Type a task into the pane's shell at its prompt, as the app's Run does; launch.json tasks must be trusted in the app first.",
            params: [paneID, ParamV2("taskId", .string(maxBytes: 200), required: true, "The task's ID, as task.list names it.")], capabilities: [.taskRun],
            resources: [paneRule], effect: .mutating(revision: .resource(param: "paneId"), destructive: true), errors: [.taskUntrusted, .invalidState, .remoteDisconnected]),
        MethodSpecV2(
            "task.stop", "Stop the pane's running task with Ctrl-C; force (2 s after the first stop) sends Ctrl-\\.",
            params: [paneID, ParamV2("force", .boolean, "After CLOSE_PENDING and 2 s, send Ctrl-\\ (SIGQUIT) instead.")], capabilities: [.taskRun],
            resources: [paneRule], effect: .mutating(revision: .resource(param: "paneId"), destructive: true), errors: [.invalidState, .closePending, .remoteDisconnected])
    ]
}
