import Darwin
import Foundation
import Security
import TrellisControl
import TrellisCore
import TrellisRelease

/// A failure with the documented exit status: application codes map through the error registry
/// (`APIErrorCode.cliExitStatus`), local failures use the same numbers.
public struct CLIFailure: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public let exitStatus: Int32
    public var details: JSONValue?
    public var retryable: Bool?

    static func arguments(_ message: String) -> Self { Self(code: "INVALID_ARGUMENTS", message: message, exitStatus: 2) }
    static let notRunning = Self(code: "APP_NOT_RUNNING", message: "Trellis is not running. Start it, or pass --launch to start it.", exitStatus: 7)
    static func transport(_ message: String) -> Self { Self(code: "TRANSPORT", message: message, exitStatus: 7) }
    /// The running app speaks another protocol than this binary (an older app, or this is an older `trellis`).
    static let otherProtocol = Self(
        code: APIErrorCode.unsupportedVersion.rawValue,
        message:
            "The running Trellis speaks another automation protocol than this trellis command (protocol \(ControlDiscovery.currentProtocolVersion)). Update Trellis, or use the trellis inside the running Trellis.app: run its 'trellis cli install-link' to re-link it.",
        exitStatus: APIErrorCode.unsupportedVersion.cliExitStatus)

    init(code: String, message: String, exitStatus: Int32, details: JSONValue? = nil) {
        self.code = code; self.message = message; self.exitStatus = exitStatus; self.details = details
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
    public var resolvePath: (String) -> String = CLILinkEffects.live.resolvePath
    public var linkState: (String) -> CLILinkPlanner.Existing = CLILinkEffects.live.linkState
    public var createLink: (String, String) throws -> Void = CLILinkEffects.live.createLink
    public var removeLink: (String) throws -> Void = CLILinkEffects.live.removeLink

    public static var live: CLIEnvironment {
        CLIEnvironment(
            discover: { ControlEndpoint(stateDirectory: $0).readDiscovery() },
            connect: { path throws(CLIFailure) in try SocketTransport(path: path) },
            launchApp: { stateDirectory in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                // A normal native launch; an explicit state directory is forwarded unchanged.
                process.arguments = ["-b", "com.bearstouch.trellis"] + (stateDirectory.map { ["--args", "--state-directory", $0.path] } ?? [])
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
            defaultStateDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.bearstouch.trellis", isDirectory: true))
    }
}

public enum CLI {
    /// Runs one invocation and returns the process exit status. Never retries.
    public static func run(_ arguments: [String], environment: CLIEnvironment) -> Int32 {
        let json = arguments.contains("--json")
        do {
            let request: CLIRequest
            do { request = try CLIArguments.request(arguments) } catch { throw CLIFailure.arguments(Self.message(error)) }
            switch request {
            case .help(let noun, let verb):
                let text = CLIHelp.text(noun: noun, verb: verb)
                environment.stdout(json ? encode(.object(["ok": .bool(true), "result": .object(["help": .string(text)])])) : text)
            case .version: environment.stdout(json ? encode(.object(["ok": .bool(true), "result": .object(["version": .string(AppVersion.current)])])) : CLIHelp.version)
            case .run(let command):
                let (result, status) = try execute(command, environment)
                emit(.object(["ok": .bool(true), "result": result]), json: json, environment: environment)
                return status
            }
            return 0
        } catch let failure as CLIFailure {
            var error: [String: JSONValue] = ["code": .string(failure.code), "message": .string(failure.message), "exitStatus": .number(Double(failure.exitStatus))]
            if let retryable = failure.retryable { error["retryable"] = .bool(retryable) }
            if let details = failure.details { error["details"] = details }
            if json {
                environment.stdout(encode(.object(["ok": .bool(false), "error": .object(error)])))
            } else {
                environment.stderr("trellis: \(failure.message) (\(failure.code))")
                // Also for argument errors found after parsing: missing credentials, or a required option left out.
                if failure.code == "INVALID_ARGUMENTS" { environment.stderr(CLIHelp.hint(arguments)) }
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

    /// The result and the exit status: 0, or with `session execute --wait` the command's own exit code.
    private static func execute(_ command: ParsedCommand, _ environment: CLIEnvironment) throws -> (JSONValue, Int32) {
        if command.noun == "cli" { return (try local(command, environment), 0) }
        let token = try credential(command, environment)
        let stateDirectory = command.value("state-directory").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? environment.defaultStateDirectory
        let transport = try connect(stateDirectory, explicit: command.value("state-directory") != nil, launch: command.has("launch"), environment)
        defer { transport.close() }
        let auth = try transport.call("auth.authenticate", ["protocolVersion": .number(Double(ControlDiscovery.currentProtocolVersion)), "token": .string(token)])
        if auth["error"] != nil {
            let failure = failure(from: auth)
            throw failure.code == APIErrorCode.unsupportedVersion.rawValue ? CLIFailure.otherProtocol : failure
        }
        var resolver = Resolver(transport: transport)
        let params = try CLIParams.build(command, &resolver, environment)
        if command.spec == "events.subscribe" { try stream(command, params, transport, environment) }
        let response = try transport.call(command.spec, params)
        if response["error"] != nil { throw failure(from: response) }
        let result = response["result"] ?? .null
        // An invalid document is a schema error (exit 2), with the issues as details.
        if ["layout.validate", "theme.validate"].contains(command.spec), result["valid"] == .bool(false) {
            let kind = command.spec == "theme.validate" ? "THEME" : "LAYOUT"
            throw CLIFailure(code: "INVALID_\(kind)", message: "The \(kind.lowercased()) document is invalid.", exitStatus: 2, details: result)
        }
        if command.spec == "session.execute", command.has("wait") { return (result, try waitStatus(result)) }
        return (result, 0)
    }

    /// `session execute --wait` exits with the command's exit code. A wait that ended first (the command keeps running) is
    /// 124, as timeout(1) does; a session that ended before the command finished is 125.
    static func waitStatus(_ result: JSONValue) throws -> Int32 {
        if result["timedOut"] == .bool(true) {
            throw CLIFailure(code: "TIMED_OUT", message: "The wait ended before the command finished; it keeps running.", exitStatus: 124, details: result)
        }
        if result["sessionEnded"] == .bool(true) {
            throw CLIFailure(code: "SESSION_ENDED", message: "The session ended before the command finished.", exitStatus: 125, details: result)
        }
        guard case .number(let code)? = result["exitCode"] else { return 0 }
        return (0...255).contains(code) && code.rounded() == code ? Int32(code) : 1
    }

    /// Explicit, user-invoked setup. Only one symlink in a user-local directory is
    /// ever created or removed; shell startup files are never edited.
    private static func local(_ command: ParsedCommand, _ environment: CLIEnvironment) throws -> JSONValue {
        let directory = command.value("dir") ?? CLILinkInstaller.defaultDirectory
        let effects = CLILinkEffects(resolvePath: environment.resolvePath, linkState: environment.linkState, createLink: environment.createLink, removeLink: environment.removeLink, isExecutable: { _ in false })
        if let problem = CLILinkInstaller.directoryProblem(directory: directory, home: environment.home, effects: effects) { throw CLIFailure.arguments(problem) }
        switch command.verb {
        case "install-link":
            let cli = environment.executablePath
            guard cli.hasSuffix(CLILinkInstaller.bundledCLISuffix) else {
                throw CLIFailure.arguments("Run install-link from the trellis inside Trellis.app (Trellis.app/Contents/Helpers/trellis).")
            }
            let path: String
            switch try CLILinkInstaller.install(directory: directory, home: environment.home, cliPath: cli, effects: effects) {
            case .installed(let link), .replaced(let link), .alreadyInstalled(let link): path = link
            case .invalidDirectory(let reason): throw CLIFailure.arguments(reason)
            case .conflict(let reason): throw CLIFailure(code: "CONFLICT", message: reason, exitStatus: 5)
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
                "first": .string(UninstallPlanner.firstStep),
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
        // An app that publishes another protocol never gets the token.
        func reach(_ discovery: ControlDiscovery?) throws(CLIFailure) -> CLITransport? {
            guard let discovery else { return nil }
            guard discovery.protocolVersion == ControlDiscovery.currentProtocolVersion else { throw CLIFailure.otherProtocol }
            return try? environment.connect(discovery.socketPath)
        }
        if let transport = try reach(environment.discover(stateDirectory)) { return transport }
        guard launch else { throw CLIFailure.notRunning }
        guard environment.launchApp(explicit ? stateDirectory : nil) else { throw CLIFailure.transport("Trellis could not be launched.") }
        for _ in 0..<50 {
            environment.sleep(0.2)
            if let transport = try reach(environment.discover(stateDirectory)) { return transport }
        }
        throw CLIFailure.transport("Trellis was launched but its control socket did not appear.")
    }

    /// Application errors carry `data: {code, message, retryable, details?}`; JSON-RPC errors their fields in `data`.
    static func failure(from response: [String: JSONValue]) -> CLIFailure {
        guard case .object(let error)? = response["error"] else { return CLIFailure(code: "INTERNAL", message: "Malformed response.", exitStatus: 8) }
        let rpcCode: Int = if case .number(let value)? = error["code"] { Int(value) } else { -32603 }
        let message: String = if case .string(let text)? = error["message"] { text } else { "The request failed." }
        var appCode: String?
        if case .string(let code)? = error["data"]?["code"] { appCode = code }
        var failure = CLIFailure(
            code: appCode ?? (rpcCode == -32602 ? "INVALID_PARAMS" : rpcCode == -32601 ? "METHOD_NOT_FOUND" : "PROTOCOL_ERROR"), message: message,
            exitStatus: APIErrorCode.cliExitStatus(appCode: appCode, rpcCode: rpcCode))
        if appCode != nil {
            failure.details = error["data"]?["details"]
            if case .bool(let retryable)? = error["data"]?["retryable"] { failure.retryable = retryable }
        } else {
            failure.details = error["data"]
        }
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
        throw CLIFailure.transport("The app closed the event stream. Subscribe again with --instance and --after-sequence to resume.")
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

    /// A call that waits on the server (`session.execute` with `wait`, `events.poll`) gets its own wait plus the usual margin.
    /// One that waits on a host, the person or a project's setup (`MethodSpecV2.waits`) gets the setup's 15-minute bound:
    /// timing out closes the connection, which cancels the call (and a running setup) in the app.
    static func replyTimeout(_ method: String, _ params: [String: JSONValue]) -> Int {
        let waited: JSONValue? = method == "session.execute" ? params["wait"]?["timeoutMs"] ?? params["wait"].map { _ in .number(30_000) } : method == "events.poll" ? params["timeoutMs"] : nil
        if case .number(let milliseconds)? = waited, milliseconds.isFinite, milliseconds > 0 { return replyTimeout + Int(min(milliseconds, 3_600_000) / 1_000) }
        if MethodCatalogV2.spec(method)?.waits(for: params) == true { return replyTimeout + 900 }
        return replyTimeout
    }

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
        setReceiveTimeout(Self.replyTimeout(method, params))
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
