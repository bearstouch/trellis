import Foundation
import TrellisControl

/// One documented CLI command: `trellis <noun> <verb>` and its flags.
struct CommandSpec: Sendable {
    let method: String
    /// Flags taking a value (repeatable when listed in `repeatable`).
    var options: Set<String> = []
    var switches: Set<String> = []
    var repeatable: Set<String> = []
    /// Number of positional arguments (layout file path).
    var positionals = 0
    var mutating: Bool { ControlMethods.isMutating(method) }
}

enum CLICommands {
    static let globalOptions: Set<String> = ["state-directory", "keychain-grant"]
    static let globalSwitches: Set<String> = ["json", "launch", "token-stdin"]

    private static func spec(_ method: String, _ options: Set<String> = [], switches: Set<String> = [], repeatable: Set<String> = [], positionals: Int = 0) -> CommandSpec {
        var options = options
        // A replayed subscribe would return another connection's subscription.
        if ControlMethods.isMutating(method), method != "events.subscribe" { options.formUnion(["idempotency-key"]) }
        return CommandSpec(method: method, options: options, switches: switches, repeatable: repeatable, positionals: positionals)
    }

    static let table: [String: [String: CommandSpec]] = [
        "system": ["info": spec("system.info")],
        "window": [
            "list": spec("window.list"),
            "get": spec("window.get", ["window"]),
            "create": spec("window.create", ["name"], switches: ["start"]),
            "rename": spec("window.update", ["window", "name", "expected-revision"]),
            "reorder": spec("window.reorder", ["ids", "expected-revision"]),
            "focus": spec("window.focus", ["window"], switches: ["activate"]),
            "close": spec("window.close", ["window", "expected-revision"], switches: ["allow-running", "force"])
        ],
        "tab": [
            "list": spec("tab.list", ["window"]),
            "get": spec("tab.get", ["tab"]),
            "create": spec("tab.create", ["window", "title"], switches: ["start"]),
            "rename": spec("tab.update", ["tab", "title", "expected-revision"]),
            "reorder": spec("tab.reorder", ["window", "ids", "expected-revision"]),
            "focus": spec("tab.focus", ["tab"]),
            "close": spec("tab.close", ["tab", "expected-revision"], switches: ["allow-running", "force"])
        ],
        "pane": [
            "split": spec("pane.split", ["pane", "axis", "ratio"], switches: ["start"]),
            "resize": spec("pane.resize", ["branch", "ratio", "expected-revision"]),
            "focus": spec("pane.focus", ["pane"]),
            "maximize": spec("pane.maximize", ["pane"], switches: ["restore"]),
            "close": spec("pane.close", ["pane"], switches: ["allow-running", "force"])
        ],
        "session": [
            "get": spec("session.get", ["session"]),
            "start": spec("session.start", ["pane", "process", "arg", "directory", "host-launch"], switches: ["shell"], repeatable: ["arg"]),
            "restart": spec(
                "session.restart", ["pane", "process", "arg", "directory", "host-launch"], switches: ["shell", "allow-running", "force"], repeatable: ["arg"]),
            "input": spec("session.sendInput", ["session", "text", "base64", "mode"]),
            "execute": spec("session.execute", ["session", "command"], switches: ["submit"]),
            "output": spec("session.readOutput", ["session", "view", "cursor", "max-bytes"])
        ],
        "host": [
            "list": spec("host.list", ["query"]),
            "get": spec("host.get", ["host"]),
            "create": spec("host.create", ["name", "destination", "user", "port", "identity-file", "tags"]),
            "update": spec("host.update", ["host", "name", "destination", "user", "port", "identity-file", "tags", "expected-revision"]),
            "delete": spec("host.delete", ["host", "expected-revision"]),
            "connect": spec("host.connect", ["host", "window", "pane", "axis"])
        ],
        "layout": [
            "validate": spec("layout.validate", positionals: 1),
            "plan": spec("layout.plan", ["namespace"], positionals: 1),
            "apply": spec("layout.apply", ["namespace", "expected-revision"], switches: ["start-new"], positionals: 1),
            "export": spec("layout.export", ["window"], repeatable: ["window"])
        ],
        "events": ["subscribe": spec("events.subscribe", ["topics", "resource", "after-sequence", "instance"], repeatable: ["resource"])],
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
            "set": spec("appearance.set", ["mode", "light-theme", "dark-theme", "expected-revision"])
        ]
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

enum CLIArguments {
    static func parse(_ arguments: [String]) throws(ArgumentError) -> ParsedCommand {
        guard arguments.count >= 2 else { throw .usage("Usage: trellis <noun> <verb> [options]. Nouns: \(CLICommands.table.keys.sorted().joined(separator: ", ")).") }
        let noun = arguments[0], verb = arguments[1]
        guard let verbs = CLICommands.table[noun] else { throw .usage("Unknown command \(noun). Use one of: \(CLICommands.table.keys.sorted().joined(separator: ", ")).") }
        guard let spec = verbs[verb] else { throw .usage("Unknown \(noun) command \(verb). Use one of: \(verbs.keys.sorted().joined(separator: ", ")).") }
        var command = ParsedCommand(noun: noun, verb: verb, spec: spec.method)
        var index = 2
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
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
            } else {
                throw .usage("Unknown option --\(name) for \(noun) \(verb).")
            }
        }
        guard command.positionals.count == spec.positionals else {
            throw .usage(spec.positionals == 0 ? "\(noun) \(verb) takes no bare arguments; pass values after their --option." : "\(noun) \(verb) needs exactly one layout file path.")
        }
        if command.has("token-stdin"), command.value("keychain-grant") != nil { throw .usage("Use either --token-stdin or --keychain-grant, not both.") }
        return command
    }
}
