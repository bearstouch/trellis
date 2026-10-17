import Darwin
import Foundation
import Security
import TrellisControl
import TrellisRelease

/// A failure with the documented exit status (API-06 CLI contract).
public struct CLIFailure: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public let exitStatus: Int32
    public var details: JSONValue?

    static func arguments(_ message: String) -> Self { Self(code: "INVALID_ARGUMENTS", message: message, exitStatus: 2) }
    static let notRunning = Self(code: "APP_NOT_RUNNING", message: "Trellis is not running. Start it, or pass --launch to start it.", exitStatus: 7)
    static func transport(_ message: String) -> Self { Self(code: "TRANSPORT", message: message, exitStatus: 7) }

    /// 0 ok · 2 arguments/schema · 3 not found · 4 auth/permission · 5 conflict ·
    /// 6 launch failure · 7 app unavailable/transport · 8 other application error.
    static func status(appCode: String?, rpcCode: Int) -> Int32 {
        switch appCode {
        case "NOT_FOUND"?: return 3
        case "AUTH_REQUIRED"?, "PERMISSION_DENIED"?: return 4
        case "CONFLICT"?, "CONFIRMATION_REQUIRED"?: return 5
        case "LAUNCH_FAILED"?: return 6
        case "UNSUPPORTED_VERSION"?: return 7
        case .some: return 8
        case nil: return [-32700, -32600, -32602].contains(rpcCode) ? 2 : rpcCode == -32601 ? 3 : 8
        }
    }
}

/// One request/response exchange over the control socket.
public protocol CLITransport: AnyObject {
    /// Sends a request and returns its response object. Throws only for
    /// transport failures; the outcome of an in-flight request is then unknown.
    func call(_ method: String, _ params: [String: JSONValue]) throws(CLIFailure) -> [String: JSONValue]
    /// Reads the next server notification line (events), or nil at EOF.
    func nextNotification() throws(CLIFailure) -> [String: JSONValue]?
    func close()
}

/// Every side effect is injected so tests never touch the real app, socket,
/// Keychain, or terminal.
public struct CLIEnvironment {
    public var discover: (_ stateDirectory: URL) -> ControlDiscovery?
    public var connect: (_ socketPath: String) throws(CLIFailure) -> CLITransport
    /// Starts the app (normal native launch). Called only with --launch.
    /// `stateDirectory` is non-nil only for an explicit --state-directory, which the app must use too.
    public var launchApp: (_ stateDirectory: URL?) -> Bool
    public var readStdinLine: () -> String?
    public var readKeychain: (_ grantID: UUID) -> String?
    public var readFile: (_ path: String) throws -> Data
    public var stdout: (String) -> Void
    public var stderr: (String) -> Void
    public var sleep: (TimeInterval) -> Void
    public var defaultStateDirectory: URL
    /// Local setup effects (link management), injected for tests.
    /// `$HOME` first, like other command-line tools, so a link can target another home.
    public var home: String = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? NSHomeDirectory()
    // The real executable, not argv[0], which is a bare name when run through PATH.
    public var executablePath: String = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? ""
    /// Resolves symlinks in the existing part of a path, so a link directory such
    /// as `~/bin -> /usr/local/bin` is judged by where it really points.
    public var resolvePath: (String) -> String = { path in
        var existing = path, rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing), existing != "/" {
            rest.insert((existing as NSString).lastPathComponent, at: 0); existing = (existing as NSString).deletingLastPathComponent
        }
        return NSString.path(withComponents: [URL(fileURLWithPath: existing).resolvingSymlinksInPath().path] + rest)
    }
    public var linkState: (String) -> CLILinkPlanner.Existing = { path in
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) { return .symlink(to: target) }
        return FileManager.default.fileExists(atPath: path) ? .otherFile : .nothing
    }
    public var createLink: (String, String) throws -> Void = { link, target in
        try FileManager.default.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
    }
    // unlink(2), never a recursive delete, even if the path changed since it was inspected.
    public var removeLink: (String) throws -> Void = { path in
        guard unlink(path) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path]) }
    }

    public static var live: CLIEnvironment {
        CLIEnvironment(
            discover: { ControlEndpoint(stateDirectory: $0).readDiscovery() },
            connect: { path throws(CLIFailure) in try SocketTransport(path: path) },
            launchApp: { stateDirectory in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                // A normal native launch; an explicit state directory is forwarded unchanged.
                process.arguments = ["-b", "dev.trellis"] + (stateDirectory.map { ["--args", "--state-directory", $0.path] } ?? [])
                guard (try? process.run()) != nil else { return false }
                process.waitUntilExit()
                return process.terminationStatus == 0
            },
            readStdinLine: { readLine(strippingNewline: true) },
            readKeychain: { grantID in
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: KeychainGrantSecretStore.service,
                    kSecAttrAccount as String: grantID.uuidString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne
                ]
                var item: CFTypeRef?
                guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
                return String(data: data, encoding: .utf8)
            },
            readFile: { try Data(contentsOf: URL(fileURLWithPath: $0)) },
            stdout: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
            stderr: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            defaultStateDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("dev.trellis", isDirectory: true))
    }
}

public enum CLI {
    /// Runs one invocation and returns the process exit status. Never retries.
    public static func run(_ arguments: [String], environment: CLIEnvironment) -> Int32 {
        let json = arguments.contains("--json")
        do {
            let command: ParsedCommand
            do { command = try CLIArguments.parse(arguments) } catch { throw CLIFailure.arguments(Self.message(error)) }
            let result = try execute(command, environment)
            emit(.object(["ok": .bool(true), "result": result]), json: json, environment: environment)
            return 0
        } catch let failure as CLIFailure {
            var error: [String: JSONValue] = ["code": .string(failure.code), "message": .string(failure.message), "exitStatus": .number(Double(failure.exitStatus))]
            if let details = failure.details { error["details"] = details }
            if json {
                environment.stdout(encode(.object(["ok": .bool(false), "error": .object(error)])))
            } else {
                environment.stderr("trellis: \(failure.message) (\(failure.code))")
            }
            return failure.exitStatus
        } catch {
            environment.stderr("trellis: unexpected failure")
            return 8
        }
    }

    private static func message(_ error: ArgumentError) -> String {
        switch error {
        case .usage(let text): text
        }
    }

    static func emit(_ envelope: JSONValue, json: Bool, environment: CLIEnvironment) {
        if json {
            environment.stdout(encode(envelope))
        } else if case .object(let object) = envelope, let result = object["result"] {
            environment.stdout(encode(result, pretty: true))
        }
    }

    static func encode(_ value: JSONValue, pretty: Bool = false) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    // MARK: - Execution

    private static func execute(_ command: ParsedCommand, _ environment: CLIEnvironment) throws -> JSONValue {
        if command.noun == "cli" { return try local(command, environment) }
        let token = try credential(command, environment)
        let stateDirectory = command.value("state-directory").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? environment.defaultStateDirectory
        let transport = try connect(stateDirectory, explicit: command.value("state-directory") != nil, launch: command.has("launch"), environment)
        defer { transport.close() }
        let auth = try transport.call("auth.authenticate", ["protocolVersion": .number(1), "token": .string(token)])
        if auth["error"] != nil { throw failure(from: auth) }
        var resolver = Resolver(transport: transport)
        let params = try buildParams(command, &resolver, environment)
        if command.spec == "events.subscribe" { try stream(command, params, transport, environment) }
        let response = try transport.call(command.spec, params)
        if response["error"] != nil { throw failure(from: response) }
        // An invalid document is a schema error (exit 2), with the issues as details.
        if ["layout.validate", "theme.validate"].contains(command.spec), case .object(let result)? = response["result"], result["valid"] == .bool(false) {
            let kind = command.spec == "theme.validate" ? "THEME" : "LAYOUT"
            throw CLIFailure(code: "INVALID_\(kind)", message: "The \(kind.lowercased()) document is invalid.", exitStatus: 2, details: response["result"])
        }
        return response["result"] ?? .null
    }

    /// Explicit, user-invoked setup. Only one symlink in a user-local directory is
    /// ever created or removed; shell startup files are never edited.
    private static func local(_ command: ParsedCommand, _ environment: CLIEnvironment) throws -> JSONValue {
        let directory = command.value("dir") ?? "~/.local/bin"
        // Judge the real (symlink-resolved) directory too, so links cannot escape the home folder.
        let real = environment.resolvePath((CLILinkPlanner.linkPath(directory: directory, home: environment.home) as NSString).deletingLastPathComponent)
        if let problem = CLILinkPlanner.validate(directory: directory, home: environment.home) ?? CLILinkPlanner.validate(directory: real, home: environment.resolvePath(environment.home)) {
            throw CLIFailure.arguments(problem)
        }
        let link = { (plan: CLILinkPlanner.Plan) -> String? in
            switch plan {
            case .create(let link, _), .replace(let link, _), .alreadyInstalled(let link), .remove(let link): link
            default: nil
            }
        }
        switch command.verb {
        case "install-link":
            let cli = environment.executablePath
            guard cli.hasSuffix(".app/Contents/Helpers/\(CLILinkPlanner.linkName)") else {
                throw CLIFailure.arguments("Run install-link from the trellis inside Trellis.app (Trellis.app/Contents/Helpers/trellis).")
            }
            let probe = CLILinkPlanner.install(directory: directory, home: environment.home, cliPath: cli, existing: .nothing)
            guard let path = link(probe) else {
                if case .refused(let reason) = probe { throw CLIFailure.arguments(reason) }
                throw CLIFailure.arguments("Invalid directory.")
            }
            let plan = CLILinkPlanner.install(directory: directory, home: environment.home, cliPath: cli, existing: environment.linkState(path))
            switch plan {
            case .create(let path, let target), .replace(let path, let target):
                if case .replace = plan { try environment.removeLink(path) }
                try environment.createLink(path, target)
            case .alreadyInstalled: break
            case .refused(let reason): throw CLIFailure(code: "CONFLICT", message: reason, exitStatus: 5)
            default: break
            }
            return .object([
                "link": .string(path), "target": .string(cli),
                "note": .string("Add \((path as NSString).deletingLastPathComponent) to PATH yourself if it is not already; Trellis never edits shell files.")
            ])
        case "remove-link":
            let probe = CLILinkPlanner.remove(directory: directory, home: environment.home, existing: .nothing)
            if case .refused(let reason) = probe { throw CLIFailure.arguments(reason) }
            let path = CLILinkPlanner.linkPath(directory: directory, home: environment.home)
            switch CLILinkPlanner.remove(directory: directory, home: environment.home, existing: environment.linkState(path)) {
            case .remove(let path):
                try environment.removeLink(path)
                return .object(["removed": .string(path)])
            case .nothingToRemove: return .object(["removed": .null])
            case .refused(let reason): throw CLIFailure(code: "CONFLICT", message: reason, exitStatus: 5)
            default: return .null
            }
        default:
            let path = CLILinkPlanner.linkPath(directory: directory, home: environment.home)
            let items = UninstallPlanner.items(home: environment.home, cliLink: path)
            let entries: [JSONValue] = items.map { item in .object(["path": .string(item.path), "description": .string(item.description)]) }
            return .object([
                "dryRun": .bool(true),
                "remove": .array(entries),
                "keychain": .string(
                    "Delete generic passwords with service "
                        + UninstallPlanner.keychainServices.map { "\"\($0)\"" }.joined(separator: " or ")
                        + " (Keychain Access, or: "
                        + UninstallPlanner.keychainServices.map { "security delete-generic-password -s \"\($0)\"" }.joined(separator: "; ") + ")."),
                "neverRemoved": .string("~/.ssh (keys, config, known_hosts), shell startup files, and shell history are never touched.")
            ])
        }
    }

    private static func credential(_ command: ParsedCommand, _ environment: CLIEnvironment) throws(CLIFailure) -> String {
        if command.has("token-stdin") {
            guard let line = environment.readStdinLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
                throw CLIFailure.arguments("--token-stdin expects the grant token on standard input.")
            }
            return line
        }
        if let raw = command.value("keychain-grant") {
            guard let id = UUID(uuidString: raw) else { throw CLIFailure.arguments("--keychain-grant expects the grant UUID shown in Settings → Automation.") }
            guard let token = environment.readKeychain(id) else {
                throw CLIFailure(code: "AUTH_REQUIRED", message: "No Keychain token was found for that grant.", exitStatus: 4)
            }
            return token
        }
        throw CLIFailure.arguments("Provide credentials with --token-stdin or --keychain-grant GRANT_ID.")
    }

    /// Discovery only; the app is started solely when --launch was passed.
    private static func connect(_ stateDirectory: URL, explicit: Bool, launch: Bool, _ environment: CLIEnvironment) throws(CLIFailure) -> CLITransport {
        if let discovery = environment.discover(stateDirectory), let transport = try? environment.connect(discovery.socketPath) { return transport }
        guard launch else { throw CLIFailure.notRunning }
        guard environment.launchApp(explicit ? stateDirectory : nil) else { throw CLIFailure.transport("Trellis could not be launched.") }
        for _ in 0..<50 {
            environment.sleep(0.2)
            if let discovery = environment.discover(stateDirectory), let transport = try? environment.connect(discovery.socketPath) { return transport }
        }
        throw CLIFailure.transport("Trellis was launched but its control socket did not appear.")
    }

    static func failure(from response: [String: JSONValue]) -> CLIFailure {
        guard case .object(let error)? = response["error"] else { return CLIFailure(code: "INTERNAL", message: "Malformed response.", exitStatus: 8) }
        let rpcCode: Int = if case .number(let value)? = error["code"] { Int(value) } else { -32603 }
        let message: String = if case .string(let text)? = error["message"] { text } else { "The request failed." }
        var appCode: String?
        if case .object(let data)? = error["data"], case .string(let code)? = data["code"] { appCode = code }
        var failure = CLIFailure(
            code: appCode ?? (rpcCode == -32602 ? "INVALID_PARAMS" : rpcCode == -32601 ? "METHOD_NOT_FOUND" : "PROTOCOL_ERROR"), message: message, exitStatus: CLIFailure.status(appCode: appCode, rpcCode: rpcCode))
        failure.details = error["data"]
        return failure
    }

    /// Writes the subscription envelope first (its instance ID and sequence are
    /// needed to resume), then one notification per line. The stream only ends
    /// when the app closes it, which is reported as a transport failure.
    private static func stream(_ command: ParsedCommand, _ params: [String: JSONValue], _ transport: CLITransport, _ environment: CLIEnvironment) throws -> Never {
        let response = try transport.call("events.subscribe", params)
        if response["error"] != nil { throw failure(from: response) }
        emit(.object(["ok": .bool(true), "result": response["result"] ?? .null]), json: command.has("json"), environment: environment)
        environment.stderr("trellis: subscribed; streaming events (Ctrl-C to stop)")
        while let event = try transport.nextNotification() { environment.stdout(encode(.object(event))) }
        throw CLIFailure.transport("The app closed the event stream. Resubscribe with --instance and --after-sequence to resume.")
    }

    // MARK: - Params

    private static func buildParams(_ command: ParsedCommand, _ resolver: inout Resolver, _ environment: CLIEnvironment) throws -> [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        func set(_ key: String, _ option: String) { if let value = command.value(option) { params[key] = .string(value) } }
        func uuid(_ key: String, _ option: String) throws {
            guard let raw = command.value(option) else { return }
            guard UUID(uuidString: raw) != nil else { throw CLIFailure.arguments("--\(option) expects a UUID.") }
            params[key] = .string(raw)
        }
        func number(_ key: String, _ option: String, integer: Bool = false) throws {
            guard let raw = command.value(option) else { return }
            guard let value = Double(raw), value.isFinite, !integer || value.rounded() == value else {
                throw CLIFailure.arguments("--\(option) expects \(integer ? "an integer" : "a number").")
            }
            params[key] = .number(value)
        }
        func flag(_ key: String, _ name: String) { if command.has(name) { params[key] = .bool(true) } }
        func window(_ key: String) throws { if let raw = command.value("window") { params[key] = .string(try resolver.window(raw).uuidString) } }
        func tab(_ key: String) throws { if let raw = command.value("tab") { params[key] = .string(try resolver.tab(raw).uuidString) } }
        func host(_ key: String) throws { if let raw = command.value("host") { params[key] = .string(try resolver.host(raw).uuidString) } }
        func idList(_ option: String) throws -> JSONValue? {
            guard let raw = command.value(option) else { return nil }
            let ids = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard ids.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw CLIFailure.arguments("--\(option) expects comma-separated UUIDs.") }
            return .array(ids.map(JSONValue.string))
        }
        func launch() throws {
            let kinds = [command.has("shell"), command.value("process") != nil, command.value("host-launch") != nil].filter { $0 }.count
            guard kinds <= 1 else { throw CLIFailure.arguments("Use only one of --shell, --process, or --host-launch.") }
            if command.has("shell") {
                var object: [String: JSONValue] = ["kind": .string("shell")]
                if let directory = command.value("directory") { object["directory"] = .string(directory) }
                params["launch"] = .object(object)
            } else if let executable = command.value("process") {
                guard let directory = command.value("directory") else { throw CLIFailure.arguments("--process needs --directory.") }
                params["launch"] = .object([
                    "kind": .string("process"), "executable": .string(executable), "directory": .string(directory),
                    "arguments": .array((command.options["arg"] ?? []).map(JSONValue.string))
                ])
            } else if let raw = command.value("host-launch") {
                params["launch"] = .object(["kind": .string("host"), "hostId": .string(try resolver.host(raw).uuidString)])
            } else if command.value("directory") != nil || command.options["arg"] != nil {
                throw CLIFailure.arguments("--directory and --arg need --shell or --process.")
            }
        }
        func document() throws {
            guard let path = command.positionals.first else { return }
            let data: Data
            do { data = try environment.readFile(path) } catch { throw CLIFailure.arguments("Cannot read \(path).") }
            guard data.count <= 1_000_000, let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                throw CLIFailure.arguments("\(path) is not a JSON layout document of at most 1 MB.")
            }
            params["document"] = value
        }
        set("idempotencyKey", "idempotency-key")
        try number("expectedRevision", "expected-revision", integer: true)
        switch command.spec {
        case "window.get", "window.update", "window.focus", "window.close":
            try window("id")
            guard params["id"] != nil else { throw CLIFailure.arguments("--window is required.") }
            set("name", "name")
            flag("allowRunning", "allow-running"); flag("force", "force"); flag("activateApp", "activate")
        case "window.create": set("name", "name"); flag("start", "start")
        case "window.reorder": params["ids"] = try idList("ids")
        case "tab.list", "tab.create", "tab.reorder":
            try window("windowId")
            set("title", "title"); flag("start", "start")
            if let ids = try idList("ids") { params["ids"] = ids }
        case "tab.get", "tab.update", "tab.focus", "tab.close":
            try tab("id")
            set("title", "title"); flag("allowRunning", "allow-running"); flag("force", "force")
            // `none` removes the label; the app validates color names.
            if let color = command.value("color") { params["color"] = color == "none" ? .null : .string(color) }
        case "pane.split":
            try uuid("paneId", "pane"); set("axis", "axis"); try number("ratio", "ratio"); flag("start", "start")
        case "pane.resize": try uuid("branchId", "branch"); try number("ratio", "ratio")
        case "pane.focus", "pane.close": try uuid("id", "pane"); flag("allowRunning", "allow-running"); flag("force", "force")
        case "pane.maximize": try uuid("id", "pane"); params["maximized"] = .bool(!command.has("restore"))
        case "session.get", "session.sendInput", "session.execute", "session.readOutput":
            try uuid("id", "session")
            set("text", "text"); set("base64", "base64"); set("mode", "mode"); set("command", "command"); set("view", "view"); set("cursor", "cursor")
            try number("maxBytes", "max-bytes", integer: true)
            flag("submit", "submit")
        case "session.start", "session.restart":
            try uuid("paneId", "pane"); try launch(); flag("allowRunning", "allow-running"); flag("force", "force")
        case "host.list": set("query", "query")
        case "host.get", "host.update", "host.delete", "host.create", "host.connect":
            try host(command.spec == "host.connect" ? "hostId" : "id")
            set("name", "name"); set("destination", "destination"); set("user", "user"); set("identityFile", "identity-file")
            try number("port", "port", integer: true)
            if let tags = command.value("tags") { params["tags"] = .array(tags.split(separator: ",").map { .string(String($0)) }) }
            if command.spec == "host.connect" { try window("windowId"); try uuid("paneId", "pane"); set("axis", "axis") }
        case "layout.validate", "layout.plan", "layout.apply":
            try document(); set("namespace", "namespace"); flag("startNew", "start-new")
        case "theme.validate", "theme.import":
            // Theme files go as raw text so the app's validator sees duplicate keys exactly.
            if let path = command.positionals.first {
                guard let data = try? environment.readFile(path), data.count <= 1_000_000, let text = String(data: data, encoding: .utf8) else {
                    throw CLIFailure.arguments("Cannot read \(path) as a UTF-8 theme file.")
                }
                params["documentText"] = .string(text)
            }
            flag("replace", "replace")
        case "theme.get", "theme.export", "theme.delete":
            set("id", "id"); set("id", "theme"); flag("resolved", "resolved")
            guard params["id"] != nil else { throw CLIFailure.arguments("--id is required.") }
        case "appearance.set": set("mode", "mode"); set("lightThemeId", "light-theme"); set("darkThemeId", "dark-theme")
        case "layout.export":
            if let windows = command.options["window"] { params["windowIds"] = .array(try windows.map { .string(try resolver.window($0).uuidString) }) }
        case "events.subscribe":
            params["topics"] = .array((command.value("topics") ?? "resources,selection,session").split(separator: ",").map { .string(String($0)) })
            if let resources = command.options["resource"] {
                guard resources.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw CLIFailure.arguments("--resource expects UUIDs.") }
                params["resourceIds"] = .array(resources.map(JSONValue.string))
            }
            try number("afterSequence", "after-sequence", integer: true)
            set("instanceId", "instance")
        default: break
        }
        return params
    }
}

/// Resolves explicit UUIDs directly, or exact names via list calls. A name
/// that matches several resources is an argument error, never a guess.
struct Resolver {
    let transport: CLITransport

    private func list(_ method: String, _ params: [String: JSONValue], key: String) throws -> [[String: JSONValue]] {
        let response = try transport.call(method, params)
        // A denied or failed lookup keeps its own status; it is not "no match".
        if response["error"] != nil { throw CLI.failure(from: response) }
        guard case .object(let result)? = response["result"], case .array(let items)? = result[key] else { return [] }
        return items.compactMap { if case .object(let item) = $0 { item } else { nil } }
    }

    private func match(_ name: String, in items: [[String: JSONValue]], field: String, kind: String) throws -> UUID {
        if let id = UUID(uuidString: name) { return id }
        let matches = items.filter { $0[field] == .string(name) }
        guard !matches.isEmpty else { throw CLIFailure(code: "NOT_FOUND", message: "No \(kind) is named \(name).", exitStatus: 3) }
        guard matches.count == 1, case .string(let raw)? = matches[0]["id"], let id = UUID(uuidString: raw) else {
            throw CLIFailure.arguments("\(matches.count) \(kind)s are named \(name). Use its UUID instead.")
        }
        return id
    }

    mutating func window(_ value: String) throws -> UUID {
        if let id = UUID(uuidString: value) { return id }
        return try match(value, in: try list("window.list", [:], key: "windows"), field: "name", kind: "window")
    }

    mutating func tab(_ value: String) throws -> UUID {
        if let id = UUID(uuidString: value) { return id }
        var tabs: [[String: JSONValue]] = []
        for window in try list("window.list", [:], key: "windows") {
            if let id = window["id"] { tabs += try list("tab.list", ["windowId": id], key: "tabs") }
        }
        return try match(value, in: tabs, field: "title", kind: "tab")
    }

    mutating func host(_ value: String) throws -> UUID {
        if let id = UUID(uuidString: value) { return id }
        return try match(value, in: try list("host.list", [:], key: "hosts"), field: "name", kind: "host")
    }
}

/// Blocking newline-framed JSON-RPC client over the owner-only Unix socket.
final class SocketTransport: CLITransport {
    private let fd: Int32
    private var buffer = Data()
    private var nextID = 0
    /// Notifications (e.g. replayed events) that arrived while awaiting a reply.
    private var pending: [[String: JSONValue]] = []
    /// A reply that never comes must not hang a script forever.
    static let replyTimeout = 120

    init(path: String) throws(CLIFailure) {
        guard (try? ControlEndpoint.verifySocket(path, uid: geteuid())) != nil else { throw CLIFailure.transport("The control socket is missing or unsafe.") }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIFailure.transport("Cannot create a socket.") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(fd); throw CLIFailure.transport("The socket path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else {
            Darwin.close(fd)
            throw CLIFailure.notRunning
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    func call(_ method: String, _ params: [String: JSONValue]) throws(CLIFailure) -> [String: JSONValue] {
        nextID += 1
        let id = nextID
        var data = Data(CLI.encode(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": .object(params)])).utf8)
        data.append(0x0A)
        setReceiveTimeout(Self.replyTimeout)
        guard writeAll(data) else { throw CLIFailure.transport("The connection closed while sending. The request may or may not have run; inspect state before retrying.") }
        while true {
            guard let message = try readMessage() else {
                throw CLIFailure.transport("The connection closed before a reply. The request may or may not have run; inspect state before retrying.")
            }
            if message["id"] == .number(Double(id)) { return message }
            // Notifications that arrive before the reply are kept for the event stream.
            if message["id"] == nil, message["method"] != nil { pending.append(message) }
        }
    }

    func nextNotification() throws(CLIFailure) -> [String: JSONValue]? {
        if !pending.isEmpty { return pending.removeFirst() }
        setReceiveTimeout(0)  // Event streams wait indefinitely.
        return try readMessage()
    }

    private func setReceiveTimeout(_ seconds: Int) {
        var value = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    func close() { Darwin.close(fd) }

    private func writeAll(_ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    private func readMessage() throws(CLIFailure) -> [String: JSONValue]? {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else {
                    throw CLIFailure.transport("The app sent a malformed reply.")
                }
                return object
            }
            guard buffer.count <= ControlFramer.maximumFrame else { throw CLIFailure.transport("The app sent an oversized reply.") }
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count < 0 {
                throw CLIFailure.transport(
                    errno == EAGAIN ? "No reply from the app in time. The request may or may not have run; inspect state before retrying." : "The connection failed while reading.")
            }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk.prefix(count))
        }
    }
}
