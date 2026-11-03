import TrellisCore

/// The text behind `--help`, `help` and `--version`. Plain, 80-column, no color: it is meant for pipes and pagers.
/// `CLIHelpTests` keeps these tables in step with `CLICommands.table`, so a new flag can't ship undocumented.
enum CLIHelp {
    struct Command {
        let summary: String
        /// One synopsis per form, without the `trellis <noun> <verb>` prefix or the trailing `[options]`.
        let usage: [String]
        init(_ summary: String, _ usage: String...) { self.summary = summary; self.usage = usage }
    }

    struct Option {
        let value: String?
        let text: String
        init(_ text: String) { self.value = nil; self.text = text }
        init(_ value: String, _ text: String) { self.value = value; self.text = text }
        func label(_ name: String) -> String { "--\(name)" + (value.map { " \($0)" } ?? "") }
    }

    static let nouns: [String: String] = [
        "appearance": "Show or set the appearance mode and themes",
        "cli": "Manage the command link (local; needs no app or credentials)",
        "events": "Stream workspace events",
        "host": "Manage and connect to saved SSH hosts",
        "layout": "Validate, plan, apply and export layouts",
        "pane": "Split, resize, focus, maximize and close panes",
        "session": "Start sessions, send input and read output",
        "system": "Show app and API information",
        "tab": "List, create, rename, color and close tabs",
        "theme": "Manage the theme library",
        "window": "List, create, rename, reorder and close windows"
    ]

    private static let launchForms = ["--pane PANE [--shell [--directory DIR]]", "--pane PANE --process PATH --directory DIR [--arg ARG]...", "--pane PANE --host-launch HOST"]

    static let commands: [String: [String: Command]] = [
        "system": ["info": Command("Show the API and app versions, grant capabilities and limits", "")],
        "window": [
            "list": Command("List the windows this grant can see", ""),
            "get": Command("Show one window", "--window WINDOW"),
            "create": Command("Create a window with one tab and one pane", "--name NAME [--start]"),
            "rename": Command("Rename a window", "--window WINDOW --name NAME [--expected-revision N]"),
            "reorder": Command("Set the order of all windows", "--ids IDS [--expected-revision N]"),
            "focus": Command("Select a window", "--window WINDOW [--activate]"),
            "close": Command("Close a window", "--window WINDOW [--expected-revision N] [--allow-running] [--force]")
        ],
        "tab": [
            "list": Command("List a window's tabs", "--window WINDOW"),
            "get": Command("Show one tab and its split tree", "--tab TAB"),
            "create": Command("Create a tab with one pane", "--window WINDOW [--title TITLE] [--start]"),
            "rename": Command("Rename a tab", "--tab TAB --title TITLE [--expected-revision N]"),
            "color": Command("Set or remove a tab's color label", "--tab TAB --color COLOR [--expected-revision N]"),
            "reorder": Command("Set the order of a window's tabs", "--window WINDOW --ids IDS [--expected-revision N]"),
            "focus": Command("Select a tab", "--tab TAB"),
            "close": Command("Close a tab", "--tab TAB [--expected-revision N] [--allow-running] [--force]")
        ],
        "pane": [
            "split": Command("Split a pane; the existing pane becomes the first child", "--pane PANE --axis x|y [--ratio RATIO] [--start]"),
            "resize": Command("Set a split's ratio", "--branch BRANCH --ratio RATIO [--expected-revision N]"),
            "focus": Command("Select a pane", "--pane PANE"),
            "maximize": Command("Maximize a pane, or restore it", "--pane PANE [--restore]"),
            "close": Command("Close a pane", "--pane PANE [--allow-running] [--force]")
        ],
        "session": [
            "get": Command("Show a session's state and exit status", "--session SESSION"),
            "start": Command(
                "Start a pane's session; with no launch option, the pane's saved one", launchForms[0], launchForms[1], launchForms[2]),
            "restart": Command(
                "Replace a pane's session with a new one", launchForms[0] + " [--allow-running] [--force]", launchForms[1] + " [--allow-running] [--force]", launchForms[2] + " [--allow-running] [--force]"),
            "input": Command("Send input to a running session", "--session SESSION --text TEXT [--mode MODE]", "--session SESSION --base64 DATA [--mode MODE]"),
            "execute": Command("Type one command line and press Return; does not wait for it", "--session SESSION --command COMMAND --submit"),
            "output": Command("Read a session's output", "--session SESSION --view VIEW [--cursor CURSOR] [--max-bytes N]")
        ],
        "host": [
            "list": Command("List saved hosts", "[--query TEXT]"),
            "get": Command("Show one saved host", "--host HOST"),
            "create": Command("Save a new host", "--name NAME --destination DEST [--user USER] [--port PORT] [--identity-file PATH] [--tags TAGS]"),
            "update": Command("Change a saved host", "--host HOST [--name NAME] [--destination DEST] [--user USER] [--port PORT] [--identity-file PATH] [--tags TAGS] [--expected-revision N]"),
            "delete": Command("Delete a saved host", "--host HOST [--expected-revision N]"),
            "connect": Command("Open a host in a new tab, or in a split of a pane", "--host HOST --window WINDOW [--pane PANE [--axis x|y]]")
        ],
        "layout": [
            "validate": Command("Check a layout document without changing anything", "FILE"),
            "plan": Command("Show what applying a layout would change", "FILE --namespace NS"),
            "apply": Command("Apply a layout; take the revision from 'layout plan'", "FILE --namespace NS --expected-revision N [--start-new]"),
            "export": Command("Print a layout document for all or some windows", "[--window WINDOW]...")
        ],
        "events": ["subscribe": Command("Print events, one JSON object per line, until the app closes the stream", "[--topics TOPICS] [--resource ID]... [--after-sequence N] [--instance ID]")],
        "theme": [
            "list": Command("List installed themes", ""),
            "get": Command("Show a theme's resolved palette", "(--id | --theme) ID"),
            "validate": Command("Check a theme file without installing it", "FILE"),
            "import": Command("Install a theme file", "FILE [--replace]"),
            "export": Command("Print a theme document", "(--id | --theme) ID [--resolved]"),
            "delete": Command("Delete a custom theme", "(--id | --theme) ID")
        ],
        "cli": [
            "install-link": Command("Link this binary into a user-local directory", "[--dir DIR]"),
            "remove-link": Command("Remove the link that install-link created", "[--dir DIR]"),
            "uninstall-plan": Command("Print what uninstalling would remove; removes nothing", "[--dir DIR]")
        ],
        "appearance": [
            "get": Command("Show the mode, selected themes and effective theme", ""),
            "set": Command("Change the mode or the selected themes", "[--mode MODE] [--light-theme ID] [--dark-theme ID] [--expected-revision N]")
        ]
    ]

    static let options: [String: Option] = [
        "activate": Option("Currently has no effect; Trellis is not brought to the front"),
        "after-sequence": Option("N", "Resume after this event sequence number"),
        "allow-running": Option("Close running sessions too, instead of failing with CONFIRMATION_REQUIRED"),
        "arg": Option("ARG", "Argument for --process (repeatable)"),
        "axis": Option("x|y", "x splits left/right, y splits top/bottom"),
        "base64": Option("DATA", "Input bytes, base64-encoded (at most 64 KiB decoded)"),
        "branch": Option("BRANCH", "Split branch UUID"),
        "color": Option("COLOR", "red, orange, yellow, green, blue, purple, gray or none"),
        "command": Option("COMMAND", "One line for the shell to run"),
        "cursor": Option("CURSOR", "With --view stream, continue from an earlier read's nextCursor; other views ignore it"),
        "dark-theme": Option("ID", "Theme for dark appearance"),
        "destination": Option("DEST", "SSH destination"),
        "directory": Option("DIR", "Absolute working directory"),
        "dir": Option("DIR", "Directory for the link (default: ~/.local/bin)"),
        "expected-revision": Option("N", "Fail with CONFLICT if the revision has changed"),
        "force": Option("With --allow-running, force-terminate sessions still running 2 seconds after an earlier attempt; before that, fails with CLOSE_PENDING"),
        "host": Option("HOST", "Saved host UUID or exact name"),
        "host-launch": Option("HOST", "Connect to this saved host (UUID or exact name)"),
        "id": Option("ID", "Theme ID"),
        "identity-file": Option("PATH", "SSH identity file"),
        "idempotency-key": Option("KEY", "Return the original result if KEY repeats within 10 minutes"),
        "ids": Option("IDS", "Comma-separated UUIDs, in the new order"),
        "instance": Option("ID", "App instance the sequence number belongs to"),
        "light-theme": Option("ID", "Theme for light appearance"),
        "max-bytes": Option("N", "Read at most N bytes (1-262144)"),
        "mode": Option("MODE", "literal (default) writes the exact bytes; paste adds bracketed-paste framing if the shell asked for it"),
        "name": Option("NAME", "Display name"),
        "namespace": Option("NS", "Namespace that owns the layout's keys"),
        "pane": Option("PANE", "Pane UUID"),
        "port": Option("PORT", "SSH port"),
        "process": Option("PATH", "Absolute path of a program to run instead of a shell"),
        "query": Option("TEXT", "Only list hosts that match TEXT"),
        "ratio": Option("RATIO", "First child's share, 0.1 to 0.9"),
        "replace": Option("Replace an installed custom theme with the same ID"),
        "resolved": Option("Export the resolved palette"),
        "resource": Option("ID", "Only events for this resource UUID (repeatable)"),
        "restore": Option("Restore the pane instead of maximizing it"),
        "session": Option("SESSION", "Session UUID"),
        "shell": Option("Start a shell"),
        "start": Option("Start the new session; panes are created stopped otherwise"),
        "start-new": Option("Start sessions in newly created panes"),
        "submit": Option("Required: confirms that the line should be submitted"),
        "tab": Option("TAB", "Tab UUID or exact title"),
        "tags": Option("TAGS", "Comma-separated tags"),
        "text": Option("TEXT", "Input text (at most 64 KiB)"),
        "theme": Option("ID", "Same as --id"),
        "title": Option("TITLE", "Tab title"),
        "topics": Option("TOPICS", "Comma-separated topics (default: resources,selection,session)"),
        "user": Option("USER", "SSH user"),
        "view": Option("VIEW", "screen, scrollback or stream"),
        "window": Option("WINDOW", "Window UUID or exact name")
    ]

    /// Where the same flag means something else on one command.
    static let overrides: [String: Option] = [
        "appearance set --mode": Option("MODE", "system, dark or light"),
        "host create --name": Option("NAME", "Host name"),
        "host update --name": Option("NAME", "Host name"),
        "layout export --window": Option("WINDOW", "Only this window: UUID or exact name (repeatable; default: all)"),
        "layout apply --expected-revision": Option("N", "Required: the baseRevision from 'layout plan'"),
        "session restart --allow-running": Option("Stop a running session too, instead of failing with CONFIRMATION_REQUIRED"),
        "window create --start": Option("Start the new pane's session; it is created stopped otherwise"),
        "tab create --start": Option("Start the new pane's session; it is created stopped otherwise"),
        "pane split --start": Option("Start the new pane's session; it is created stopped otherwise")
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
        let topic = words.count > 1 && verbs[words[1]] != nil ? "\(noun) \(words[1])" : noun
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
            ("0", "Success"), ("2", "Bad arguments, or an invalid layout or theme"), ("3", "Not found"), ("4", "Authentication or permission failure"),
            ("5", "Conflict, or confirmation required"), ("6", "Process launch failure"), ("7", "App not running, or transport failure"), ("8", "Other application error")
        ]))

        Examples:
          trellis window list --keychain-grant GRANT_ID
          trellis window create --name Project --token-stdin < token-file
          trellis layout plan ./layout.json --namespace dev --keychain-grant GRANT_ID

        Run 'trellis <noun> --help' for a noun's verbs, and
        'trellis <noun> <verb> --help' for a verb's options.
        """
    }

    private static func nounHelp(_ noun: String) -> String {
        let verbs = (commands[noun] ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value.summary) }
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
        let title = fill("trellis \(noun) \(verb) - \(command.summary)", first: "", rest: "  ").joined(separator: "\n")
        var sections = [title, "Usage:\n" + usage.joined(separator: "\n")]
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

    /// The flags as the synopsis mentions them, then any it leaves out for brevity (`--idempotency-key`).
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

    private static func fill(_ text: String, first: String, rest: String) -> [String] {
        var lines: [String] = [], line = first, empty = true
        for word in words(text) {
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
