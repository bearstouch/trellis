import Foundation
import TrellisCore

/// Phase 2 of the catalog (docs/api/v2/methods.md): the system, workspace, space, tab, pane, session and host methods.
extension MethodCatalogV2 {
    // MARK: Shared parameters

    private static func id(_ kind: String) -> ParamV2 { ParamV2("id", .uuid, required: true, "The \(kind)'s ID.") }
    private static let name = ParamV2("name", .string(maxBytes: 800), required: true, "1–200 characters.")
    private static let start = ParamV2("start", .boolean, "Start the new panes' sessions (needs session.start).")
    private static let allowRunning = ParamV2("allowRunning", .boolean, "Stop running sessions instead of answering CONFIRMATION_REQUIRED (needs session.close).")
    private static let force = ParamV2("force", .boolean, "After CLOSE_PENDING and 2 s, end sessions that ignored the graceful request (needs session.close).")
    private static let stopsSessions = ConditionalCapabilityV2(.sessionClose, if: .anyOf([.present("allowRunning"), .present("force")]))
    private static let closeErrors: Set<APIErrorCode> = [.confirmationRequired, .closePending, .invalidState]
    private static let colors = TabColor.allCases.map(\.rawValue)

    /// What a pane runs (resources.md#session). Agents start only through `agent.start`, so `agent` is not a kind here.
    static let launch = ParamV2(
        "launch",
        .structure(
            ObjectSchemaV2(
                [
                    ParamV2("kind", .string(values: ["shell", "process", "ssh"]), "What runs; agents start with agent.start, not here."),
                    ParamV2("directory", .string(maxBytes: 4_096), "Absolute starting directory (needs session.execute)."),
                    ParamV2("executable", .string(maxBytes: 4_096), "Absolute path of the program."),
                    ParamV2("arguments", .stringList(maxCount: 256), "Program arguments."),
                    ParamV2("environment", .stringMap(maxCount: 256), "Extra environment variables (needs session.execute); TRELLIS_ names are reserved."),
                    ParamV2("hostId", .uuid, "Saved host to connect to with ssh; the host must be in the grant's scope.")
                ], tag: "kind",
                variants: [
                    .init("shell", allowed: ["directory", "environment"]),
                    .init("process", allowed: ["executable", "arguments", "directory", "environment"], required: ["executable", "directory"]),
                    .init("ssh", allowed: ["hostId"], required: ["hostId"])
                ])), "What to run instead of the pane's saved launch.")
    private static let launchRule = ResourceRuleV2(.host, "launch.hostId")
    /// A launch decides what runs unless it is a saved host, which host scope governs (permissions.md).
    private static let choosesWhatRuns = ConditionalCapabilityV2(
        .sessionExecute, if: .anyOf([.equals("launch.kind", .string("process")), .present("launch.directory"), .present("launch.environment")]))

    static let placement = ParamV2(
        "placement",
        .structure(
            ObjectSchemaV2(
                [
                    ParamV2("kind", .string(values: ["tab", "split", "space"]), "Where the connection opens."),
                    ParamV2("spaceId", .uuid, "The space that gets a new tab."),
                    ParamV2("paneId", .uuid, "The pane to split."),
                    ParamV2("axis", .string(values: ["x", "y"]), "x splits left/right (default), y top/bottom."),
                    ParamV2("name", .string(maxBytes: 800), "The new space's name; default the host's name.")
                ], tag: "kind",
                variants: [
                    .init("tab", allowed: ["spaceId"], required: ["spaceId"]), .init("split", allowed: ["paneId", "axis"], required: ["paneId"]),
                    .init("space", allowed: ["name"])
                ])), required: true, "Where the new pane goes.")

    // MARK: System and workspace

    static let system: [MethodSpecV2] = [
        MethodSpecV2("system.info", "Trellis version, protocol version, app instance ID and protocol limits."),
        MethodSpecV2("grant.get", "This connection's own grant: capabilities, scopes and expiry, so a client can see what it may do.")
    ]

    static let workspace: [MethodSpecV2] = [
        MethodSpecV2(
            "workspace.get", "Everything in scope in one call: the workspace revision, the active space, spaces and the included collections.",
            params: [
                ParamV2(
                    "include", .stringList(values: ["tabs", "panes", "sessions", "agents", "layout"], maxCount: 5),
                    "Collections to add; agents adds agentRuns, layout adds each tab's split tree.")
            ],
            capabilities: [.workspaceRead]),
        MethodSpecV2(
            "workspace.save", "Save the workspace to disk now instead of waiting for the next automatic save.", capabilities: [.workspaceWrite],
            effect: .mutating(revision: .exempt(reason: "Saving writes the current state and changes no resource.")), errors: [.invalidState])
    ]

    // MARK: Spaces

    static let spaces: [MethodSpecV2] = [
        MethodSpecV2("space.list", "Spaces in scope, in sidebar order.", capabilities: [.workspaceRead], paginated: true),
        MethodSpecV2("space.get", "One space.", params: [id("space")], capabilities: [.workspaceRead], resources: [ResourceRuleV2(.space, "id")]),
        MethodSpecV2(
            "space.create", "Create a local space with one tab and one stopped pane, optionally starting it; with created scope it joins the grant's scope.", params: [name, start], capabilities: [.workspaceWrite],
            conditional: [ConditionalCapabilityV2(.sessionStart, if: .present("start"))], createsSpace: true, effect: .mutating(revision: .container("workspace")),
            errors: [.invalidState, .launchFailed]),
        MethodSpecV2(
            "space.update", "Rename a space.", params: [id("space"), name], capabilities: [.workspaceWrite], resources: [ResourceRuleV2(.space, "id")],
            effect: .mutating(revision: .resource(param: "id")), errors: [.invalidState]),
        MethodSpecV2(
            "space.reorder", "Reorder the sidebar; ids lists every space once.", params: [ParamV2("ids", .uuidList(), required: true, "Every space ID in the new order.")],
            capabilities: [.workspaceWrite], resources: [ResourceRuleV2(.space, "ids", list: true)], allSpaces: true,
            effect: .mutating(revision: .container("workspace")), errors: [.invalidState]),
        MethodSpecV2(
            "space.focus", "Make a space the active one.", params: [id("space")], capabilities: [.workspaceWrite], resources: [ResourceRuleV2(.space, "id")],
            effect: .mutating(revision: .resource(param: "id")), errors: [.invalidState]),
        MethodSpecV2(
            "space.close", "Close a space with its tabs and panes.", params: [id("space"), allowRunning, force], capabilities: [.workspaceWrite],
            conditional: [stopsSessions], resources: [ResourceRuleV2(.space, "id")], effect: .mutating(revision: .resource(param: "id"), destructive: true),
            errors: closeErrors)
    ]

    // MARK: Tabs

    static let tabs: [MethodSpecV2] = [
        MethodSpecV2(
            "tab.list", "A space's tabs in order.",
            params: [ParamV2("spaceId", .uuid, required: true, "The space."), ParamV2("include", .stringList(values: ["layout"], maxCount: 1), "layout adds each tab's split tree.")],
            capabilities: [.workspaceRead], resources: [ResourceRuleV2(.space, "spaceId")], paginated: true),
        MethodSpecV2("tab.get", "One tab with its layout.", params: [id("tab")], capabilities: [.workspaceRead], resources: [ResourceRuleV2(.tab, "id")]),
        MethodSpecV2(
            "tab.create", "Add a tab with one stopped pane to a space; in a project space it is a temporary tab.",
            params: [
                ParamV2("spaceId", .uuid, required: true, "The space."), ParamV2("title", .string(maxBytes: 800), "1–200 characters; default automatic."),
                ParamV2("color", .string(values: colors), "Color label."), start
            ], capabilities: [.workspaceWrite], conditional: [ConditionalCapabilityV2(.sessionStart, if: .present("start"))],
            resources: [ResourceRuleV2(.space, "spaceId")], effect: .mutating(revision: .container("space", param: "spaceId")), errors: [.invalidState, .launchFailed]),
        MethodSpecV2(
            "tab.update", "Rename a tab or set its color; a null title returns to the automatic title, a null color clears it.",
            params: [
                id("tab"), ParamV2("title", .string(maxBytes: 800), nullable: true, "1–200 characters, or null for the automatic title."),
                ParamV2("color", .string(values: colors), nullable: true, "Color label, or null to clear it.")
            ], capabilities: [.workspaceWrite], rules: [.atLeastOne(["title", "color"])], resources: [ResourceRuleV2(.tab, "id")],
            effect: .mutating(revision: .resource(param: "id")), errors: [.invalidState]),
        MethodSpecV2(
            "tab.duplicate", "Copy a tab's layout and pane launches into a new tab after it, optionally starting it.", params: [id("tab"), start],
            capabilities: [.workspaceWrite], conditional: [ConditionalCapabilityV2(.sessionStart, if: .present("start"))], resources: [ResourceRuleV2(.tab, "id")],
            effect: .mutating(revision: .resource(param: "id")), errors: [.invalidState, .launchFailed]),
        MethodSpecV2(
            "tab.reorder", "Reorder a space's tabs; ids lists each of its tabs once.",
            params: [ParamV2("spaceId", .uuid, required: true, "The space."), ParamV2("ids", .uuidList(), required: true, "Every tab ID of the space in the new order.")],
            capabilities: [.workspaceWrite], resources: [ResourceRuleV2(.space, "spaceId"), ResourceRuleV2(.tab, "ids", list: true)],
            effect: .mutating(revision: .container("space", param: "spaceId")), errors: [.invalidState]),
        MethodSpecV2(
            "tab.focus", "Make a tab its space's active tab.", params: [id("tab")], capabilities: [.workspaceWrite], resources: [ResourceRuleV2(.tab, "id")],
            effect: .mutating(revision: .resource(param: "id")), errors: [.invalidState]),
        MethodSpecV2(
            "tab.close", "Close a tab with its panes.", params: [id("tab"), allowRunning, force], capabilities: [.workspaceWrite], conditional: [stopsSessions],
            resources: [ResourceRuleV2(.tab, "id")], effect: .mutating(revision: .resource(param: "id"), destructive: true), errors: closeErrors)
    ]

    // MARK: Panes

    static let panes: [MethodSpecV2] = [
        MethodSpecV2(
            "pane.list", "The panes of one tab or of every tab in a space.",
            params: [ParamV2("tabId", .uuid, "A tab."), ParamV2("spaceId", .uuid, "A space.")], capabilities: [.workspaceRead], rules: [.exactlyOne(["tabId", "spaceId"])],
            resources: [ResourceRuleV2(.tab, "tabId"), ResourceRuleV2(.space, "spaceId")], paginated: true),
        MethodSpecV2("pane.get", "One pane with its machine, shell and attention state.", params: [id("pane")], capabilities: [.workspaceRead], resources: [ResourceRuleV2(.pane, "id")]),
        MethodSpecV2(
            "pane.split", "Split a pane; the new pane inherits its machine and folder, as in the app.",
            params: [
                id("pane"), ParamV2("axis", .string(values: ["x", "y"]), required: true, "x splits left/right, y top/bottom."),
                ParamV2("ratio", .number(minimum: 0.1, maximum: 0.9), "The existing pane's share, 0.1–0.9; default 0.5."), start
            ], capabilities: [.workspaceWrite], conditional: [ConditionalCapabilityV2(.sessionStart, if: .present("start"))], resources: [ResourceRuleV2(.pane, "id")],
            effect: .mutating(revision: .resource(param: "id")), errors: [.invalidState, .launchFailed]),
        MethodSpecV2(
            "pane.resize", "Move a split's divider; expectedRevision is the tab's.",
            params: [ParamV2("branchId", .uuid, required: true, "The split (a layout branch ID)."), ParamV2("ratio", .number(minimum: 0.1, maximum: 0.9), required: true, "The first child's share.")],
            capabilities: [.workspaceWrite], resources: [ResourceRuleV2(.branch, "branchId")], effect: .mutating(revision: .resource(param: "branchId")),
            errors: [.invalidState]),
        MethodSpecV2(
            "pane.focus", "Make a pane its tab's focused pane.", params: [id("pane")], capabilities: [.workspaceWrite], resources: [ResourceRuleV2(.pane, "id")],
            effect: .mutating(revision: .resource(param: "id")), errors: [.invalidState]),
        MethodSpecV2(
            "pane.maximize", "Maximize a pane in its tab (it also becomes focused), or restore the tab.",
            params: [id("pane"), ParamV2("maximized", .boolean, required: true, "true maximizes, false restores.")], capabilities: [.workspaceWrite],
            resources: [ResourceRuleV2(.pane, "id")], effect: .mutating(revision: .resource(param: "id")), errors: [.invalidState]),
        MethodSpecV2(
            "pane.close", "Close a pane; closing a tab's last pane closes the tab.", params: [id("pane"), allowRunning, force], capabilities: [.workspaceWrite],
            conditional: [stopsSessions], resources: [ResourceRuleV2(.pane, "id")], effect: .mutating(revision: .resource(param: "id"), destructive: true),
            errors: closeErrors)
    ]

    // MARK: Sessions

    static let sessions: [MethodSpecV2] = [
        MethodSpecV2("session.get", "One session: state, launch, times and exit.", params: [id("session")], capabilities: [.workspaceRead], resources: [ResourceRuleV2(.session, "id")]),
        MethodSpecV2(
            "session.start", "Start a stopped pane with its saved launch or the one given.", params: [ParamV2("paneId", .uuid, required: true, "The pane."), launch],
            capabilities: [.sessionStart], conditional: [choosesWhatRuns], resources: [ResourceRuleV2(.pane, "paneId"), launchRule],
            effect: .mutating(revision: .resource(param: "paneId")), errors: [.invalidState, .launchFailed, .remoteDisconnected]),
        MethodSpecV2(
            "session.restart", "Replace a pane's session with a new one (a new session ID), stopping a running one first if allowed.",
            params: [ParamV2("paneId", .uuid, required: true, "The pane."), launch, allowRunning, force], capabilities: [.sessionStart],
            conditional: [choosesWhatRuns, stopsSessions], resources: [ResourceRuleV2(.pane, "paneId"), launchRule],
            effect: .mutating(revision: .resource(param: "paneId")), errors: closeErrors.union([.launchFailed, .remoteDisconnected])),
        MethodSpecV2(
            "session.stop", "Stop a running session gracefully; force after CLOSE_PENDING ends it.", params: [id("session"), force], capabilities: [.sessionClose],
            resources: [ResourceRuleV2(.session, "id")], effect: .mutating(revision: .resource(param: "id"), destructive: true), errors: [.invalidState, .closePending]),
        MethodSpecV2(
            "session.sendInput", "Send bytes to a running session, literally or as a bracketed paste.",
            params: [
                id("session"), ParamV2("text", .string(), "UTF-8 text."), ParamV2("base64", .string(), "Bytes, base64-encoded."),
                ParamV2("mode", .string(values: ["literal", "paste"]), "literal (default) or paste.")
            ], capabilities: [.sessionInput], rules: [.exactlyOne(["text", "base64"])], resources: [ResourceRuleV2(.session, "id")],
            effect: .mutating(revision: .resource(param: "id")), errors: [.invalidState, .remoteDisconnected]),
        MethodSpecV2(
            "session.execute", "Type one command line plus Return into a running session.",
            params: [id("session"), ParamV2("command", .string(), required: true, "One line, no CR or LF.")], capabilities: [.sessionExecute],
            resources: [ResourceRuleV2(.session, "id")], effect: .mutating(revision: .resource(param: "id")), errors: [.invalidState, .remoteDisconnected]),
        MethodSpecV2(
            "session.readOutput", "Read a session's screen, its scrollback or its raw output stream from a cursor.",
            params: [
                id("session"), ParamV2("view", .string(values: ["screen", "scrollback", "stream"]), required: true, "What to read."),
                ParamV2("cursor", .string(maxBytes: 1_024), "stream only: nextCursor from the previous read."),
                ParamV2("maxBytes", .integer(minimum: 1, maximum: 262_144), "At most this many bytes; default 65536.")
            ], capabilities: [.sessionOutputRead], resources: [ResourceRuleV2(.session, "id")], errors: [.invalidCursor])
    ]

    // MARK: Hosts

    private static let hostFields = [
        ParamV2("user", .string(maxBytes: 256), nullable: true, "SSH user; null clears it."), ParamV2("port", .integer(minimum: 1, maximum: 65_535), nullable: true, "Port; null clears it."),
        ParamV2("identityFile", .string(maxBytes: 4_096), nullable: true, "Identity file path; null clears it."),
        ParamV2("tags", .stringList(maxCount: 64), nullable: true, "Tags; null clears them.")
    ]

    static let hosts: [MethodSpecV2] = [
        MethodSpecV2(
            "host.list", "Saved hosts in scope, filtered by text and tags.",
            params: [
                ParamV2("query", .string(maxBytes: 200), "Every word must match a name, destination, user or tag."),
                ParamV2("tags", .stringList(maxCount: 64), "Only hosts with every one of these tags.")
            ], capabilities: [.hostRead], paginated: true),
        MethodSpecV2("host.get", "One saved host.", params: [id("host")], capabilities: [.hostRead], resources: [ResourceRuleV2(.host, "id")]),
        MethodSpecV2(
            "host.create", "Save a new SSH host.",
            params: [ParamV2("name", .string(maxBytes: 800), required: true, "Display name."), ParamV2("destination", .string(maxBytes: 1_024), required: true, "SSH config alias, hostname or address.")]
                + hostFields.map { ParamV2($0.name, $0.type, $0.summary.replacingOccurrences(of: "; null clears it.", with: ".").replacingOccurrences(of: "; null clears them.", with: ".")) },
            capabilities: [.hostWrite, .sessionExecute], effect: .mutating(revision: .exempt(reason: "The host library has no collection revision; a new host conflicts with none.")),
            errors: [.invalidState]),
        MethodSpecV2(
            "host.update", "Change a saved host's fields; changing where it connects needs session.execute and invalidates host approvals.",
            params: [id("host"), ParamV2("name", .string(maxBytes: 800), "Display name."), ParamV2("destination", .string(maxBytes: 1_024), "SSH config alias, hostname or address.")]
                + hostFields,
            capabilities: [.hostWrite],
            conditional: [
                ConditionalCapabilityV2(.sessionExecute, if: .anyOf([.provided("destination"), .provided("user"), .provided("port"), .provided("identityFile")]))
            ], rules: [.atLeastOne(["name", "destination", "user", "port", "identityFile", "tags"])], resources: [ResourceRuleV2(.host, "id")],
            effect: .mutating(revision: .resource(param: "id")), errors: [.invalidState]),
        MethodSpecV2(
            "host.delete", "Delete a saved host; panes connected to it keep running.", params: [id("host")], capabilities: [.hostWrite],
            resources: [ResourceRuleV2(.host, "id")], effect: .mutating(revision: .resource(param: "id"), destructive: true), errors: [.invalidState]),
        MethodSpecV2(
            "host.connect", "Open an ssh session to a saved host in a new tab, a split or a new space; expectedRevision is the host's.",
            params: [ParamV2("hostId", .uuid, required: true, "The saved host."), placement], capabilities: [.sessionStart, .workspaceWrite],
            resources: [ResourceRuleV2(.host, "hostId"), ResourceRuleV2(.space, "placement.spaceId"), ResourceRuleV2(.pane, "placement.paneId")],
            createsSpaceIf: .equals("placement.kind", .string("space")), effect: .mutating(revision: .resource(param: "hostId")), errors: [.invalidState, .launchFailed])
    ]
}
