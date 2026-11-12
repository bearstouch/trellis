import TrellisCore

/// The text behind `--help`, `help` and `--version`. Plain, 80-column, ASCII, no color: it is meant for pipes and pagers.
/// What a command does, what it needs and its errors come from the method catalog; the synopses and flag texts are the
/// CLI's own. `CLIHelpTests` keeps these tables in step with `CLICommands.table`, so a new flag can't ship undocumented.
enum CLIHelp {
    struct Command {
        /// Only where the catalog's summary doesn't fit the command (local commands, two commands over one method).
        let summary: String?
        /// One synopsis per form, without the `trellis <noun> <verb>` prefix or the trailing `[options]`.
        let usage: [String]
        init(_ usage: String...) { summary = nil; self.usage = usage }
        init(summary: String, _ usage: String...) { self.summary = summary; self.usage = usage }
    }

    struct Option {
        let value: String?
        let text: String
        init(_ text: String) { self.value = nil; self.text = text }
        init(_ value: String, _ text: String) { self.value = value; self.text = text }
        func label(_ name: String) -> String { "--\(name)" + (value.map { " \($0)" } ?? "") }
    }

    static let nouns: [String: String] = [
        "agent": "Start, answer, restart and install coding agents",
        "appearance": "Show or set the appearance mode and themes",
        "cli": "Manage the command link (local; needs no app or credentials)",
        "events": "Follow workspace events, or wait for the next ones",
        "grant": "Show what this grant may do",
        "host": "Manage and connect to saved SSH hosts",
        "layout": "Validate, plan, apply and export layouts",
        "pane": "List, split, resize, focus, maximize and close panes",
        "project": "Manage library projects, check and launch them",
        "remote": "Open remote workspaces and manage the helper on hosts",
        "session": "Start and stop sessions, send input and read output",
        "space": "List, create, rename, reorder and close spaces",
        "system": "Show app and protocol information",
        "tab": "List, create, rename, color, duplicate and close tabs",
        "task": "List, run and stop a pane's tasks",
        "theme": "Manage the theme library",
        "workspace": "Read everything in scope at once, or save it now"
    ]

    private static let launchForms = [
        "--pane PANE [--shell [--directory DIR] [--env KEY=VALUE]...]", "--pane PANE --process PATH --directory DIR [--arg ARG]... [--env KEY=VALUE]...",
        "--pane PANE --ssh HOST"
    ]
    private static let agentPlacements = ["--space SPACE", "--split PANE [--axis x|y]", "--pane PANE"]

    static let commands: [String: [String: Command]] = [
        "system": ["info": Command("")],
        "grant": ["get": Command("")],
        "workspace": ["get": Command("[--include LIST]"), "save": Command("")],
        "space": [
            "list": Command("[--name NAME]"),
            "get": Command("--space SPACE"),
            "create": Command("--name NAME [--start]"),
            "rename": Command("--space SPACE --name NAME"),
            "reorder": Command("--ids IDS"),
            "focus": Command("--space SPACE"),
            "close": Command("--space SPACE [--allow-running] [--force]")
        ],
        "tab": [
            "list": Command("--space SPACE [--title TITLE] [--layout]"),
            "get": Command("--tab TAB [--space SPACE]"),
            "create": Command("--space SPACE [--title TITLE] [--color COLOR] [--start]"),
            "rename": Command(
                summary: "Rename a tab, or return it to its automatic title", "--tab TAB [--space SPACE] --title TITLE", "--tab TAB [--space SPACE] --automatic-title"),
            "color": Command(summary: "Set or remove a tab's color label", "--tab TAB [--space SPACE] --color COLOR"),
            "duplicate": Command("--tab TAB [--space SPACE] [--start]"),
            "reorder": Command("--space SPACE --ids IDS"),
            "focus": Command("--tab TAB [--space SPACE]"),
            "close": Command("--tab TAB [--space SPACE] [--allow-running] [--force]")
        ],
        "pane": [
            "list": Command("--tab TAB [--space SPACE]", "--space SPACE"),
            "get": Command("--pane PANE"),
            "split": Command("--pane PANE --axis x|y [--ratio RATIO] [--start]"),
            "resize": Command("--branch BRANCH --ratio RATIO"),
            "focus": Command("--pane PANE"),
            "maximize": Command("--pane PANE [--restore]"),
            "close": Command("--pane PANE [--allow-running] [--force]")
        ],
        "session": [
            "get": Command("--session SESSION"),
            "start": Command(launchForms[0], launchForms[1], launchForms[2]),
            "restart": Command(launchForms[0] + " [--allow-running] [--force]", launchForms[1] + " [--allow-running] [--force]", launchForms[2] + " [--allow-running] [--force]"),
            "stop": Command("--session SESSION [--force]"),
            "input": Command("--session SESSION --text TEXT [--mode MODE]", "--session SESSION --base64 DATA [--mode MODE]"),
            "execute": Command("--session SESSION --command COMMAND [--wait [--timeout-ms N]]"),
            "output": Command("--session SESSION --view VIEW [--cursor CURSOR] [--max-bytes N]")
        ],
        "host": [
            "list": Command("[--query TEXT] [--tags TAGS]"),
            "get": Command("--host HOST"),
            "create": Command("--name NAME --destination DEST [--user USER] [--port PORT] [--identity-file PATH] [--tags TAGS]"),
            "update": Command("--host HOST [--name NAME] [--destination DEST] [--user USER] [--port PORT] [--identity-file PATH] [--tags TAGS]"),
            "delete": Command("--host HOST"),
            "connect": Command("--host HOST --space SPACE", "--host HOST --split PANE [--axis x|y]", "--host HOST --new-space [--name NAME]")
        ],
        "agent": [
            "list": Command("[--machine local|HOST]"),
            "get": Command("--agent AGENT"),
            "runs": Command("[--space SPACE] [--state STATE]"),
            "start": Command(
                "--agent AGENT \(agentPlacements[0]) [--directory DIR] [--resume]", "--agent AGENT \(agentPlacements[1]) [--directory DIR] [--resume]",
                "--agent AGENT \(agentPlacements[2]) [--directory DIR] [--resume]"),
            "restart": Command("--session SESSION [--resume]"),
            "respond": Command("--session SESSION --action approve|reject|reply [--text TEXT] [--expected-state STATE]"),
            "install": Command("--agent AGENT \(agentPlacements[0])", "--agent AGENT \(agentPlacements[1])", "--agent AGENT \(agentPlacements[2])")
        ],
        "remote": [
            "open": Command("--host HOST [--name NAME] [--start]"),
            "status": Command("--host HOST"),
            "reconnect": Command("--host HOST [--interactive]"),
            "helper install": Command("--host HOST"),
            "helper remove": Command("--host HOST [--stop-sessions]")
        ],
        "project": [
            "list": Command("[--query TEXT]"),
            "get": Command("--project PROJECT"),
            "create": Command("FILE"),
            "update": Command("FILE --project PROJECT"),
            "delete": Command("--project PROJECT"),
            "capture": Command("--space SPACE --name NAME"),
            "check": Command("--project PROJECT --target local|HOST [--folder DIR]"),
            "launch": Command("--project PROJECT --target local|HOST [--folder DIR] [--setup]")
        ],
        "task": [
            "list": Command("--pane PANE"),
            "get": Command("--pane PANE"),
            "run": Command("--pane PANE --task TASK"),
            "stop": Command("--pane PANE [--force]")
        ],
        "layout": [
            "validate": Command("FILE"),
            "plan": Command("FILE --namespace NS"),
            "apply": Command("FILE --namespace NS --expected-revision N [--start-new]"),
            "export": Command("[--space SPACE]...")
        ],
        "events": [
            "subscribe": Command(
                summary: "Print events, one JSON object per line, until the app closes the stream",
                "[--topics TOPICS] [--resource ID]... [--space SPACE]... [--after-sequence N] [--instance ID]"),
            "poll": Command("[--topics TOPICS] [--space SPACE]... [--after-sequence N] [--instance ID] [--timeout-ms N] [--limit N]")
        ],
        "theme": [
            "list": Command(""),
            "get": Command("(--id | --theme) ID"),
            "validate": Command("FILE"),
            "import": Command("FILE [--replace]"),
            "export": Command("(--id | --theme) ID [--resolved]"),
            "delete": Command("(--id | --theme) ID")
        ],
        "cli": [
            "install-link": Command(summary: "Link this binary into a user-local directory", "[--dir DIR]"),
            "remove-link": Command(summary: "Remove the link that install-link created", "[--dir DIR]"),
            "uninstall-plan": Command(summary: "Print what uninstalling would remove; removes nothing", "[--dir DIR]")
        ],
        "appearance": [
            "get": Command(""),
            "set": Command("[--mode MODE] [--light-theme ID] [--dark-theme ID]")
        ]
    ]

    /// A command's one-line summary: its own, else its method's from the catalog.
    static func summary(_ noun: String, _ verb: String) -> String {
        if let summary = commands[noun]?[verb]?.summary { return summary }
        guard let declared = CLICommands.table[noun]?[verb]?.declaration else { return "" }
        var text = ascii(declared.summary)
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Catalog text is written for the docs; help must survive LANG=C.
    static func ascii(_ text: String) -> String {
        let replacements: [Character: String] = ["\u{2026}": "...", "\u{2013}": "-", "\u{2014}": "-", "\u{2192}": "->", "\u{2019}": "'", "\u{2018}": "'", "\u{201C}": "\"", "\u{201D}": "\""]
        return String(text.flatMap { $0.isASCII ? String($0) : replacements[$0] ?? "?" })
    }

    static let options: [String: Option] = [
        "action": Option("ACTION", "approve (1 and Return), reject (Escape) or reply (--text and Return)"),
        "after-sequence": Option("N", "Only events after this sequence number"),
        "agent": Option("AGENT", "Agent definition ID (trellis-claude-code) or exact name"),
        "allow-running": Option("Close running sessions too, instead of failing with CONFIRMATION_REQUIRED"),
        "arg": Option("ARG", "Argument for --process (repeatable)"),
        "automatic-title": Option("Return to the automatic title"),
        "axis": Option("x|y", "x splits left/right, y splits top/bottom"),
        "base64": Option("DATA", "Input bytes, base64-encoded (at most 64 KiB decoded)"),
        "branch": Option("BRANCH", "Split branch UUID"),
        "color": Option("COLOR", "red, orange, yellow, green, blue, purple, gray or none"),
        "command": Option("COMMAND", "One line for the shell to run"),
        "cursor": Option("CURSOR", "Continue from an earlier page's nextCursor"),
        "dark-theme": Option("ID", "Theme for dark appearance"),
        "destination": Option("DEST", "SSH destination"),
        "directory": Option("DIR", "Absolute working directory"),
        "dir": Option("DIR", "Directory for the link (default: ~/.local/bin)"),
        "env": Option("KEY=VALUE", "Environment variable for the launch (repeatable; TRELLIS_ names are reserved)"),
        "expected-revision": Option("N", "Fail with CONFLICT if the revision has changed"),
        "expected-state": Option("STATE", "Answer only while the agent is in this state (default needsInput)"),
        "folder": Option("DIR", "Project folder: absolute or ~/... on this Mac, relative to home on a host"),
        "force": Option("After CLOSE_PENDING and 2 seconds, end sessions that ignored the graceful request"),
        "host": Option("HOST", "Saved host UUID or exact name"),
        "id": Option("ID", "Theme ID"),
        "identity-file": Option("PATH", "SSH identity file"),
        "idempotency-key": Option("KEY", "Return the original result if KEY repeats within 10 minutes"),
        "ids": Option("IDS", "Comma-separated UUIDs, in the new order"),
        "include": Option("LIST", "Comma-separated: tabs, panes, sessions, agents, layout"),
        "instance": Option("ID", "App instance the sequence number belongs to"),
        "interactive": Option("Let ssh ask in the app's connection console (Reconnect...)"),
        "layout": Option("Include each tab's split tree"),
        "light-theme": Option("ID", "Theme for light appearance"),
        "limit": Option("N", "Items per page, 1-500"),
        "machine": Option("local|HOST", "Only availability on this Mac, or on a host"),
        "max-bytes": Option("N", "Read at most N bytes (1-262144)"),
        "mode": Option("MODE", "literal (default) writes the exact bytes; paste adds bracketed-paste framing if the shell asked for it"),
        "name": Option("NAME", "Display name"),
        "namespace": Option("NS", "Namespace that owns the layout's keys"),
        "new-space": Option("Open the host in a new space"),
        "pane": Option("PANE", "Pane UUID"),
        "port": Option("PORT", "SSH port"),
        "process": Option("PATH", "Absolute path of a program to run instead of a shell"),
        "project": Option("PROJECT", "Project UUID or exact name"),
        "query": Option("TEXT", "Only items that match every word of TEXT"),
        "ratio": Option("RATIO", "First child's share, 0.1 to 0.9"),
        "replace": Option("Replace an installed custom theme with the same ID"),
        "resolved": Option("Export the resolved palette"),
        "resource": Option("ID", "Only events for this resource UUID (repeatable)"),
        "restore": Option("Restore the pane instead of maximizing it"),
        "resume": Option("Continue the agent's last conversation"),
        "session": Option("SESSION", "Session UUID"),
        "setup": Option("Create the folder and clone what's missing first"),
        "shell": Option("Start a login shell"),
        "split": Option("PANE", "Split this pane (UUID) for the new pane"),
        "ssh": Option("HOST", "Connect to this saved host with ssh (UUID or exact name)"),
        "start": Option("Start the new session; panes are created stopped otherwise"),
        "start-new": Option("Start sessions in newly created panes"),
        "state": Option("STATE", "ready, working, needsInput, done or error"),
        "stop-sessions": Option("Stop this Mac's sessions still running on the host first"),
        "tab": Option("TAB", "Tab UUID or exact title"),
        "tags": Option("TAGS", "Comma-separated tags"),
        "target": Option("local|HOST", "This Mac, or a saved host (UUID or exact name)"),
        "task": Option("TASK", "Task ID as 'task list' shows it (file:NAME or detected:NAME)"),
        "text": Option("TEXT", "Input text (at most 64 KiB)"),
        "theme": Option("ID", "Same as --id"),
        "timeout-ms": Option("N", "Give up waiting after N milliseconds"),
        "title": Option("TITLE", "Tab title"),
        "topics": Option("TOPICS", "Comma-separated topics (default: workspace,selection,session)"),
        "user": Option("USER", "SSH user"),
        "view": Option("VIEW", "screen, scrollback or stream"),
        "space": Option("SPACE", "Space UUID or exact name")
    ]

    /// Where the same flag means something else on one command.
    static let overrides: [String: Option] = [
        "agent respond --text": Option("TEXT", "With reply: one line, without control characters"),
        "appearance set --mode": Option("MODE", "system, dark or light"),
        "events poll --limit": Option("N", "Most events to return, 1-500 (default 100)"),
        "events poll --timeout-ms": Option("N", "Wait up to N milliseconds (0-25000) for the first event"),
        "host connect --name": Option("NAME", "Name of the new space (default: the host's)"),
        "host create --name": Option("NAME", "Host name"),
        "host update --name": Option("NAME", "Host name"),
        "layout export --space": Option("SPACE", "Only this space: UUID or exact name (repeatable; default: all)"),
        "layout apply --expected-revision": Option("N", "Required: the baseRevision from 'layout plan'"),
        "pane list --space": Option("SPACE", "Every pane in this space; with --tab, where to look for the tab"),
        "project capture --name": Option("NAME", "The new project's name"),
        "remote open --name": Option("NAME", "Space name (default: the host's)"),
        "remote open --start": Option("Connect first and start the shell on the host"),
        "session execute --timeout-ms": Option("N", "With --wait: stop waiting after N ms, 1-600000 (default 30000)"),
        "session execute --wait": Option("Wait for the command to finish and exit with its exit code (needs shell integration)"),
        "session output --cursor": Option("CURSOR", "With --view stream, continue from an earlier read's nextCursor"),
        "session restart --allow-running": Option("Stop a running session too, instead of failing with CONFIRMATION_REQUIRED"),
        "space create --start": Option("Start the new pane's session; it is created stopped otherwise"),
        "space list --name": Option("NAME", "Only spaces with exactly this name"),
        "tab create --start": Option("Start the new pane's session; it is created stopped otherwise"),
        "tab list --title": Option("TITLE", "Only tabs with exactly this title"),
        "pane split --start": Option("Start the new pane's session; it is created stopped otherwise"),
        "agent start --directory": Option("DIR", "Absolute folder to start in (default: the pane's)"),
        "agent start --pane": Option("PANE", "Run in this pane, which must not be running"),
        "agent install --pane": Option("PANE", "Run in this pane, which must not be running"),
        "agent runs --state": Option("STATE", "Only runs in this state: ready, working, needsInput, done or error"),
        "task stop --force": Option("After CLOSE_PENDING and 2 seconds, send Ctrl-\\ instead of Ctrl-C")
    ]

    private static let connectionOptions: [(String, String)] = [
        ("--token-stdin", "Read the grant token from standard input"),
        ("--keychain-grant GRANT_ID", "Read the grant token from the Keychain"),
        ("--launch", "Start Trellis if it is not running"),
        ("--state-directory DIR", "Use the app instance started with this state directory")
    ]
    private static let outputOptions: [(String, String)] = [("--json", "Print one JSON envelope on stdout, for success or failure"), ("-h, --help", "Show this help and exit")]

    static func text(noun: String?, verb: String?) -> String {
        guard let noun else { return overview }
        guard let verb else { return nounHelp(noun) }
        return commandHelp(noun, verb)
    }

    static var version: String { "trellis \(AppVersion.current)" }

    /// The line after a usage error. Built only from names found in the tables, so it never echoes a stray argument.
    static func hint(_ arguments: [String]) -> String {
        var words = arguments.filter { $0 != "--json" }
        if words.first == "help" { words.removeFirst() }
        guard let noun = words.first else { return "Usage: trellis <noun> <verb> [options]\nTry 'trellis --help' for more information." }
        guard let verbs = CLICommands.table[noun] else { return "Try 'trellis --help' for more information." }
        let verb = CLIArguments.verbWords(noun, Array(words.dropFirst())).0
        let topic = verbs[verb] != nil ? "\(noun) \(verb)" : noun
        return "Try 'trellis \(topic) --help' for more information."
    }

    private static var overview: String {
        """
        trellis - script a running Trellis app from the command line

        Usage:
          trellis <noun> <verb> [options]
          trellis help [<noun> [<verb>]]
          trellis --version

        Nouns:
        \(table(nouns.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))

        Options:
        \(table(connectionOptions + outputOptions + [("-V, --version", "Show the version and exit")]))

        Every command except 'cli ...' needs a grant: create one in
        Settings > Automation, then pass --token-stdin or --keychain-grant. Tokens are
        never accepted as arguments. Results go to stdout, diagnostics to stderr.

        Exit status:
        \(table([
            ("0", "Success; with 'session execute --wait', the command's own exit code"), ("2", "Bad arguments, an invalid document, or another protocol version"),
            ("3", "Not found"), ("4", "Authentication, permission or trust failure"), ("5", "Conflict, confirmation required, or invalid state"),
            ("6", "Launch failure, or agent unavailable"), ("7", "App not running, transport failure, or remote host disconnected"),
            ("8", "Limits and other errors"), ("124", "'session execute --wait' stopped waiting; the command keeps running"),
            ("125", "'session execute --wait': the session ended first")
        ]))

        Examples:
          trellis workspace get --include tabs,panes --keychain-grant GRANT_ID
          trellis space create --name Build --start --token-stdin < token-file
          trellis session execute --session ID --command 'swift test' --wait
          trellis events poll --topics agent,attention --timeout-ms 20000

        Run 'trellis <noun> --help' for a noun's verbs, and
        'trellis <noun> <verb> --help' for a verb's options.
        """
    }

    private static func nounHelp(_ noun: String) -> String {
        let verbs = (commands[noun] ?? [:]).keys.sorted().map { ($0, summary(noun, $0)) }
        return """
            trellis \(noun) - \(nouns[noun] ?? "")

            Usage:
              trellis \(noun) <verb> [options]

            Verbs:
            \(table(verbs))

            Run 'trellis \(noun) <verb> --help' for a verb's options.
            """
    }

    private static func commandHelp(_ noun: String, _ verb: String) -> String {
        guard let command = commands[noun]?[verb], let spec = CLICommands.table[noun]?[verb] else { return overview }
        let prefix = "  trellis \(noun) \(verb) "
        let usage = command.usage.flatMap { fill($0.isEmpty ? "[options]" : "\($0) [options]", first: prefix, rest: String(repeating: " ", count: prefix.count)) }
        let title = fill("trellis \(noun) \(verb) - \(summary(noun, verb))", first: "", rest: "  ").joined(separator: "\n")
        var sections = [title, "Usage:\n" + usage.joined(separator: "\n")]
        if let declared = spec.declaration {
            let calls = fill("Calls \(declared.name). Needs: \(ascii(declared.requirementSummary)).", first: "", rest: "  ", keepGroups: false)
            let errors = fill("Errors: " + declared.errors.map(\.rawValue).sorted().joined(separator: ", "), first: "", rest: "  ", keepGroups: false)
            sections.append((calls + errors).joined(separator: "\n"))
        }
        if spec.positionals > 0 { sections.append("Arguments:\n" + table([("FILE", "Path to a JSON document of at most 1 MB")])) }
        let names = optionOrder(command, spec)
        let rows = names.map { name -> (String, String) in
            let option = overrides["\(noun) \(verb) --\(name)"] ?? options[name] ?? Option(name)
            return (option.label(name), option.text)
        }
        if !rows.isEmpty { sections.append("Options:\n" + table(rows)) }
        // The cli commands never reach the app, so the connection options mean nothing to them.
        sections.append((rows.isEmpty ? "Options:\n" : "Global options:\n") + table(noun == "cli" ? outputOptions : connectionOptions + outputOptions))
        return sections.joined(separator: "\n\n")
    }

    /// The flags as the synopsis mentions them, then the convention flags it leaves out for brevity (`--idempotency-key`).
    static func optionOrder(_ command: Command, _ spec: CommandSpec) -> [String] {
        var seen: Set<String> = [], names: [String] = []
        for name in synopsisOptions(command) where seen.insert(name).inserted { names.append(name) }
        return names + spec.options.union(spec.switches).subtracting(seen).sorted()
    }

    static func synopsisOptions(_ command: Command) -> [String] {
        command.usage.flatMap { $0.split { !($0.isLetter || $0.isNumber || $0 == "-") } }.filter { $0.hasPrefix("--") }.map { String($0.dropFirst(2)) }
    }

    // MARK: - Layout

    private static let width = 80

    /// Two aligned columns. A label too long for the column gets its own line, as in argparse.
    private static func table(_ rows: [(String, String)]) -> String {
        let column = 2 + min(rows.map(\.0.count).max() ?? 0, 26) + 2
        let indent = String(repeating: " ", count: column)
        return rows.flatMap { label, text -> [String] in
            let head = "  \(label)"
            if head.count + 2 > column { return [head] + fill(text, first: indent, rest: indent) }
            return fill(text, first: head + String(repeating: " ", count: column - head.count), rest: indent)
        }.joined(separator: "\n")
    }

    private static func fill(_ text: String, first: String, rest: String, keepGroups: Bool = true) -> [String] {
        var lines: [String] = [], line = first, empty = true
        for word in keepGroups ? words(text) : text.split(separator: " ").map(String.init) {
            if !empty, line.count + 1 + word.count > width {
                lines.append(line)
                line = rest + word
            } else {
                line += (empty ? "" : " ") + word
            }
            empty = false
        }
        return lines + [line]
    }

    /// Splits on spaces outside brackets, so `[--expected-revision N]` is never broken across lines.
    private static func words(_ text: String) -> [String] {
        var result: [String] = [], current = "", depth = 0
        for character in text {
            if character == "[" || character == "(" { depth += 1 }
            if character == "]" || character == ")" { depth -= 1 }
            if character == " ", depth == 0 {
                if !current.isEmpty { result.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        return current.isEmpty ? result : result + [current]
    }
}
