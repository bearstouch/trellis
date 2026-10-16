import Darwin
import XCTest
@testable import TrellisCLI
@testable import TrellisControl
import TrellisRelease

/// Scripted transport: replies by method and records every call.
final class FakeTransport: CLITransport {
    var replies: [String: [String: JSONValue]] = [:]
    var calls: [(method: String, params: [String: JSONValue])] = []
    var failOn: String?
    var notifications: [[String: JSONValue]] = []
    func call(_ method: String, _ params: [String: JSONValue]) throws(CLIFailure) -> [String: JSONValue] {
        calls.append((method, params))
        if method == failOn { throw CLIFailure.transport("The connection closed before a reply. The request may or may not have run; inspect state before retrying.") }
        return replies[method] ?? ["result": .object([:])]
    }
    func nextNotification() throws(CLIFailure) -> [String: JSONValue]? { notifications.isEmpty ? nil : notifications.removeFirst() }
    func close() {}
}

final class CLIHarness {
    var out: [String] = [], err: [String] = []
    var launches = 0
    var launchedWith: URL?
    var stdinReads = 0
    var discovery: ControlDiscovery? = ControlDiscovery(protocolVersion: 1, instanceID: UUID(), socketPath: "/tmp/fake")
    var discoverAfterLaunch = false
    var stdinToken: String? = "trl_STDIN_SECRET_123"
    var keychain: [UUID: String] = [:]
    let transport = FakeTransport()

    var environment: CLIEnvironment {
        CLIEnvironment(
            discover: { _ in self.discovery },
            connect: { _ throws(CLIFailure) in self.transport },
            launchApp: { stateDirectory in
                self.launchedWith = stateDirectory
                self.launches += 1
                if self.discoverAfterLaunch { self.discovery = ControlDiscovery(protocolVersion: 1, instanceID: UUID(), socketPath: "/tmp/fake") }
                return true
            },
            readStdinLine: {
                self.stdinReads += 1
                return self.stdinToken
            },
            readKeychain: { self.keychain[$0] },
            readFile: { _ in Data(#"{"version":1,"windows":[]}"#.utf8) },
            stdout: { self.out.append($0) }, stderr: { self.err.append($0) }, sleep: { _ in },
            defaultStateDirectory: URL(fileURLWithPath: "/tmp/state"))
    }

    func run(_ arguments: [String]) -> Int32 { CLI.run(arguments, environment: environment) }
    var mutatingCalls: [String] { transport.calls.map(\.method).filter { ControlMethods.isMutating($0) && $0 != "auth.authenticate" } }
}

final class CLITests: XCTestCase {
    func testParseAndRejectAmbiguousArguments() throws {
        let create = try CLIArguments.parse(["session", "start", "--pane", UUID().uuidString, "--process", "/bin/echo", "--arg", "a b", "--arg", "c", "--directory", "/tmp", "--json"])
        XCTAssertEqual(create.spec, "session.start")
        XCTAssertEqual(create.options["arg"], ["a b", "c"])
        XCTAssertTrue(create.has("json"))
        for bad in [
            ["window"], ["nope", "list"], ["window", "explode"], ["window", "list", "--bogus", "x"], ["window", "create", "--name"], ["layout", "apply"],
            ["window", "get", "--window", "a", "--window", "b"], ["window", "list", "stray"]
        ] {
            XCTAssertThrowsError(try CLIArguments.parse(bad), "\(bad)")
        }

        // Two windows share a name: resolving it is an argument error and nothing mutates.
        let h = CLIHarness()
        h.transport.replies["window.list"] = [
            "result": .object([
                "windows": .array([
                    .object(["id": .string(UUID().uuidString), "name": .string("Dup")]), .object(["id": .string(UUID().uuidString), "name": .string("Dup")]),
                    .object(["id": .string(UUID().uuidString), "name": .string("Solo")])
                ])
            ])
        ]
        XCTAssertEqual(h.run(["window", "rename", "--window", "Dup", "--name", "New", "--token-stdin", "--json"]), 2)
        XCTAssertTrue(h.out.last?.contains("Use its UUID") == true)
        XCTAssertEqual(h.mutatingCalls, [])
        XCTAssertEqual(h.run(["window", "rename", "--window", "Missing", "--name", "New", "--token-stdin"]), 3)
        XCTAssertEqual(h.mutatingCalls, [])
        XCTAssertEqual(h.run(["window", "rename", "--window", "Solo", "--name", "New", "--token-stdin"]), 0)
        XCTAssertEqual(h.mutatingCalls, ["window.update"])
        XCTAssertEqual(h.transport.calls.last?.params["name"], .string("New"))

        // A denied lookup keeps its auth status instead of looking like "no match".
        let denied = CLIHarness()
        denied.transport.replies["window.list"] = ["error": .object(["code": .number(-32000), "message": .string("Denied."), "data": .object(["code": .string("PERMISSION_DENIED")])])]
        XCTAssertEqual(denied.run(["window", "rename", "--window", "Solo", "--name", "New", "--token-stdin"]), 4)
        XCTAssertEqual(denied.mutatingCalls, [])

        // Tabs resolve across windows; a title in two windows is ambiguous.
        let tabs = CLIHarness()
        let w1 = UUID().uuidString, w2 = UUID().uuidString
        tabs.transport.replies["window.list"] = ["result": .object(["windows": .array([.object(["id": .string(w1)]), .object(["id": .string(w2)])])])]
        tabs.transport.replies["tab.list"] = ["result": .object(["tabs": .array([.object(["id": .string(UUID().uuidString), "title": .string("Server")])])])]
        XCTAssertEqual(tabs.run(["tab", "close", "--tab", "Server", "--token-stdin"]), 2)
        XCTAssertEqual(tabs.transport.calls.filter { $0.method == "tab.list" }.map { $0.params["windowId"] }, [.string(w1), .string(w2)])
        XCTAssertEqual(tabs.mutatingCalls, [])
    }

    func testEventStreamWritesSubscriptionFirstAndReportsClosure() throws {
        let h = CLIHarness()
        h.transport.replies["events.subscribe"] = ["result": .object(["subscriptionId": .string("S"), "sequence": .number(4), "instanceId": .string("I")])]
        h.transport.notifications = [["jsonrpc": .string("2.0"), "method": .string("event"), "params": .object(["sequence": .number(5)])]]
        XCTAssertEqual(h.run(["events", "subscribe", "--topics", "session", "--json", "--token-stdin"]), 7)
        XCTAssertEqual(h.out.count, 3)
        XCTAssertEqual(h.out[0], #"{"ok":true,"result":{"instanceId":"I","sequence":4,"subscriptionId":"S"}}"#)
        XCTAssertTrue(h.out[1].contains(#""method":"event""#))
        XCTAssertTrue(h.out[2].contains(#""ok":false"#) && h.out[2].contains("closed the event stream"))
        XCTAssertEqual(h.transport.calls.filter { $0.method == "events.subscribe" }.count, 1, "Never resubscribed automatically")
        XCTAssertThrowsError(try CLIArguments.parse(["events", "subscribe", "--idempotency-key", "k"]))
    }

    func testInvalidLayoutValidationIsSchemaError() throws {
        let h = CLIHarness()
        h.transport.replies["layout.validate"] = ["result": .object(["valid": .bool(false), "errors": .array([.string("e")]), "warnings": .array([])])]
        XCTAssertEqual(h.run(["layout", "validate", "./l.json", "--json", "--token-stdin"]), 2)
        XCTAssertTrue(h.out[0].contains("INVALID_LAYOUT") && h.out[0].contains(#""errors":["e"]"#))
        h.transport.replies["layout.validate"] = ["result": .object(["valid": .bool(true), "errors": .array([]), "warnings": .array([])])]
        XCTAssertEqual(h.run(["layout", "validate", "./l.json", "--json", "--token-stdin"]), 0)
    }

    /// Notifications that arrive before a reply (e.g. subscribe replay) are kept, not dropped.
    func testSocketTransportKeepsNotificationsReceivedBeforeReply() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tcls-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(mkdir(root.path, 0o700), 0)
        let path = root.appendingPathComponent("s").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(listener) }
        var address = try XCTUnwrap(ControlEndpoint.unixAddress(path))
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        let served = expectation(description: "served")
        Thread.detachNewThread {
            let client = accept(listener, nil, nil)
            var byte: UInt8 = 0
            while read(client, &byte, 1) == 1, byte != 0x0A {}
            let reply = #"{"jsonrpc":"2.0","method":"event","params":{"sequence":1}}"# + "\n" + #"{"jsonrpc":"2.0","id":1,"result":{}}"# + "\n"
            _ = reply.withCString { write(client, $0, strlen($0)) }
            Darwin.close(client)
            served.fulfill()
        }
        let transport = try SocketTransport(path: path)
        defer { transport.close() }
        XCTAssertEqual(try transport.call("events.subscribe", [:])["result"], .object([:]))
        wait(for: [served], timeout: 5)
        XCTAssertEqual(try transport.nextNotification()?["method"], .string("event"))
        XCTAssertNil(try transport.nextNotification())
    }

    func testJsonAndExitCodeMapping() throws {
        let cases: [(String?, Int, Int32)] = [
            ("NOT_FOUND", -32000, 3), ("AUTH_REQUIRED", -32000, 4), ("PERMISSION_DENIED", -32000, 4), ("CONFLICT", -32000, 5),
            ("CONFIRMATION_REQUIRED", -32000, 5), ("LAUNCH_FAILED", -32000, 6), ("INVALID_STATE", -32000, 8), ("LIMIT_EXCEEDED", -32000, 8),
            ("CLOSE_PENDING", -32000, 8), (nil, -32602, 2), (nil, -32601, 3), (nil, -32603, 8)
        ]
        for (appCode, rpcCode, status) in cases {
            let h = CLIHarness()
            var error: [String: JSONValue] = ["code": .number(Double(rpcCode)), "message": .string("Something specific.")]
            if let appCode { error["data"] = .object(["code": .string(appCode), "retryable": .bool(false)]) }
            h.transport.replies["window.list"] = ["error": .object(error)]
            XCTAssertEqual(h.run(["window", "list", "--json", "--token-stdin"]), status, "\(appCode ?? String(rpcCode))")
            XCTAssertEqual(h.out.count, 1)
            XCTAssertEqual(h.err, [], "JSON mode keeps stderr for diagnostics only")
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(h.out[0].utf8)) as? [String: Any])
            XCTAssertEqual(Set(envelope.keys), ["ok", "error"])
            XCTAssertEqual(envelope["ok"] as? Bool, false)
            let body = try XCTUnwrap(envelope["error"] as? [String: Any])
            XCTAssertEqual(body["exitStatus"] as? Int, Int(status))
            XCTAssertEqual(body["message"] as? String, "Something specific.")
            XCTAssertFalse(h.out[0].contains("\u{1b}"), "No ANSI color in JSON")
        }

        let ok = CLIHarness()
        ok.transport.replies["window.list"] = ["result": .object(["windows": .array([])])]
        XCTAssertEqual(ok.run(["window", "list", "--json", "--token-stdin"]), 0)
        XCTAssertEqual(ok.out, [#"{"ok":true,"result":{"windows":[]}}"#])

        // Transport failure is status 7 and is never retried, even for execute.
        let lost = CLIHarness()
        lost.transport.failOn = "session.execute"
        XCTAssertEqual(lost.run(["session", "execute", "--session", UUID().uuidString, "--command", "make", "--submit", "--json", "--token-stdin"]), 7)
        XCTAssertEqual(lost.transport.calls.filter { $0.method == "session.execute" }.count, 1)
        XCTAssertTrue(lost.out[0].contains("may or may not have run"))

        // Plain mode: result on stdout, diagnostics on stderr, no color.
        let plain = CLIHarness()
        plain.transport.replies["window.list"] = ["error": .object(["code": .number(-32000), "message": .string("Nope."), "data": .object(["code": .string("NOT_FOUND")])])]
        XCTAssertEqual(plain.run(["window", "list", "--token-stdin"]), 3)
        XCTAssertEqual(plain.out, [])
        XCTAssertEqual(plain.err, ["trellis: Nope. (NOT_FOUND)"])
    }

    func testLaunchOnlyWhenRequested() {
        let absent = CLIHarness()
        absent.discovery = nil
        XCTAssertEqual(absent.run(["window", "list", "--json", "--token-stdin"]), 7)
        XCTAssertTrue(absent.out[0].contains("APP_NOT_RUNNING"))
        XCTAssertEqual(absent.launches, 0)
        XCTAssertEqual(absent.transport.calls.count, 0)

        let launched = CLIHarness()
        launched.discovery = nil
        launched.discoverAfterLaunch = true
        XCTAssertEqual(launched.run(["window", "list", "--json", "--launch", "--token-stdin"]), 0)
        XCTAssertEqual(launched.launches, 1)
        XCTAssertNil(launched.launchedWith, "Default launches use the app's own state directory")
        let isolated = CLIHarness()
        isolated.discovery = nil
        isolated.discoverAfterLaunch = true
        XCTAssertEqual(isolated.run(["window", "list", "--launch", "--state-directory", "/tmp/dev-state", "--token-stdin"]), 0)
        XCTAssertEqual(isolated.launchedWith?.path, "/tmp/dev-state", "An explicit state directory is forwarded to the launched app")

        let running = CLIHarness()
        XCTAssertEqual(running.run(["window", "list", "--launch", "--token-stdin"]), 0)
        XCTAssertEqual(running.launches, 0, "An already running app is never relaunched")
    }

    func testCredentialsNeverInArgumentsOrLogs() throws {
        let secret = "trl_STDIN_SECRET_123"
        for flag in ["--token", "--password"] {
            let h = CLIHarness()
            XCTAssertEqual(h.run(["window", "list", flag, secret, "--json"]), 2)
            XCTAssertTrue(h.out[0].contains("never accepted as arguments"))
            XCTAssertFalse((h.out + h.err).joined().contains(secret), "The rejected argument is not echoed")
            XCTAssertEqual(h.transport.calls.count, 0)
        }
        // Misplaced secrets are rejected without being echoed in any form.
        for arguments in [["--token=\(secret)"], ["--password=\(secret)"], ["--token-stdin", secret], ["--json=\(secret)"]] {
            let h = CLIHarness()
            XCTAssertEqual(h.run(["window", "list", "--json"] + arguments), 2, "\(arguments)")
            XCTAssertFalse((h.out + h.err).joined().contains(secret), "\(arguments)")
            XCTAssertEqual(h.transport.calls.count, 0)
        }

        // Stdin token: sent only inside auth.authenticate, never printed.
        let h = CLIHarness()
        h.transport.replies["auth.authenticate"] = ["error": .object(["code": .number(-32000), "message": .string("Authentication failed."), "data": .object(["code": .string("AUTH_REQUIRED")])])]
        XCTAssertEqual(h.run(["window", "list", "--token-stdin", "--json"]), 4)
        XCTAssertEqual(h.transport.calls.first?.params["token"], .string(secret))
        XCTAssertFalse((h.out + h.err).joined().contains(secret))

        // Keychain reference: the token comes from the Keychain, the argument is only an ID.
        let grant = UUID()
        let keychained = CLIHarness()
        keychained.keychain[grant] = "trl_KEYCHAIN_SECRET_456"
        XCTAssertEqual(keychained.run(["window", "list", "--keychain-grant", grant.uuidString, "--json"]), 0)
        XCTAssertEqual(keychained.stdinReads, 0)
        XCTAssertEqual(keychained.transport.calls.first?.params["token"], .string("trl_KEYCHAIN_SECRET_456"))
        XCTAssertFalse((keychained.out + keychained.err).joined().contains("KEYCHAIN_SECRET"))
        XCTAssertEqual(keychained.run(["window", "list", "--keychain-grant", UUID().uuidString]), 4, "A missing Keychain item is an auth failure")
        XCTAssertEqual(CLIHarness().run(["window", "list"]), 2, "Credentials are required")
    }

    func testThemeAndAppearanceCommandsMapToTheAPI() {
        let h = CLIHarness()
        XCTAssertEqual(h.run(["appearance", "set", "--mode", "dark", "--dark-theme", "calm", "--expected-revision", "4", "--token-stdin"]), 0)
        XCTAssertEqual(h.transport.calls.last?.method, "appearance.set")
        XCTAssertEqual(h.transport.calls.last?.params, ["mode": .string("dark"), "darkThemeId": .string("calm"), "expectedRevision": .number(4)])
        XCTAssertEqual(h.run(["theme", "export", "--id", "calm", "--resolved", "--token-stdin"]), 0)
        XCTAssertEqual(h.transport.calls.last?.params, ["id": .string("calm"), "resolved": .bool(true)])
        XCTAssertEqual(h.run(["theme", "import", "theme.json", "--replace", "--token-stdin"]), 0)
        XCTAssertEqual(h.transport.calls.last?.method, "theme.import")
        XCTAssertEqual(h.transport.calls.last?.params["replace"], .bool(true))
        XCTAssertNotNil(h.transport.calls.last?.params["documentText"])
        XCTAssertEqual(h.run(["theme", "delete", "--token-stdin"]), 2, "--id is required")
        h.transport.replies["theme.validate"] = ["result": .object(["valid": .bool(false), "errors": .array([])])]
        XCTAssertEqual(h.run(["theme", "validate", "theme.json", "--token-stdin", "--json"]), 2, "An invalid theme is a schema error")
        XCTAssertTrue(h.out.last?.contains("INVALID_THEME") == true)
    }

    func testCLILinkCommandsAreExplicitAndUserLocal() {
        let h = CLIHarness()
        var created: [(String, String)] = [], removed: [String] = []
        var existing: CLILinkPlanner.Existing = .nothing
        var environment = h.environment
        environment.home = "/Users/fixture"
        environment.executablePath = "/Applications/Trellis.app/Contents/Helpers/trellis"
        environment.linkState = { _ in existing }
        environment.createLink = { created.append(($0, $1)) }
        environment.removeLink = { removed.append($0) }
        XCTAssertEqual(CLI.run(["cli", "install-link", "--json"], environment: environment), 0)
        XCTAssertEqual(created.map(\.0), ["/Users/fixture/.local/bin/trellis"])
        XCTAssertEqual(h.transport.calls.count, 0, "Local setup needs no app connection or credentials")
        existing = .otherFile
        XCTAssertEqual(CLI.run(["cli", "install-link", "--json"], environment: environment), 5, "An unrelated file is never overwritten")
        XCTAssertEqual(CLI.run(["cli", "install-link", "--dir", "/usr/local/bin", "--json"], environment: environment), 2)
        XCTAssertEqual(CLI.run(["cli", "remove-link", "--json"], environment: environment), 5)
        XCTAssertEqual(removed, [])
        existing = .symlink(to: "/Applications/Trellis.app/Contents/Helpers/trellis")
        XCTAssertEqual(CLI.run(["cli", "remove-link", "--json"], environment: environment), 0)
        XCTAssertEqual(removed, ["/Users/fixture/.local/bin/trellis"])
        environment.executablePath = "/usr/local/bin/trellis-cli"
        XCTAssertEqual(CLI.run(["cli", "install-link"], environment: environment), 2, "Only the app-bundled CLI links itself")
        XCTAssertEqual(CLI.run(["cli", "uninstall-plan", "--json"], environment: environment), 0)
        XCTAssertEqual(CLI.run(["cli", "uninstall-plan", "--dir", "~/.SSH", "--json"], environment: environment), 2)
    }

    func testCLILinkRefusesSymlinkedDirectoryOutsideHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tlink-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("bin"), withDestinationURL: outside)  // like ~/bin -> /usr/local/bin
        let h = CLIHarness()
        var environment = h.environment
        var created: [String] = []
        environment.home = home.path
        environment.executablePath = "/Applications/Trellis.app/Contents/Helpers/trellis"
        environment.createLink = { link, _ in created.append(link) }
        environment.removeLink = { created.append($0) }
        XCTAssertEqual(CLI.run(["cli", "install-link", "--dir", "~/bin", "--json"], environment: environment), 2)
        XCTAssertEqual(CLI.run(["cli", "remove-link", "--dir", "~/bin", "--json"], environment: environment), 2)
        XCTAssertEqual(created, [])
        XCTAssertEqual(CLI.run(["cli", "install-link", "--dir", "~/.local/bin", "--json"], environment: environment), 0)
        XCTAssertEqual(created, [home.path + "/.local/bin/trellis"])
        // The live remover unlinks, and never deletes a directory recursively.
        let directory = root.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertThrowsError(try CLIEnvironment.live.removeLink(directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRealSocketRoundTripThroughDiscovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tcli-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(mkdir(root.path, 0o700), 0)
        XCTAssertEqual(mkdir(root.appendingPathComponent("r").path, 0o700), 0)
        let server = ControlServer(endpoint: ControlEndpoint(stateDirectory: root, runtimeRoot: root.appendingPathComponent("r")), handler: EchoHandler())
        try server.start()
        defer { server.stop() }
        var environment = CLIEnvironment.live
        var out: [String] = [], err: [String] = []
        environment.stdout = { out.append($0) }
        environment.stderr = { err.append($0) }
        environment.readStdinLine = { "trl_TEST" }
        environment.launchApp = { _ in
            XCTFail("Must not launch"); return false
        }
        XCTAssertEqual(CLI.run(["window", "list", "--json", "--token-stdin", "--state-directory", root.path], environment: environment), 0)
        XCTAssertEqual(out, [#"{"ok":true,"result":{"method":"window.list"}}"#])
        environment.readStdinLine = { "wrong" }
        XCTAssertEqual(CLI.run(["window", "list", "--json", "--token-stdin", "--state-directory", root.path], environment: environment), 4)
        server.stop()
        XCTAssertEqual(CLI.run(["window", "list", "--json", "--token-stdin", "--state-directory", root.path], environment: environment), 7)
    }
}

final class EchoHandler: ControlHandler, @unchecked Sendable {
    func authenticate(_ params: JSONValue?, connectionID: UUID, peerUID: uid_t) async -> Result<(ControlIdentity, JSONValue), ControlError> {
        params?["token"] == .string("trl_TEST") ? .success((ControlIdentity(connectionID: connectionID, peerUID: peerUID), .object([:]))) : .failure(.authenticationFailed)
    }
    func dispatch(_ method: String, params: JSONValue?, identity: ControlIdentity) async -> Result<JSONValue, ControlError> {
        .success(.object(["method": .string(method)]))
    }
}
