import Foundation
import TrellisControl
import TrellisCore

/// Turns a parsed command into its method's params. Names are resolved by the app (filtered lists), never guessed; any
/// lookup happens before the call, so a failed one sends nothing that changes state.
enum CLIParams {
    static func build(_ command: ParsedCommand, _ resolver: inout Resolver, _ environment: CLIEnvironment) throws -> [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        func set(_ key: String, _ option: String) { if let value = command.value(option) { params[key] = .string(value) } }
        func flag(_ key: String, _ name: String) { if command.has(name) { params[key] = .bool(true) } }
        func uuid(_ option: String) throws -> JSONValue? {
            guard let raw = command.value(option) else { return nil }
            guard UUID(uuidString: raw) != nil else { throw CLIFailure.arguments("--\(option) expects a UUID.") }
            return .string(raw.lowercased())
        }
        func number(_ option: String, integer: Bool = false) throws -> JSONValue? {
            guard let raw = command.value(option) else { return nil }
            guard let value = Double(raw), value.isFinite, !integer || value.rounded() == value else {
                throw CLIFailure.arguments("--\(option) expects \(integer ? "an integer" : "a number").")
            }
            return .number(value)
        }
        func list(_ option: String) -> JSONValue? {
            command.value(option).map { .array($0.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) }) }
        }
        func ids(_ option: String) throws -> JSONValue? {
            guard let raw = command.value(option) else { return nil }
            let ids = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard ids.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw CLIFailure.arguments("--\(option) expects comma-separated UUIDs.") }
            return .array(ids.map { .string($0.lowercased()) })
        }
        func space() throws -> JSONValue? { try command.value("space").map { .string(try resolver.space($0)) } }
        func tab() throws -> JSONValue? {
            guard let raw = command.value("tab") else { return nil }
            return .string(try resolver.tab(raw, space: try command.value("space").map { try resolver.space($0) }))
        }
        func host(_ option: String = "host") throws -> JSONValue? { try command.value(option).map { .string(try resolver.host($0)) } }
        func file(_ what: String) throws -> JSONValue? {
            guard let path = command.positionals.first else { return nil }
            let data: Data
            do { data = try environment.readFile(path) } catch { throw CLIFailure.arguments("Cannot read \(path).") }
            guard data.count <= 1_000_000, let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                throw CLIFailure.arguments("\(path) is not a JSON \(what) document of at most 1 MB.")
            }
            return value
        }
        /// `--space` (a new tab), `--split PANE [--axis]`, or the extra kinds a method takes.
        func placement(newSpace: Bool, pane: Bool) throws -> JSONValue {
            var chosen: [[String: JSONValue]] = []
            if let space = try space() { chosen.append(["kind": .string("tab"), "spaceId": space]) }
            if let split = try uuid("split") {
                var object: [String: JSONValue] = ["kind": .string("split"), "paneId": split]
                if let axis = command.value("axis") { object["axis"] = .string(axis) }
                chosen.append(object)
            } else if command.value("axis") != nil {
                throw CLIFailure.arguments("--axis needs --split.")
            }
            if pane, let id = try uuid("pane") { chosen.append(["kind": .string("pane"), "paneId": id]) }
            if newSpace, command.has("new-space") {
                var object: [String: JSONValue] = ["kind": .string("space")]
                if let name = command.value("name") { object["name"] = .string(name) }
                chosen.append(object)
            } else if newSpace, command.value("name") != nil {
                throw CLIFailure.arguments("--name needs --new-space.")
            }
            let forms = ["--space SPACE", "--split PANE"] + (pane ? ["--pane PANE"] : []) + (newSpace ? ["--new-space"] : [])
            guard chosen.count == 1, let only = chosen.first else { throw CLIFailure.arguments("Give exactly one of \(forms.joined(separator: ", ")).") }
            return .object(only)
        }
        func launch() throws {
            let kinds = [command.has("shell"), command.value("process") != nil, command.value("ssh") != nil].filter { $0 }.count
            guard kinds <= 1 else { throw CLIFailure.arguments("Use only one of --shell, --process, or --ssh.") }
            var variables: [String: JSONValue] = [:]
            for entry in command.options["env"] ?? [] {
                guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { throw CLIFailure.arguments("--env expects KEY=VALUE.") }
                variables[String(entry[..<equals])] = .string(String(entry[entry.index(after: equals)...]))
            }
            var object: [String: JSONValue]
            if command.has("shell") {
                object = ["kind": .string("shell")]
                if let directory = command.value("directory") { object["directory"] = .string(directory) }
            } else if let executable = command.value("process") {
                guard let directory = command.value("directory") else { throw CLIFailure.arguments("--process needs --directory.") }
                object = [
                    "kind": .string("process"), "executable": .string(executable), "directory": .string(directory),
                    "arguments": .array((command.options["arg"] ?? []).map(JSONValue.string))
                ]
            } else if let hostID = try host("ssh") {
                guard variables.isEmpty, command.value("directory") == nil, command.options["arg"] == nil else {
                    throw CLIFailure.arguments("--ssh takes no --directory, --arg or --env.")
                }
                params["launch"] = .object(["kind": .string("ssh"), "hostId": hostID])
                return
            } else {
                guard command.value("directory") == nil, command.options["arg"] == nil, variables.isEmpty else {
                    throw CLIFailure.arguments("--directory, --arg and --env need --shell or --process.")
                }
                return
            }
            if !variables.isEmpty { object["environment"] = .object(variables) }
            params["launch"] = .object(object)
        }
        func target() throws -> JSONValue? {
            guard let raw = command.value("target") else { return nil }
            return raw == "local" ? .object(["kind": .string("local")]) : .object(["kind": .string("host"), "hostId": .string(try resolver.host(raw))])
        }

        // The conventions every method shares, offered where the declaration takes them.
        set("idempotencyKey", "idempotency-key")
        params["expectedRevision"] = try number("expected-revision", integer: true)
        params["limit"] = try number("limit", integer: true)
        set("cursor", "cursor")
        switch "\(command.noun) \(command.verb)" {
        case "workspace get": params["include"] = list("include")
        case "space list": set("name", "name")
        case "space get", "space focus": params["id"] = try space()
        case "space rename": params["id"] = try space(); set("name", "name")
        case "space close": params["id"] = try space(); flag("allowRunning", "allow-running"); flag("force", "force")
        case "space create": set("name", "name"); flag("start", "start")
        case "space reorder": params["ids"] = try ids("ids")
        case "tab list":
            params["spaceId"] = try space(); set("title", "title")
            if command.has("layout") { params["include"] = .array([.string("layout")]) }
        case "tab get", "tab focus": params["id"] = try tab()
        case "tab rename":
            guard (command.value("title") != nil) != command.has("automatic-title") else { throw CLIFailure.arguments("Give --title TITLE or --automatic-title.") }
            params["id"] = try tab()
            params["title"] = command.value("title").map(JSONValue.string) ?? .null
        case "tab color":
            params["id"] = try tab()
            // `none` removes the label; the app validates color names.
            if let color = command.value("color") { params["color"] = color == "none" ? .null : .string(color) }
        case "tab duplicate": params["id"] = try tab(); flag("start", "start")
        case "tab close": params["id"] = try tab(); flag("allowRunning", "allow-running"); flag("force", "force")
        case "tab create": params["spaceId"] = try space(); set("title", "title"); set("color", "color"); flag("start", "start")
        case "tab reorder": params["spaceId"] = try space(); params["ids"] = try ids("ids")
        case "pane list":
            if command.value("tab") != nil { params["tabId"] = try tab() } else if command.value("space") != nil { params["spaceId"] = try space() }
            guard params["tabId"] != nil || params["spaceId"] != nil else { throw CLIFailure.arguments("pane list needs --tab or --space.") }
        case "pane get", "pane focus": params["id"] = try uuid("pane")
        case "pane close": params["id"] = try uuid("pane"); flag("allowRunning", "allow-running"); flag("force", "force")
        case "pane maximize": params["id"] = try uuid("pane"); params["maximized"] = .bool(!command.has("restore"))
        case "pane split": params["id"] = try uuid("pane"); set("axis", "axis"); params["ratio"] = try number("ratio"); flag("start", "start")
        case "pane resize": params["branchId"] = try uuid("branch"); params["ratio"] = try number("ratio")
        case "session get": params["id"] = try uuid("session")
        case "session stop": params["id"] = try uuid("session"); flag("force", "force")
        case "session input": params["id"] = try uuid("session"); set("text", "text"); set("base64", "base64"); set("mode", "mode")
        case "session execute":
            params["id"] = try uuid("session"); set("command", "command")
            if command.has("wait") {
                var wait: [String: JSONValue] = ["until": .string("finished")]
                wait["timeoutMs"] = try number("timeout-ms", integer: true)
                params["wait"] = .object(wait)
            } else if command.value("timeout-ms") != nil {
                throw CLIFailure.arguments("--timeout-ms needs --wait.")
            }
        case "session output":
            params["id"] = try uuid("session"); set("view", "view")
            params["maxBytes"] = try number("max-bytes", integer: true)
        case "session start": params["paneId"] = try uuid("pane"); try launch()
        case "session restart": params["paneId"] = try uuid("pane"); try launch(); flag("allowRunning", "allow-running"); flag("force", "force")
        case "host list": set("query", "query"); params["tags"] = list("tags")
        case "host get", "host delete": params["id"] = try host()
        case "host create", "host update":
            if command.verb == "update" { params["id"] = try host() }
            set("name", "name"); set("destination", "destination"); set("user", "user"); set("identityFile", "identity-file")
            params["port"] = try number("port", integer: true); params["tags"] = list("tags")
        case "host connect": params["hostId"] = try host(); params["placement"] = try placement(newSpace: true, pane: false)
        case "agent list":
            if let machine = command.value("machine") {
                params["machine"] = machine == "local" ? .object(["kind": .string("local")]) : .object(["kind": .string("remote"), "hostId": .string(try resolver.host(machine))])
            }
        case "agent get": params["id"] = .string(try resolver.agent(command.value("agent") ?? ""))
        case "agent runs": params["spaceId"] = try space(); set("state", "state")
        case "agent start", "agent install":
            params["agentId"] = .string(try resolver.agent(command.value("agent") ?? ""))
            params["placement"] = try placement(newSpace: false, pane: true)
            set("directory", "directory"); flag("resume", "resume")
        case "agent restart": params["sessionId"] = try uuid("session"); flag("resume", "resume")
        case "agent respond":
            params["sessionId"] = try uuid("session"); set("action", "action"); set("text", "text"); set("expectedState", "expected-state")
        case "remote open": params["hostId"] = try host(); set("name", "name"); flag("start", "start")
        case "remote status", "remote helper install": params["hostId"] = try host()
        case "remote reconnect": params["hostId"] = try host(); flag("interactive", "interactive")
        case "remote helper remove": params["hostId"] = try host(); flag("stopSessions", "stop-sessions")
        case "project list": set("query", "query")
        case "project get", "project delete": params["id"] = .string(try resolver.project(command.value("project") ?? ""))
        case "project create": params["document"] = try file("project")
        case "project update": params["id"] = .string(try resolver.project(command.value("project") ?? "")); params["document"] = try file("project")
        case "project capture": params["spaceId"] = try space(); set("name", "name")
        case "project check", "project launch":
            params["id"] = .string(try resolver.project(command.value("project") ?? ""))
            params["target"] = try target(); set("folder", "folder"); flag("setup", "setup")
        case "task list", "task get": params["paneId"] = try uuid("pane")
        case "task run": params["paneId"] = try uuid("pane"); set("taskId", "task")
        case "task stop": params["paneId"] = try uuid("pane"); flag("force", "force")
        case "layout validate", "layout plan", "layout apply":
            params["document"] = try file("layout"); set("namespace", "namespace"); flag("startNew", "start-new")
        case "layout export":
            if let spaces = command.options["space"] { params["spaceIds"] = .array(try spaces.map { .string(try resolver.space($0)) }) }
        case "theme validate", "theme import":
            // Theme files go as raw text so the app's validator sees duplicate keys exactly.
            if let path = command.positionals.first {
                guard let data = try? environment.readFile(path), data.count <= 1_000_000, let text = String(data: data, encoding: .utf8) else {
                    throw CLIFailure.arguments("Cannot read \(path) as a UTF-8 theme file.")
                }
                params["documentText"] = .string(text)
            }
            flag("replace", "replace")
        case "theme get", "theme export", "theme delete":
            set("id", "id"); set("id", "theme"); flag("resolved", "resolved")
            guard params["id"] != nil else { throw CLIFailure.arguments("--id is required.") }
        case "appearance set": set("mode", "mode"); set("lightThemeId", "light-theme"); set("darkThemeId", "dark-theme")
        case "events subscribe", "events poll":
            params["topics"] = list("topics") ?? .array(defaultTopics.map(JSONValue.string))
            if let resources = command.options["resource"] {
                guard resources.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw CLIFailure.arguments("--resource expects UUIDs.") }
                params["resourceIds"] = .array(resources.map { .string($0.lowercased()) })
            }
            if let spaces = command.options["space"] { params["spaceIds"] = .array(try spaces.map { .string(try resolver.space($0)) }) }
            params["afterSequence"] = try number("after-sequence", integer: true)
            set("instanceId", "instance")
            params["timeoutMs"] = try number("timeout-ms", integer: true)
        default: break
        }
        return params
    }

    /// What `events subscribe` and `events poll` follow without `--topics`.
    static let defaultTopics = ["workspace", "selection", "session"]
}

/// Resolves explicit UUIDs directly, or exact names through the app's filtered lists, page by page. A name that matches
/// several resources is an argument error, never a guess.
struct Resolver {
    let transport: CLITransport

    /// Every item of a list call, following `nextCursor`.
    private func list(_ method: String, _ params: [String: JSONValue], key: String) throws -> [[String: JSONValue]] {
        var items: [[String: JSONValue]] = [], params = params
        params["limit"] = .number(Double(PageV2.maximumLimit))
        for _ in 0..<100 {
            let response = try transport.call(method, params)
            // A denied or failed lookup keeps its own status; it is not "no match".
            if response["error"] != nil { throw CLI.failure(from: response) }
            if case .array(let page)? = response["result"]?[key] { items += page.compactMap { if case .object(let item) = $0 { item } else { nil } } }
            guard case .string(let cursor)? = response["result"]?["nextCursor"] else { break }
            params["cursor"] = .string(cursor)
        }
        return items
    }

    private func match(_ name: String, in items: [[String: JSONValue]], field: String, kind: String) throws -> String {
        let matches = items.filter { $0[field] == .string(name) }
        guard !matches.isEmpty else { throw CLIFailure(code: "NOT_FOUND", message: "No \(kind) is named \(name).", exitStatus: APIErrorCode.notFound.cliExitStatus) }
        guard matches.count == 1, case .string(let id)? = matches[0]["id"] else {
            throw CLIFailure.arguments("\(matches.count) \(kind)s are named \(name). Use its ID instead.")
        }
        return id
    }

    private static func id(_ value: String) -> String? { UUID(uuidString: value) != nil ? value.lowercased() : nil }

    func space(_ value: String) throws -> String {
        if let id = Self.id(value) { return id }
        return try match(value, in: try list("space.list", ["name": .string(value)], key: "spaces"), field: "name", kind: "space")
    }

    /// In `space` when given, otherwise in every space in scope.
    func tab(_ value: String, space: String?) throws -> String {
        if let id = Self.id(value) { return id }
        let spaces = try space.map { [$0] } ?? list("space.list", [:], key: "spaces").compactMap { if case .string(let id)? = $0["id"] { id } else { nil } }
        var tabs: [[String: JSONValue]] = []
        for id in spaces { tabs += try list("tab.list", ["spaceId": .string(id), "title": .string(value)], key: "tabs") }
        return try match(value, in: tabs, field: "title", kind: "tab")
    }

    func host(_ value: String) throws -> String {
        if let id = Self.id(value) { return id }
        return try match(value, in: try list("host.list", ["query": .string(value)], key: "hosts"), field: "name", kind: "host")
    }

    func project(_ value: String) throws -> String {
        if let id = Self.id(value) { return id }
        return try match(value, in: try list("project.list", ["query": .string(value)], key: "projects"), field: "name", kind: "project")
    }

    /// A definition ID as it is (`trellis-claude-code`), or a definition's exact name.
    func agent(_ value: String) throws -> String {
        let response = try transport.call("agent.get", ["id": .string(value)])
        if response["error"] == nil { return value }
        let failure = CLI.failure(from: response)
        guard failure.code == APIErrorCode.notFound.rawValue || failure.code == "INVALID_PARAMS" else { throw failure }
        return try match(value, in: try list("agent.list", [:], key: "agents"), field: "name", kind: "agent")
    }
}
