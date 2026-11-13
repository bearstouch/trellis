import Foundation
import TrellisControl

/// One documented CLI command: `trellis <noun> <verb>` and its flags.
struct CommandSpec: Sendable {
    let method: String
    /// Flags taking a value (repeatable when listed in `repeatable`).
    var options: Set<String> = []
    var switches: Set<String> = []
    var repeatable: Set<String> = []
    /// Flags the command can't run without; checked while parsing, so nothing is resolved or sent first.
    var required: Set<String> = []
    /// Number of positional arguments (a document's path).
    var positionals = 0
    /// The catalog declaration behind the command; nil for the local `cli` commands.
    var declaration: MethodSpecV2? { MethodCatalogV2.spec(method) }
}

enum CLICommands {
    static let globalOptions: Set<String> = ["state-directory", "keychain-grant"]
    static let globalSwitches: Set<String> = ["json", "launch", "token-stdin"]
    /// Verbs of more than one word (`trellis remote helper install`), by noun and first word.
    static let groups: [String: Set<String>] = ["remote": ["helper"]]

    /// The convention flags come from the declaration, so they can't drift from it: `--idempotency-key` and
    /// `--expected-revision` where the method takes them, `--limit` and `--cursor` on paginated lists.
    private static func spec(
        _ method: String, _ options: Set<String> = [], switches: Set<String> = [], repeatable: Set<String> = [], required: Set<String> = [], positionals: Int = 0
    ) -> CommandSpec {
        var options = options
        if let declared = MethodCatalogV2.spec(method) {
            let names = Set(declared.params.map(\.name))
            if names.contains("idempotencyKey") { options.insert("idempotency-key") }
            if names.contains("expectedRevision") { options.insert("expected-revision") }
            if declared.paginated { options.formUnion(["limit", "cursor"]) }
        }
        return CommandSpec(method: method, options: options, switches: switches, repeatable: repeatable, required: required, positionals: positionals)
    }

    private static let launch: Set<String> = ["process", "arg", "directory", "ssh", "env"]
    private static let agentPlacement: Set<String> = ["space", "split", "axis", "pane"]

    static let table: [String: [String: CommandSpec]] = [
        "system": ["info": spec("system.info")],
        "grant": ["get": spec("grant.get")],
        "workspace": ["get": spec("workspace.get", ["include"]), "save": spec("workspace.save")],
        "space": [
            "list": spec("space.list", ["name"]),
            "get": spec("space.get", ["space"], required: ["space"]),
            "create": spec("space.create", ["name"], switches: ["start"], required: ["name"]),
            "rename": spec("space.update", ["space", "name"], required: ["space", "name"]),
            "reorder": spec("space.reorder", ["ids"], required: ["ids"]),
            "focus": spec("space.focus", ["space"], required: ["space"]),
            "close": spec("space.close", ["space"], switches: ["allow-running", "force"], required: ["space"])
        ],
        "tab": [
            "list": spec("tab.list", ["space", "title"], switches: ["layout"], required: ["space"]),
            "get": spec("tab.get", ["tab", "space"], required: ["tab"]),
            "create": spec("tab.create", ["space", "title", "color"], switches: ["start"], required: ["space"]),
            "rename": spec("tab.update", ["tab", "space", "title"], switches: ["automatic-title"], required: ["tab"]),
            "color": spec("tab.update", ["tab", "space", "color"], required: ["tab", "color"]),
            "duplicate": spec("tab.duplicate", ["tab", "space"], switches: ["start"], required: ["tab"]),
            "reorder": spec("tab.reorder", ["space", "ids"], required: ["space", "ids"]),
            "focus": spec("tab.focus", ["tab", "space"], required: ["tab"]),
            "close": spec("tab.close", ["tab", "space"], switches: ["allow-running", "force"], required: ["tab"])
        ],
        "pane": [
            "list": spec("pane.list", ["tab", "space"]),
            "get": spec("pane.get", ["pane"], required: ["pane"]),
            "split": spec("pane.split", ["pane", "axis", "ratio"], switches: ["start"], required: ["pane", "axis"]),
            "resize": spec("pane.resize", ["branch", "ratio"], required: ["branch", "ratio"]),
            "focus": spec("pane.focus", ["pane"], required: ["pane"]),
            "maximize": spec("pane.maximize", ["pane"], switches: ["restore"], required: ["pane"]),
            "close": spec("pane.close", ["pane"], switches: ["allow-running", "force"], required: ["pane"])
        ],
        "session": [
            "get": spec("session.get", ["session"], required: ["session"]),
            "start": spec("session.start", launch.union(["pane"]), switches: ["shell"], repeatable: ["arg", "env"], required: ["pane"]),
            "restart": spec("session.restart", launch.union(["pane"]), switches: ["shell", "allow-running", "force"], repeatable: ["arg", "env"], required: ["pane"]),
            "stop": spec("session.stop", ["session"], switches: ["force"], required: ["session"]),
            "input": spec("session.sendInput", ["session", "text", "base64", "mode"], required: ["session"]),
            "execute": spec("session.execute", ["session", "command", "timeout-ms"], switches: ["wait"], required: ["session", "command"]),
            "output": spec("session.readOutput", ["session", "view", "cursor", "max-bytes"], required: ["session", "view"])
        ],
        "host": [
            "list": spec("host.list", ["query", "tags"]),
            "get": spec("host.get", ["host"], required: ["host"]),
            "create": spec("host.create", ["name", "destination", "user", "port", "identity-file", "tags"], required: ["name", "destination"]),
            "update": spec("host.update", ["host", "name", "destination", "user", "port", "identity-file", "tags"], required: ["host"]),
            "delete": spec("host.delete", ["host"], required: ["host"]),
            "connect": spec("host.connect", ["host", "space", "split", "axis", "name"], switches: ["new-space"], required: ["host"])
        ],
        "agent": [
            "list": spec("agent.list", ["machine"]),
            "get": spec("agent.get", ["agent"], required: ["agent"]),
            "runs": spec("agent.runs", ["space", "state"]),
            "start": spec("agent.start", agentPlacement.union(["agent", "directory"]), switches: ["resume"], required: ["agent"]),
            "restart": spec("agent.restart", ["session"], switches: ["resume"], required: ["session"]),
            "respond": spec("agent.respond", ["session", "action", "text", "expected-state"], required: ["session", "action"]),
            "install": spec("agent.install", agentPlacement.union(["agent"]), required: ["agent"])
        ],
        "remote": [
            "open": spec("remote.open", ["host", "name"], switches: ["start"], required: ["host"]),
            "status": spec("remote.status", ["host"], required: ["host"]),
            "reconnect": spec("remote.reconnect", ["host"], switches: ["interactive"], required: ["host"]),
            "helper install": spec("remote.helper.install", ["host"], required: ["host"]),
            "helper remove": spec("remote.helper.remove", ["host"], switches: ["stop-sessions"], required: ["host"])
        ],
        "project": [
            "list": spec("project.list", ["query"]),
            "get": spec("project.get", ["project"], required: ["project"]),
            "create": spec("project.create", positionals: 1),
            "update": spec("project.update", ["project"], required: ["project"], positionals: 1),
            "delete": spec("project.delete", ["project"], required: ["project"]),
            "capture": spec("project.capture", ["space", "name"], required: ["space", "name"]),
            "check": spec("project.check", ["project", "target", "folder"], required: ["project", "target"]),
            "launch": spec("project.launch", ["project", "target", "folder"], switches: ["setup"], required: ["project", "target"])
        ],
        "task": [
            "list": spec("task.list", ["pane"], required: ["pane"]),
            "get": spec("task.get", ["pane"], required: ["pane"]),
            "run": spec("task.run", ["pane", "task"], required: ["pane", "task"]),
            "stop": spec("task.stop", ["pane"], switches: ["force"], required: ["pane"])
        ],
        "layout": [
            "validate": spec("layout.validate", positionals: 1),
            "plan": spec("layout.plan", ["namespace"], required: ["namespace"], positionals: 1),
            "apply": spec("layout.apply", ["namespace"], switches: ["start-new"], required: ["namespace", "expected-revision"], positionals: 1),
            "export": spec("layout.export", ["space"], repeatable: ["space"])
        ],
        "events": [
            "subscribe": spec("events.subscribe", ["topics", "resource", "space", "after-sequence", "instance"], repeatable: ["resource", "space"]),
            "poll": spec("events.poll", ["topics", "space", "after-sequence", "instance", "timeout-ms", "limit"], repeatable: ["space"])
        ],
        "theme": [
            "list": spec("theme.list"),
            "get": spec("theme.get", ["id", "theme"]),
            "validate": spec("theme.validate", positionals: 1),
            "import": spec("theme.import", switches: ["replace"], positionals: 1),
            "export": spec("theme.export", ["id", "theme"], switches: ["resolved"]),
            "delete": spec("theme.delete", ["id", "theme"])
        ],
        // Local setup commands: no app connection or credentials.
        "cli": [
            "install-link": CommandSpec(method: "local.installLink", options: ["dir"]),
            "remove-link": CommandSpec(method: "local.removeLink", options: ["dir"]),
            "uninstall-plan": CommandSpec(method: "local.uninstallPlan", options: ["dir"])
        ],
        "appearance": [
            "get": spec("appearance.get"),
            "set": spec("appearance.set", ["mode", "light-theme", "dark-theme"])
        ]
    ]

    /// Catalog methods no CLI command calls, with why.
    static let uncovered: [String: String] = ["events.unsubscribe": "a subscription ends with the CLI's connection"]

    /// Commands and flags from protocol 1, refused with what replaced them rather than as unknown words.
    static let removedNouns: [String: String] = ["window": "The window noun was removed; use space."]
    static let removedOptions: [String: String] = [
        "window": "--window was removed; use --space.", "host-launch": "--host-launch was renamed --ssh.",
        "submit": "--submit was removed; session execute always submits the line.", "activate": "--activate was removed; it never had an effect."
    ]
}

/// A parsed invocation. Parsing performs no I/O and no mutation.
struct ParsedCommand: Equatable, Sendable {
    let noun: String
    let verb: String
    let spec: String
    var options: [String: [String]] = [:]
    var switches: Set<String> = []
    var positionals: [String] = []

    func value(_ name: String) -> String? { options[name]?.last }
    func has(_ name: String) -> Bool { switches.contains(name) }
}

enum ArgumentError: Error, Equatable {
    case usage(String)
}

/// What one invocation asks for. Help and version never need the app or credentials.
enum CLIRequest: Equatable, Sendable {
    case help(noun: String?, verb: String?)
    case version
    case run(ParsedCommand)
}

enum CLIArguments {
    private static let helpFlags: Set<String> = ["--help", "-h"]

    static func request(_ arguments: [String]) throws(ArgumentError) -> CLIRequest {
        // --json can sit anywhere; it only changes how the answer is printed.
        let words = arguments.filter { $0 != "--json" }
        if let first = words.first {
            if helpFlags.contains(first) { return .help(noun: nil, verb: nil) }
            if first == "--version" || first == "-V" { return .version }
            if first == "help" {
                let topic = Array(words.dropFirst().filter { !helpFlags.contains($0) })
                guard let noun = topic.first else { return .help(noun: nil, verb: nil) }
                let verbs = try verbs(of: noun)
                guard topic.count > 1 else { return .help(noun: noun, verb: nil) }
                let (verb, used) = verbWords(noun, Array(topic.dropFirst()))
                guard verbs[verb] != nil else { throw unknown(of: noun, verbs) }
                guard topic.count == 1 + used else { throw .usage("help takes at most a noun and a verb.") }
                return .help(noun: noun, verb: verb)
            }
            if words.count >= 2, helpFlags.contains(words[1]) {
                _ = try verbs(of: first)
                return .help(noun: first, verb: nil)
            }
        }
        let command = try parse(words.isEmpty ? [] : arguments)
        return command.has("help") ? .help(noun: command.noun, verb: command.verb) : .run(command)
    }

    /// `helper install` for `remote`; one word otherwise. Returns the verb and how many words it took.
    static func verbWords(_ noun: String, _ words: [String]) -> (String, Int) {
        guard let first = words.first else { return ("", 0) }
        if CLICommands.groups[noun]?.contains(first) == true, words.count > 1, !words[1].hasPrefix("-") { return (first + " " + words[1], 2) }
        return (first, 1)
    }

    // Unknown words aren't repeated in the message: a mistyped `--token=VALUE` can land here.
    private static func verbs(of noun: String) throws(ArgumentError) -> [String: CommandSpec] {
        if let removed = CLICommands.removedNouns[noun] { throw .usage(removed) }
        guard let verbs = CLICommands.table[noun] else { throw .usage("Unknown command. Use one of: \(CLICommands.table.keys.sorted().joined(separator: ", ")).") }
        return verbs
    }

    private static func unknown(of noun: String, _ verbs: [String: CommandSpec]) -> ArgumentError {
        .usage("Unknown \(noun) command. Use one of: \(verbs.keys.sorted().joined(separator: ", ")).")
    }

    static func parse(_ arguments: [String]) throws(ArgumentError) -> ParsedCommand {
        guard let noun = arguments.first else { throw .usage("Missing command.") }
        let verbs = try verbs(of: noun)
        guard arguments.count >= 2 else { throw .usage("\(noun) needs a verb. Use one of: \(verbs.keys.sorted().joined(separator: ", ")).") }
        let (verb, used) = verbWords(noun, Array(arguments.dropFirst()))
        guard let spec = verbs[verb] else { throw unknown(of: noun, verbs) }
        var command = ParsedCommand(noun: noun, verb: verb, spec: spec.method)
        var index = 1 + used
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            // Checked here rather than up front, so an option's value can be the literal text "--help".
            if helpFlags.contains(argument) {
                command.switches.insert("help")
                return command
            }
            guard argument.hasPrefix("--") else {
                command.positionals.append(argument)
                continue
            }
            let name = String(argument.dropFirst(2))
            // Secrets never travel in argv, where other processes can read them,
            // and argument values are never echoed back in diagnostics.
            let base = String(name.prefix { $0 != "=" })
            if ["token", "password", "secret"].contains(base) {
                throw .usage("Tokens are never accepted as arguments. Use --token-stdin or --keychain-grant GRANT_ID.")
            }
            guard base == name else { throw .usage("Write --\(base) VALUE; the --option=value form is not supported.") }
            if spec.switches.contains(name) || CLICommands.globalSwitches.contains(name) {
                command.switches.insert(name)
            } else if spec.options.contains(name) || CLICommands.globalOptions.contains(name) {
                guard index < arguments.count else { throw .usage("--\(name) needs a value.") }
                if command.options[name] != nil, !spec.repeatable.contains(name) { throw .usage("--\(name) may be given only once.") }
                command.options[name, default: []].append(arguments[index])
                index += 1
            } else if let removed = CLICommands.removedOptions[name] {
                throw .usage(removed)
            } else {
                throw .usage("Unknown option --\(name) for \(noun) \(verb).")
            }
        }
        guard command.positionals.count == spec.positionals else {
            throw .usage(spec.positionals == 0 ? "\(noun) \(verb) takes no bare arguments; pass values after their --option." : "\(noun) \(verb) needs exactly one FILE argument.")
        }
        if command.has("token-stdin"), command.value("keychain-grant") != nil { throw .usage("Use either --token-stdin or --keychain-grant, not both.") }
        if let missing = spec.required.sorted().first(where: { command.options[$0] == nil && !command.has($0) }) {
            throw .usage("\(noun) \(verb) needs --\(missing).")
        }
        return command
    }
}
