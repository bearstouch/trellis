import Darwin
import XCTest
@testable import TrellisCLI
@testable import TrellisControl
import TrellisCore
import TrellisRelease

/// Scripted transport: replies by method and records every call.
final class FakeTransport: CLITransport {
    var replies: [String: [String: JSONValue]] = [:]
    var calls: [(method: String, params: [String: JSONValue])] = []
    var failOn: String?
    var notifications: [[String: JSONValue]] = []
    /// Answers before `replies`, for replies that depend on the params (paging, lookups).
    var respond: ((String, [String: JSONValue]) -> [String: JSONValue]?)?
    func call(_ method: String, _ params: [String: JSONValue]) throws(CLIFailure) -> [String: JSONValue] {
        calls.append((method, params))
        if method == failOn { throw CLIFailure.transport("The connection closed before a reply. The request may or may not have run; inspect state before retrying.") }
        return respond?(method, params) ?? replies[method] ?? ["result": .object([:])]
    }
    func calls(_ method: String) -> [[String: JSONValue]] { calls.filter { $0.method == method }.map(\.params) }
    func nextNotification() throws(CLIFailure) -> [String: JSONValue]? { notifications.isEmpty ? nil : notifications.removeFirst() }
    func close() {}
}

final class CLIHarness {
    var out: [String] = [], err: [String] = []
    var launches = 0
    var launchedWith: URL?
    var stdinReads = 0
    var discovery: ControlDiscovery? = ControlDiscovery(protocolVersion: 2, instanceID: UUID(), socketPath: "/tmp/fake")
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
                if self.discoverAfterLaunch { self.discovery = ControlDiscovery(protocolVersion: 2, instanceID: UUID(), socketPath: "/tmp/fake") }
                return true
            },
            readStdinLine: {
                self.stdinReads += 1
                return self.stdinToken
            },
            readKeychain: { self.keychain[$0] },
            readFile: { _ in Data(#"{"version":3,"spaces":[]}"#.utf8) },
            stdout: { self.out.append($0) }, stderr: { self.err.append($0) }, sleep: { _ in },
            defaultStateDirectory: URL(fileURLWithPath: "/tmp/state"))
    }

    func run(_ arguments: [String]) -> Int32 { CLI.run(arguments, environment: environment) }
    var mutatingCalls: [String] { transport.calls.map(\.method).filter { MethodCatalogV2.isMutating($0) && $0 != "auth.authenticate" } }
    /// The last call's method and params, after the lookups it needed.
    var last: (method: String, params: [String: JSONValue])? { transport.calls.last }
}

final class CLITests: XCTestCase {
    private static func list(_ key: String, _ items: [[String: JSONValue]], next: String? = nil) -> [String: JSONValue] {
        var result: [String: JSONValue] = [key: .array(items.map(JSONValue.object))]
        if let next { result["nextCursor"] = .string(next) }
        return ["result": .object(result)]
    }

    private static func error(_ code: String, rpc: Int = -32000) -> [String: JSONValue] {
        ["error": .object(["code": .number(Double(rpc)), "message": .string("No."), "data": .object(["code": .string(code), "message": .string("No."), "retryable": .bool(false)])])]
    }

    func testParseAndRejectAmbiguousArguments() throws {
        let create = try CLIArguments.parse(["session", "start", "--pane", UUID().uuidString, "--process", "/bin/echo", "--arg", "a b", "--arg", "c", "--directory", "/tmp", "--json"])
        XCTAssertEqual(create.spec, "session.start")
        XCTAssertEqual(create.options["arg"], ["a b", "c"])
        XCTAssertTrue(create.has("json"))
        for bad in [
            ["space"], ["nope", "list"], ["space", "explode"], ["space", "list", "--bogus", "x"], ["space", "create", "--name"], ["layout", "apply"],
            ["space", "get", "--space", "a", "--space", "b"], ["space", "list", "stray"], ["space", "get"], ["remote", "helper"], ["remote", "helper", "explode"]
        ] {
            XCTAssertThrowsError(try CLIArguments.parse(bad), "\(bad)")
        }

        // Names resolve through the app's filtered list; two spaces sharing a name are an argument error and nothing mutates.
        let h = CLIHarness()
        h.transport.respond = { method, params in
            guard method == "space.list", case .string(let name)? = params["name"] else { return nil }
            let count = ["Dup": 2, "Solo": 1][name] ?? 0
            return Self.list("spaces", (0..<count).map { _ in ["id": .string(UUID().uuidString.lowercased()), "name": .string(name)] })
        }
        XCTAssertEqual(h.run(["space", "rename", "--space", "Dup", "--name", "New", "--token-stdin", "--json"]), 2)
        XCTAssertTrue(h.out.last?.contains("Use its ID") == true)
        XCTAssertEqual(h.mutatingCalls, [])
        XCTAssertEqual(h.run(["space", "rename", "--space", "Missing", "--name", "New", "--token-stdin"]), 3)
        XCTAssertEqual(h.mutatingCalls, [])
        XCTAssertEqual(h.run(["space", "rename", "--space", "Solo", "--name", "New", "--token-stdin"]), 0)
        XCTAssertEqual(h.mutatingCalls, ["space.update"])
        XCTAssertEqual(h.last?.params["name"], .string("New"))
        XCTAssertEqual(h.transport.calls("space.list").last, ["name": .string("Solo"), "limit": .number(500)], "Filtered by the app, not listed in full")

        // A denied lookup keeps its auth status instead of looking like "no match".
        let denied = CLIHarness()
        denied.transport.replies["space.list"] = Self.error("PERMISSION_DENIED")
        XCTAssertEqual(denied.run(["space", "rename", "--space", "Solo", "--name", "New", "--token-stdin"]), 4)
        XCTAssertEqual(denied.mutatingCalls, [])

        // Tabs resolve by title in each space; a title in two spaces is ambiguous. With --space only that space is asked.
        let tabs = CLIHarness()
        let w1 = UUID().uuidString.lowercased(), w2 = UUID().uuidString.lowercased()
        tabs.transport.replies["space.list"] = Self.list("spaces", [["id": .string(w1)], ["id": .string(w2)]])
        tabs.transport.replies["tab.list"] = Self.list("tabs", [["id": .string(UUID().uuidString), "title": .string("Server")]])
        XCTAssertEqual(tabs.run(["tab", "close", "--tab", "Server", "--token-stdin"]), 2)
        XCTAssertEqual(tabs.transport.calls("tab.list").map { $0["spaceId"] }, [.string(w1), .string(w2)])
        XCTAssertTrue(tabs.transport.calls("tab.list").allSatisfy { $0["title"] == .string("Server") })
        XCTAssertEqual(tabs.mutatingCalls, [])
        XCTAssertEqual(tabs.run(["tab", "close", "--tab", "Server", "--space", w2, "--token-stdin"]), 0)
        XCTAssertEqual(tabs.transport.calls("tab.list").last?["spaceId"], .string(w2))
        XCTAssertEqual(tabs.mutatingCalls, ["tab.close"])
    }

    func testNameResolutionFollowsCursorsAndMatchesExactly() {
        let h = CLIHarness()
        let id = UUID().uuidString.lowercased()
        h.transport.respond = { method, params in
            guard method == "host.list" else { return nil }
            // The query matches loosely; only an exact name counts, on whichever page it is.
            return params["cursor"] == nil
                ? Self.list("hosts", [["id": .string(UUID().uuidString), "name": .string("build-old")]], next: "c2")
                : Self.list("hosts", [["id": .string(id), "name": .string("build")]])
        }
        XCTAssertEqual(h.run(["remote", "status", "--host", "build", "--token-stdin"]), 0)
        XCTAssertEqual(h.transport.calls("host.list").map { $0["cursor"] }, [nil, .string("c2")])
        XCTAssertEqual(h.transport.calls("host.list").first?["query"], .string("build"))
        XCTAssertEqual(h.last?.method, "remote.status")
        XCTAssertEqual(h.last?.params, ["hostId": .string(id)])
    }

    func testTabColorAndTitleSendNullToClear() throws {
        let h = CLIHarness()
        let tab = UUID().uuidString.lowercased()
        XCTAssertEqual(h.run(["tab", "color", "--tab", tab, "--color", "purple", "--token-stdin"]), 0)
        XCTAssertEqual(h.run(["tab", "color", "--tab", tab, "--color", "none", "--token-stdin"]), 0)
        let updates = h.transport.calls("tab.update")
        XCTAssertEqual(updates.map { $0["color"] }, [.string("purple"), .null])
        XCTAssertTrue(updates.allSatisfy { $0["title"] == nil })
        XCTAssertEqual(h.run(["tab", "rename", "--tab", tab, "--automatic-title", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["id": .string(tab), "title": .null])
        XCTAssertEqual(h.run(["tab", "rename", "--tab", tab, "--token-stdin"]), 2, "A title or the automatic one")
        XCTAssertEqual(h.run(["tab", "duplicate", "--tab", tab, "--start", "--expected-revision", "3", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.method, "tab.duplicate")
        XCTAssertEqual(h.last?.params, ["id": .string(tab), "start": .bool(true), "expectedRevision": .number(3)])
    }

    func testEventStreamWritesSubscriptionFirstAndReportsClosure() throws {
        let h = CLIHarness()
        h.transport.replies["events.subscribe"] = ["result": .object(["subscriptionId": .string("S"), "sequence": .number(4), "instanceId": .string("I")])]
        h.transport.notifications = [["jsonrpc": .string("2.0"), "method": .string("events.event"), "params": .object(["sequence": .number(5)])]]
        XCTAssertEqual(h.run(["events", "subscribe", "--topics", "session", "--json", "--token-stdin"]), 7)
        XCTAssertEqual(h.out.count, 3)
        XCTAssertEqual(h.out[0], #"{"ok":true,"result":{"instanceId":"I","sequence":4,"subscriptionId":"S"}}"#)
        XCTAssertTrue(h.out[1].contains(#""method":"events.event""#))
        XCTAssertTrue(h.out[2].contains(#""ok":false"#) && h.out[2].contains("closed the event stream"))
        XCTAssertEqual(h.transport.calls("events.subscribe").count, 1, "Never resubscribed automatically")
        XCTAssertEqual(h.transport.calls("events.subscribe").first?["topics"], .array([.string("session")]))
        XCTAssertThrowsError(try CLIArguments.parse(["events", "subscribe", "--idempotency-key", "k"]))

        // Without --topics, both follow topics that exist in protocol 2.
        let defaults = CLIHarness()
        XCTAssertEqual(defaults.run(["events", "poll", "--token-stdin"]), 0)
        guard case .array(let topics)? = defaults.last?.params["topics"] else { return XCTFail("No topics") }
        XCTAssertEqual(topics, CLIParams.defaultTopics.map(JSONValue.string))
        XCTAssertTrue(CLIParams.defaultTopics.allSatisfy { EventTopicV2(rawValue: $0) != nil })
    }

    func testEventsPollSendsOnePollWithItsWait() {
        let h = CLIHarness()
        let space = UUID().uuidString.lowercased()
        h.transport.replies["events.poll"] = ["result": .object(["events": .array([]), "nextSequence": .number(9), "instanceId": .string("I")])]
        XCTAssertEqual(
            h.run([
                "events", "poll", "--topics", "agent,attention", "--space", space, "--after-sequence", "8", "--instance", "I", "--timeout-ms", "20000", "--limit", "10",
                "--token-stdin", "--json"
            ]), 0)
        XCTAssertEqual(h.transport.calls("events.poll").count, 1)
        XCTAssertEqual(
            h.last?.params,
            [
                "topics": .array([.string("agent"), .string("attention")]), "spaceIds": .array([.string(space)]), "afterSequence": .number(8), "instanceId": .string("I"),
                "timeoutMs": .number(20_000), "limit": .number(10)
            ])
        XCTAssertEqual(h.out, [#"{"ok":true,"result":{"events":[],"instanceId":"I","nextSequence":9}}"#])
        XCTAssertEqual(SocketTransport.replyTimeout("events.poll", ["timeoutMs": .number(25_000)]), SocketTransport.replyTimeout + 25)
        XCTAssertEqual(SocketTransport.replyTimeout("space.list", [:]), SocketTransport.replyTimeout)
        // Calls that wait on a host, the person or a setup outlast the setup's 15-minute bound; closing early would cancel them.
        XCTAssertEqual(SocketTransport.replyTimeout("project.launch", ["setup": .bool(true)]), SocketTransport.replyTimeout + 900)
        XCTAssertEqual(SocketTransport.replyTimeout("remote.reconnect", ["interactive": .bool(true)]), SocketTransport.replyTimeout + 900)
        XCTAssertEqual(SocketTransport.replyTimeout("project.launch", ["target": .object(["kind": .string("local")])]), SocketTransport.replyTimeout)
    }

    func testInvalidLayoutValidationIsSchemaError() throws {
        let h = CLIHarness()
        h.transport.replies["layout.validate"] = ["result": .object(["valid": .bool(false), "errors": .array([.string("e")]), "warnings": .array([])])]
        XCTAssertEqual(h.run(["layout", "validate", "./l.json", "--json", "--token-stdin"]), 2)
        XCTAssertTrue(h.out[0].contains("INVALID_LAYOUT") && h.out[0].contains(#""errors":["e"]"#))
        h.transport.replies["layout.validate"] = ["result": .object(["valid": .bool(true), "errors": .array([]), "warnings": .array([]), "version": .number(3)])]
        XCTAssertEqual(h.run(["layout", "validate", "./l.json", "--json", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["document": .object(["version": .number(3), "spaces": .array([])])])
        XCTAssertEqual(h.run(["layout", "apply", "./l.json", "--namespace", "dev", "--expected-revision", "12", "--start-new", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.method, "layout.apply")
        XCTAssertEqual(
            h.last?.params, ["document": .object(["version": .number(3), "spaces": .array([])]), "namespace": .string("dev"), "expectedRevision": .number(12), "startNew": .bool(true)])
        XCTAssertEqual(h.run(["layout", "apply", "./l.json", "--namespace", "dev", "--token-stdin"]), 2, "apply needs the plan's revision")
        let space = UUID().uuidString.lowercased()
        XCTAssertEqual(h.run(["layout", "export", "--space", space, "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["spaceIds": .array([.string(space)])])
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
            let reply = #"{"jsonrpc":"2.0","method":"events.event","params":{"sequence":1}}"# + "\n" + #"{"jsonrpc":"2.0","id":1,"result":{}}"# + "\n"
            _ = reply.withCString { write(client, $0, strlen($0)) }
            Darwin.close(client)
            served.fulfill()
        }
        let transport = try SocketTransport(path: path)
        defer { transport.close() }
        XCTAssertEqual(try transport.call("events.subscribe", [:])["result"], .object([:]))
        wait(for: [served], timeout: 5)
        XCTAssertEqual(try transport.nextNotification()?["method"], .string("events.event"))
        XCTAssertNil(try transport.nextNotification())
    }

    func testExitCodesComeFromTheErrorRegistry() throws {
        var cases: [(String?, Int, Int32)] = APIErrorCode.allCases.map { ($0.rawValue, -32000, $0.cliExitStatus) }
        cases += [("SOMETHING_NEW", -32000, 8), (nil, -32602, 2), (nil, -32600, 2), (nil, -32700, 2), (nil, -32601, 3), (nil, -32603, 8)]
        XCTAssertEqual(APIErrorCode.invalidState.cliExitStatus, 5)
        XCTAssertEqual(APIErrorCode.remoteDisconnected.cliExitStatus, 7)
        for (appCode, rpcCode, status) in cases {
            let h = CLIHarness()
            var error: [String: JSONValue] = ["code": .number(Double(rpcCode)), "message": .string("Something specific.")]
            if let appCode {
                error["data"] = .object([
                    "code": .string(appCode), "message": .string("Something specific."), "retryable": .bool(true), "details": .object(["state": .string("busy")])
                ])
            } else {
                error["data"] = .object(["fields": .object(["id": .string("UUID")])])
            }
            h.transport.replies["space.list"] = ["error": .object(error)]
            XCTAssertEqual(h.run(["space", "list", "--json", "--token-stdin"]), status, "\(appCode ?? String(rpcCode))")
            XCTAssertEqual(h.out.count, 1)
            XCTAssertEqual(h.err, [], "JSON mode keeps stderr for diagnostics only")
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(h.out[0].utf8)) as? [String: Any])
            XCTAssertEqual(Set(envelope.keys), ["ok", "error"])
            XCTAssertEqual(envelope["ok"] as? Bool, false)
            let body = try XCTUnwrap(envelope["error"] as? [String: Any])
            XCTAssertEqual(body["exitStatus"] as? Int, Int(status))
            XCTAssertEqual(body["message"] as? String, "Something specific.")
            if appCode != nil {
                XCTAssertEqual(body["code"] as? String, appCode)
                XCTAssertEqual(body["retryable"] as? Bool, true)
                XCTAssertEqual((body["details"] as? [String: Any])?["state"] as? String, "busy", "The error's details are kept")
            } else {
                XCTAssertNotNil((body["details"] as? [String: Any])?["fields"], "Field errors are kept")
            }
            XCTAssertFalse(h.out[0].contains("\u{1b}"), "No ANSI color in JSON")
        }

        let ok = CLIHarness()
        ok.transport.replies["space.list"] = ["result": .object(["spaces": .array([])])]
        XCTAssertEqual(ok.run(["space", "list", "--json", "--token-stdin"]), 0)
        XCTAssertEqual(ok.out, [#"{"ok":true,"result":{"spaces":[]}}"#])

        // Transport failure is status 7 and is never retried, even for execute.
        let lost = CLIHarness()
        lost.transport.failOn = "session.execute"
        XCTAssertEqual(lost.run(["session", "execute", "--session", UUID().uuidString, "--command", "make", "--json", "--token-stdin"]), 7)
        XCTAssertEqual(lost.transport.calls("session.execute").count, 1)
        XCTAssertTrue(lost.out[0].contains("may or may not have run"))

        // Plain mode: result on stdout, diagnostics on stderr, no color.
        let plain = CLIHarness()
        plain.transport.replies["space.list"] = Self.error("NOT_FOUND")
        XCTAssertEqual(plain.run(["space", "list", "--token-stdin"]), 3)
        XCTAssertEqual(plain.out, [])
        XCTAssertEqual(plain.err, ["trellis: No. (NOT_FOUND)"])
    }

    func testSpeaksOnlyProtocol2AndNamesTheFixForAnOutdatedPair() throws {
        let h = CLIHarness()
        XCTAssertEqual(h.run(["system", "info", "--token-stdin"]), 0)
        XCTAssertEqual(h.transport.calls.first?.method, "auth.authenticate")
        XCTAssertEqual(h.transport.calls.first?.params["protocolVersion"], .number(2))

        // An app publishing protocol 1 never gets the token.
        let old = CLIHarness()
        old.discovery = ControlDiscovery(protocolVersion: 1, instanceID: UUID(), socketPath: "/tmp/fake")
        XCTAssertEqual(old.run(["space", "list", "--token-stdin", "--json"]), APIErrorCode.unsupportedVersion.cliExitStatus)
        XCTAssertEqual(old.transport.calls.count, 0)
        XCTAssertTrue(old.out[0].contains("UNSUPPORTED_VERSION") && old.out[0].contains("trellis cli install-link"))

        // An app that refuses protocol 2 at authentication gets the same advice.
        let refused = CLIHarness()
        refused.transport.replies["auth.authenticate"] = Self.error("UNSUPPORTED_VERSION")
        XCTAssertEqual(refused.run(["space", "list", "--token-stdin"]), 2)
        XCTAssertTrue(refused.err[0].contains("install-link"))
        XCTAssertEqual(refused.transport.calls.map(\.method), ["auth.authenticate"])
    }

    func testExecuteWaitExitsWithTheCommandsExitCode() throws {
        let session = UUID().uuidString.lowercased()
        func run(_ result: [String: JSONValue], _ extra: [String] = []) -> (Int32, CLIHarness) {
            let h = CLIHarness()
            h.transport.replies["session.execute"] = ["result": .object(result)]
            return (h.run(["session", "execute", "--session", session, "--command", "swift test", "--wait"] + extra + ["--token-stdin", "--json"]), h)
        }
        let (failed, h) = run(["submitted": .bool(true), "timedOut": .bool(false), "exitCode": .number(3), "durationMs": .number(1200)], ["--timeout-ms", "60000"])
        XCTAssertEqual(failed, 3)
        XCTAssertEqual(
            h.last?.params, ["id": .string(session), "command": .string("swift test"), "wait": .object(["until": .string("finished"), "timeoutMs": .number(60_000)])])
        XCTAssertTrue(h.out[0].contains(#""ok":true"#) && h.out[0].contains(#""exitCode":3"#), "The result is printed, then the code is the exit status")
        XCTAssertEqual(run(["timedOut": .bool(false), "exitCode": .number(0)]).0, 0)
        XCTAssertEqual(run(["timedOut": .bool(false)]).0, 0, "A line that ran no command reports no code")
        let (timedOut, late) = run(["timedOut": .bool(true)])
        XCTAssertEqual(timedOut, 124)
        XCTAssertTrue(late.out[0].contains("TIMED_OUT"))
        XCTAssertEqual(run(["timedOut": .bool(false), "sessionEnded": .bool(true)]).0, 125)
        XCTAssertEqual(SocketTransport.replyTimeout("session.execute", ["wait": .object(["timeoutMs": .number(600_000)])]), SocketTransport.replyTimeout + 600)
        XCTAssertEqual(SocketTransport.replyTimeout("session.execute", ["wait": .object(["until": .string("finished")])]), SocketTransport.replyTimeout + 30)

        // Without --wait the line is only submitted, and --timeout-ms alone is a mistake.
        let submit = CLIHarness()
        submit.transport.replies["session.execute"] = ["result": .object(["submitted": .bool(true), "acceptedBytes": .number(5)])]
        XCTAssertEqual(submit.run(["session", "execute", "--session", session, "--command", "make", "--token-stdin"]), 0)
        XCTAssertEqual(submit.last?.params, ["id": .string(session), "command": .string("make")])
        XCTAssertEqual(submit.run(["session", "execute", "--session", session, "--command", "make", "--timeout-ms", "5", "--token-stdin"]), 2)
    }

    func testRemovedVersion1FormsAreRefusedWithTheirReplacement() {
        for (arguments, replacement) in [
            (["window", "list"], "use space"), (["tab", "list", "--window", "A"], "--space"), (["space", "focus", "--space", "A", "--activate"], "never had an effect"),
            (["session", "start", "--pane", UUID().uuidString, "--host-launch", "h"], "--ssh"), (["session", "execute", "--session", UUID().uuidString, "--command", "x", "--submit"], "always submits")
        ] {
            let h = CLIHarness()
            XCTAssertEqual(h.run(arguments + ["--token-stdin"]), 2, "\(arguments)")
            XCTAssertTrue(h.err.first?.contains(replacement) == true, "\(arguments): \(h.err)")
            XCTAssertEqual(h.transport.calls.count, 0)
        }
    }

    func testWorkspaceGrantAndSpaceCommands() {
        let h = CLIHarness()
        XCTAssertEqual(h.run(["workspace", "get", "--include", "tabs,panes", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.method, "workspace.get")
        XCTAssertEqual(h.last?.params, ["include": .array([.string("tabs"), .string("panes")])])
        XCTAssertEqual(h.run(["workspace", "save", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.method, "workspace.save")
        XCTAssertEqual(h.run(["grant", "get", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.method, "grant.get")
        XCTAssertEqual(h.run(["space", "create", "--name", "Build", "--start", "--idempotency-key", "k1", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["name": .string("Build"), "start": .bool(true), "idempotencyKey": .string("k1")])
        XCTAssertEqual(h.run(["space", "list", "--limit", "50", "--cursor", "c", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["limit": .number(50), "cursor": .string("c")])
        let id = UUID().uuidString
        XCTAssertEqual(h.run(["space", "close", "--space", id, "--allow-running", "--force", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["id": .string(id.lowercased()), "allowRunning": .bool(true), "force": .bool(true)], "A UUID is used as it is, lowercased")
    }

    func testPaneVerbsTakePane() {
        let h = CLIHarness()
        let pane = UUID().uuidString.lowercased(), tab = UUID().uuidString.lowercased()
        XCTAssertEqual(h.run(["pane", "split", "--pane", pane, "--axis", "y", "--ratio", "0.3", "--start", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.method, "pane.split")
        XCTAssertEqual(h.last?.params, ["id": .string(pane), "axis": .string("y"), "ratio": .number(0.3), "start": .bool(true)])
        XCTAssertEqual(h.run(["pane", "get", "--pane", pane, "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["id": .string(pane)])
        XCTAssertEqual(h.run(["pane", "maximize", "--pane", pane, "--restore", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["id": .string(pane), "maximized": .bool(false)])
        XCTAssertEqual(h.run(["pane", "list", "--tab", tab, "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["tabId": .string(tab)])
        XCTAssertEqual(h.run(["pane", "list", "--token-stdin"]), 2)
        XCTAssertEqual(h.run(["pane", "close", "--pane", "not-a-uuid", "--token-stdin"]), 2)
    }

    func testSessionLaunchesAndStop() {
        let h = CLIHarness()
        let pane = UUID().uuidString.lowercased(), host = UUID().uuidString.lowercased(), session = UUID().uuidString.lowercased()
        h.transport.replies["host.list"] = Self.list("hosts", [["id": .string(host), "name": .string("build")]])
        XCTAssertEqual(h.run(["session", "start", "--pane", pane, "--ssh", "build", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["paneId": .string(pane), "launch": .object(["kind": .string("ssh"), "hostId": .string(host)])])
        XCTAssertEqual(h.run(["session", "restart", "--pane", pane, "--shell", "--directory", "/tmp", "--env", "A=b=c", "--allow-running", "--token-stdin"]), 0)
        XCTAssertEqual(
            h.last?.params,
            [
                "paneId": .string(pane), "allowRunning": .bool(true),
                "launch": .object(["kind": .string("shell"), "directory": .string("/tmp"), "environment": .object(["A": .string("b=c")])])
            ])
        XCTAssertEqual(h.run(["session", "start", "--pane", pane, "--ssh", host, "--shell", "--token-stdin"]), 2, "One launch kind")
        XCTAssertEqual(h.run(["session", "start", "--pane", pane, "--env", "NOEQUALS", "--shell", "--token-stdin"]), 2)
        XCTAssertEqual(h.run(["session", "stop", "--session", session, "--force", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.method, "session.stop")
        XCTAssertEqual(h.last?.params, ["id": .string(session), "force": .bool(true)])
    }

    func testHostConnectTakesOnePlacement() {
        let h = CLIHarness()
        let host = UUID().uuidString.lowercased(), space = UUID().uuidString.lowercased(), pane = UUID().uuidString.lowercased()
        XCTAssertEqual(h.run(["host", "connect", "--host", host, "--space", space, "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["hostId": .string(host), "placement": .object(["kind": .string("tab"), "spaceId": .string(space)])])
        XCTAssertEqual(h.run(["host", "connect", "--host", host, "--split", pane, "--axis", "y", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params["placement"], .object(["kind": .string("split"), "paneId": .string(pane), "axis": .string("y")]))
        XCTAssertEqual(h.run(["host", "connect", "--host", host, "--new-space", "--name", "Build", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params["placement"], .object(["kind": .string("space"), "name": .string("Build")]))
        XCTAssertEqual(h.run(["host", "connect", "--host", host, "--token-stdin"]), 2)
        XCTAssertEqual(h.run(["host", "connect", "--host", host, "--space", space, "--new-space", "--token-stdin"]), 2)
        XCTAssertEqual(h.mutatingCalls, ["host.connect", "host.connect", "host.connect"])
        XCTAssertEqual(h.run(["host", "list", "--query", "build", "--tags", "linux,ci", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["query": .string("build"), "tags": .array([.string("linux"), .string("ci")])])
    }

    func testAgentCommandsResolveDefinitionsAndPlacements() {
        let h = CLIHarness()
        let space = UUID().uuidString.lowercased(), pane = UUID().uuidString.lowercased(), session = UUID().uuidString.lowercased()
        h.transport.respond = { method, params in
            guard method == "agent.get" else { return nil }
            return params["id"] == .string("trellis-claude-code") ? ["result": .object(["agent": .object([:])])] : Self.error("NOT_FOUND")
        }
        h.transport.replies["agent.list"] = Self.list("agents", [["id": .string("trellis-codex"), "name": .string("Codex")]])
        XCTAssertEqual(h.run(["agent", "start", "--agent", "trellis-claude-code", "--space", space, "--resume", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.method, "agent.start")
        XCTAssertEqual(
            h.last?.params, ["agentId": .string("trellis-claude-code"), "placement": .object(["kind": .string("tab"), "spaceId": .string(space)]), "resume": .bool(true)])
        XCTAssertEqual(h.run(["agent", "install", "--agent", "Codex", "--pane", pane, "--token-stdin"]), 0, "A name resolves through agent.list")
        XCTAssertEqual(h.last?.params, ["agentId": .string("trellis-codex"), "placement": .object(["kind": .string("pane"), "paneId": .string(pane)])])
        XCTAssertEqual(h.run(["agent", "start", "--agent", "Nobody", "--pane", pane, "--token-stdin"]), 3)
        XCTAssertEqual(h.run(["agent", "respond", "--session", session, "--action", "reply", "--text", "yes", "--expected-state", "needsInput", "--token-stdin"]), 0)
        XCTAssertEqual(
            h.last?.params, ["sessionId": .string(session), "action": .string("reply"), "text": .string("yes"), "expectedState": .string("needsInput")])
        XCTAssertEqual(h.run(["agent", "restart", "--session", session, "--resume", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["sessionId": .string(session), "resume": .bool(true)])
        XCTAssertEqual(h.run(["agent", "runs", "--state", "needsInput", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["state": .string("needsInput")])
        XCTAssertEqual(h.run(["agent", "list", "--machine", "local", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["machine": .object(["kind": .string("local")])])
    }

    func testRemoteCommandsIncludingHelperVerbs() throws {
        XCTAssertEqual(try CLIArguments.parse(["remote", "helper", "install", "--host", "h"]).spec, "remote.helper.install")
        XCTAssertEqual(try CLIArguments.parse(["remote", "helper", "remove", "--host", "h", "--stop-sessions"]).spec, "remote.helper.remove")
        let h = CLIHarness()
        let host = UUID().uuidString.lowercased()
        XCTAssertEqual(h.run(["remote", "open", "--host", host, "--name", "Box", "--start", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["hostId": .string(host), "name": .string("Box"), "start": .bool(true)])
        XCTAssertEqual(h.run(["remote", "reconnect", "--host", host, "--interactive", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["hostId": .string(host), "interactive": .bool(true)])
        XCTAssertEqual(h.run(["remote", "helper", "remove", "--host", host, "--stop-sessions", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.method, "remote.helper.remove")
        XCTAssertEqual(h.last?.params, ["hostId": .string(host), "stopSessions": .bool(true)])
    }

    func testProjectCommandsResolveProjectsAndTargets() {
        let h = CLIHarness()
        let project = UUID().uuidString.lowercased(), host = UUID().uuidString.lowercased()
        h.transport.replies["project.list"] = Self.list("projects", [["id": .string(project), "name": .string("Trellis")]])
        h.transport.replies["host.list"] = Self.list("hosts", [["id": .string(host), "name": .string("build")]])
        XCTAssertEqual(h.run(["project", "launch", "--project", "Trellis", "--target", "build", "--folder", "code/t", "--setup", "--expected-revision", "4", "--token-stdin"]), 0)
        XCTAssertEqual(h.transport.calls("project.list").first?["query"], .string("Trellis"))
        XCTAssertEqual(h.last?.method, "project.launch")
        XCTAssertEqual(
            h.last?.params,
            [
                "id": .string(project), "target": .object(["kind": .string("host"), "hostId": .string(host)]), "folder": .string("code/t"), "setup": .bool(true),
                "expectedRevision": .number(4)
            ])
        XCTAssertEqual(h.run(["project", "check", "--project", project, "--target", "local", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["id": .string(project), "target": .object(["kind": .string("local")])])
        XCTAssertEqual(h.run(["project", "create", "./p.json", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.method, "project.create")
        XCTAssertNotNil(h.last?.params["document"])
        let space = UUID().uuidString.lowercased()
        XCTAssertEqual(h.run(["project", "capture", "--space", space, "--name", "From space", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["spaceId": .string(space), "name": .string("From space")])
    }

    func testTaskCommandsTakeThePane() {
        let h = CLIHarness()
        let pane = UUID().uuidString.lowercased()
        XCTAssertEqual(h.run(["task", "run", "--pane", pane, "--task", "detected:swift: build", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.method, "task.run")
        XCTAssertEqual(h.last?.params, ["paneId": .string(pane), "taskId": .string("detected:swift: build")])
        XCTAssertEqual(h.run(["task", "stop", "--pane", pane, "--force", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["paneId": .string(pane), "force": .bool(true)])
        XCTAssertEqual(h.run(["task", "list", "--pane", pane, "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.method, "task.list")
    }

    func testLaunchOnlyWhenRequested() {
        let absent = CLIHarness()
        absent.discovery = nil
        XCTAssertEqual(absent.run(["space", "list", "--json", "--token-stdin"]), 7)
        XCTAssertTrue(absent.out[0].contains("APP_NOT_RUNNING"))
        XCTAssertEqual(absent.launches, 0)
        XCTAssertEqual(absent.transport.calls.count, 0)

        let launched = CLIHarness()
        launched.discovery = nil
        launched.discoverAfterLaunch = true
        XCTAssertEqual(launched.run(["space", "list", "--json", "--launch", "--token-stdin"]), 0)
        XCTAssertEqual(launched.launches, 1)
        XCTAssertNil(launched.launchedWith, "Default launches use the app's own state directory")
        let isolated = CLIHarness()
        isolated.discovery = nil
        isolated.discoverAfterLaunch = true
        XCTAssertEqual(isolated.run(["space", "list", "--launch", "--state-directory", "/tmp/dev-state", "--token-stdin"]), 0)
        XCTAssertEqual(isolated.launchedWith?.path, "/tmp/dev-state", "An explicit state directory is forwarded to the launched app")

        let running = CLIHarness()
        XCTAssertEqual(running.run(["space", "list", "--launch", "--token-stdin"]), 0)
        XCTAssertEqual(running.launches, 0, "An already running app is never relaunched")
    }

    func testCredentialsNeverInArgumentsOrLogs() throws {
        let secret = "trl_STDIN_SECRET_123"
        for flag in ["--token", "--password", "--secret"] {
            let h = CLIHarness()
            XCTAssertEqual(h.run(["space", "list", flag, secret, "--json"]), 2)
            XCTAssertTrue(h.out[0].contains("never accepted as arguments"))
            XCTAssertFalse((h.out + h.err).joined().contains(secret), "The rejected argument is not echoed")
            XCTAssertEqual(h.transport.calls.count, 0)
        }
        // Misplaced secrets are rejected without being echoed in any form.
        for arguments in [["--token=\(secret)"], ["--password=\(secret)"], ["--token-stdin", secret], ["--json=\(secret)"]] {
            let h = CLIHarness()
            XCTAssertEqual(h.run(["space", "list", "--json"] + arguments), 2, "\(arguments)")
            XCTAssertFalse((h.out + h.err).joined().contains(secret), "\(arguments)")
            XCTAssertEqual(h.transport.calls.count, 0)
        }

        // Stdin token: sent only inside auth.authenticate, never printed.
        let h = CLIHarness()
        h.transport.replies["auth.authenticate"] = Self.error("AUTH_REQUIRED")
        XCTAssertEqual(h.run(["space", "list", "--token-stdin", "--json"]), 4)
        XCTAssertEqual(h.transport.calls.first?.params["token"], .string(secret))
        XCTAssertFalse((h.out + h.err).joined().contains(secret))

        // Keychain reference: the token comes from the Keychain, the argument is only an ID.
        let grant = UUID()
        let keychained = CLIHarness()
        keychained.keychain[grant] = "trl_KEYCHAIN_SECRET_456"
        XCTAssertEqual(keychained.run(["space", "list", "--keychain-grant", grant.uuidString, "--json"]), 0)
        XCTAssertEqual(keychained.stdinReads, 0)
        XCTAssertEqual(keychained.transport.calls.first?.params["token"], .string("trl_KEYCHAIN_SECRET_456"))
        XCTAssertFalse((keychained.out + keychained.err).joined().contains("KEYCHAIN_SECRET"))
        XCTAssertEqual(keychained.run(["space", "list", "--keychain-grant", UUID().uuidString]), 4, "A missing Keychain item is an auth failure")
        XCTAssertEqual(CLIHarness().run(["space", "list"]), 2, "Credentials are required")
    }

    func testThemeAndAppearanceCommandsMapToTheAPI() {
        let h = CLIHarness()
        XCTAssertEqual(h.run(["appearance", "set", "--mode", "dark", "--dark-theme", "calm", "--expected-revision", "4", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.method, "appearance.set")
        XCTAssertEqual(h.last?.params, ["mode": .string("dark"), "darkThemeId": .string("calm"), "expectedRevision": .number(4)])
        XCTAssertEqual(h.run(["theme", "export", "--id", "calm", "--resolved", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["id": .string("calm"), "resolved": .bool(true)])
        XCTAssertEqual(h.run(["theme", "import", "theme.json", "--replace", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.method, "theme.import")
        XCTAssertEqual(h.last?.params["replace"], .bool(true))
        XCTAssertNotNil(h.last?.params["documentText"])
        XCTAssertEqual(h.run(["theme", "delete", "--token-stdin"]), 2, "--id is required")
        h.transport.replies["theme.validate"] = ["result": .object(["valid": .bool(false), "errors": .array([])])]
        XCTAssertEqual(h.run(["theme", "validate", "theme.json", "--token-stdin", "--json"]), 2, "An invalid theme is a schema error")
        XCTAssertTrue(h.out.last?.contains("INVALID_THEME") == true)
        XCTAssertEqual(h.run(["theme", "list", "--limit", "10", "--token-stdin"]), 0)
        XCTAssertEqual(h.last?.params, ["limit": .number(10)], "theme.list is paginated")
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

    func testCLILinkRefusesARelativeDirectoryThatDoesNotExist() {
        // Used to spin forever in the real path resolver, before any validation ran.
        let h = CLIHarness()
        var environment = h.environment
        var touched: [String] = []
        environment.home = "/Users/fixture"
        environment.executablePath = "/Applications/Trellis.app/Contents/Helpers/trellis"
        environment.createLink = { link, _ in touched.append(link) }
        environment.removeLink = { touched.append($0) }
        let directory = "no-such-dir-\(UUID().uuidString.prefix(8))/bin"
        for verb in ["install-link", "remove-link", "uninstall-plan"] {
            XCTAssertEqual(CLI.run(["cli", verb, "--dir", directory, "--json"], environment: environment), 2, verb)
        }
        XCTAssertEqual(touched, [])
        XCTAssertTrue(CLILinkEffects.live.resolvePath(directory).hasSuffix(directory), "The live resolver returns for a relative path too")
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
        XCTAssertEqual(CLI.run(["space", "list", "--json", "--token-stdin", "--state-directory", root.path], environment: environment), 0)
        XCTAssertEqual(out, [#"{"ok":true,"result":{"method":"space.list"}}"#])
        environment.readStdinLine = { "wrong" }
        XCTAssertEqual(CLI.run(["space", "list", "--json", "--token-stdin", "--state-directory", root.path], environment: environment), 4)
        server.stop()
        XCTAssertEqual(CLI.run(["space", "list", "--json", "--token-stdin", "--state-directory", root.path], environment: environment), 7)
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
