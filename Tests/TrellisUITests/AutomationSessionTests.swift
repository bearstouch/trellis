import AppKit
import Darwin
import XCTest
import TrellisControl
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

final class AutomationSessionTests: XCTestCase {
    /// Prints each received byte as hex so tests can assert exact input.
    static let byteEcho = #"stty raw -echo; printf 'READY\n'; exec /usr/bin/perl -e '$|=1; binmode STDIN; while (sysread(STDIN, $b, 1)) { printf "%02x ", ord $b }'"#

    @MainActor
    private func liveWindow(_ h: Harness, script: String = byteEcho) async throws -> (window: String, pane: UUID, terminal: NativeTerminalHandle) {
        let window: String = try await h.value("windowId", "window.create", ["name": "Live"])
        let pane = try XCTUnwrap(h.model.presentation.activePane?.id)
        _ = try await h.model.service.execute(.configureStoppedSession(paneID: pane, launch: .process(executable: "/bin/zsh", arguments: ["-f", "-c", script], directory: "/tmp")))
        await h.model.refresh()
        let started = try await h.code("session.start", ["paneId": pane.uuidString])
        XCTAssertEqual(started, "OK")
        let terminal = NativeTerminalHandle(try XCTUnwrap(h.model.terminals[pane]))
        try await terminal.waitFor("READY")
        return (window, pane, terminal)
    }

    @MainActor
    func testS024_UT01_rejectUnapprovedLaunchDescriptor() async throws {
        let h = try Harness()
        try await h.grant("full")
        try await h.grant("starter", [.metadataRead, .sessionStart], scope: .all)
        defer {
            h.model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        _ = try await h.code("window.create", ["name": "W"])
        let pane = try XCTUnwrap(h.model.presentation.activePane?.id)
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-s024-\(UUID().uuidString)").path
        let arbitrary: [String: Any] = ["kind": "process", "executable": "/usr/bin/touch", "arguments": [marker], "directory": "/tmp"]
        let codes = [
            try await h.code("session.start", ["paneId": pane.uuidString, "launch": arbitrary], as: "starter"),
            try await h.code("session.start", ["paneId": pane.uuidString, "launch": ["kind": "shell", "directory": "/tmp"]], as: "starter"),
            try await h.code("session.start", ["paneId": pane.uuidString, "launch": ["kind": "host", "hostId": UUID().uuidString, "environment": ["A": "1"]]], as: "starter"),
            try await h.code("session.restart", ["paneId": pane.uuidString, "launch": arbitrary], as: "starter")
        ]
        XCTAssertEqual(codes, ["PERMISSION_DENIED", "PERMISSION_DENIED", "PERMISSION_DENIED", "PERMISSION_DENIED"])
        let unknownHost = try await h.code("session.start", ["paneId": pane.uuidString, "launch": ["kind": "host", "hostId": UUID().uuidString]], as: "starter")
        XCTAssertEqual(unknownHost, "NOT_FOUND")
        // Reserved control variables are rejected even for execute grants.
        let reserved = try await h.call("session.start", ["paneId": pane.uuidString, "launch": arbitrary.merging(["environment": ["TRELLIS_TOKEN": "x"]]) { $1 }])
        XCTAssertEqual((reserved["error"] as? [String: Any])?["code"] as? Int, -32602)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "Nothing was spawned")
        XCTAssertEqual(h.model.terminals[pane]?.sessionState, .stopped)

        // The pane's own approved descriptor starts with session.start alone.
        _ = try await h.model.service.execute(.configureStoppedSession(paneID: pane, launch: .process(executable: "/bin/sleep", arguments: ["30"], directory: "/tmp")))
        await h.model.refresh()
        let started = try result(try await h.call("session.start", ["paneId": pane.uuidString], as: "starter"))
        XCTAssertEqual((started["session"] as? [String: Any])?["state"] as? String, "running")
        XCTAssertNil((started["session"] as? [String: Any])?["executable"], "Launch details stay redacted without execute")

        // A failed arbitrary launch returns LAUNCH_FAILED with the failed record.
        _ = try await h.code("window.create", ["name": "Fail"])
        let failPane = try XCTUnwrap(h.model.presentation.activePane?.id)
        let failed = try await h.call(
            "session.start", ["paneId": failPane.uuidString, "launch": ["kind": "process", "executable": "/nonexistent/tool", "directory": "/tmp"]])
        XCTAssertEqual(errorCode(failed), "LAUNCH_FAILED")
        XCTAssertEqual(
            ((((failed["error"] as? [String: Any])?["data"] as? [String: Any])?["session"]) as? [String: Any])?["state"] as? String, "failed")
    }

    @MainActor
    func testS024_UT02_validateInputEncodingAndLimit() async throws {
        let h = try Harness()
        try await h.grant("full")
        let live = try await liveWindow(h, script: "stty raw -echo; printf 'READY\\n'; exec /bin/cat > /dev/null")
        defer { live.terminal.close() }
        let id = live.terminal.native.sessionID.uuidString
        let fill = Data(repeating: 0x61, count: 65_536)
        let both = try await h.call("session.sendInput", ["id": id, "text": "a", "base64": "YQ=="])
        let neither = try await h.call("session.sendInput", ["id": id])
        let invalid = try await h.call("session.sendInput", ["id": id, "base64": "@@@@"])
        let badMode = try await h.call("session.sendInput", ["id": id, "text": "a", "mode": "shell"])
        let escape = try await h.call("session.sendInput", ["id": id, "text": "x\u{1b}[201~rm -rf ~\r", "mode": "paste"])
        for response in [both, neither, invalid, badMode, escape] {
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602, "\(response)")
        }
        let exact = try result(try await h.call("session.sendInput", ["id": id, "base64": fill.base64EncodedString()]))
        XCTAssertEqual(exact["acceptedBytes"] as? Int, 65_536)
        let over = try await h.code("session.sendInput", ["id": id, "base64": (fill + Data([0x61])).base64EncodedString()])
        XCTAssertEqual(over, "LIMIT_EXCEEDED")
        let overText = try await h.code("session.sendInput", ["id": id, "text": String(repeating: "b", count: 65_537)])
        XCTAssertEqual(overText, "LIMIT_EXCEEDED")
        let pasted = try result(try await h.call("session.sendInput", ["id": id, "text": "line one\nline two", "mode": "paste"]))
        XCTAssertEqual(pasted["mode"] as? String, "paste")

        live.terminal.native.requestTermination(force: true)
        try await live.terminal.waitUntil { !live.terminal.native.isRunning }
        let stopped = try await h.code("session.sendInput", ["id": id, "text": "a"])
        XCTAssertEqual(stopped, "INVALID_STATE")
    }

    @MainActor
    func testS024_UT03_executeRequiresSubmit() async throws {
        let h = try Harness()
        try await h.grant("full")
        try await h.grant("input", [.metadataRead, .sessionInput])
        let live = try await liveWindow(h)
        defer { live.terminal.close() }
        let id = live.terminal.native.sessionID.uuidString
        let missing = try await h.call("session.execute", ["id": id, "command": "ls"])
        let disabled = try await h.call("session.execute", ["id": id, "command": "ls", "submit": false])
        let multiline = try await h.call("session.execute", ["id": id, "command": "ls\nrm -rf ~", "submit": true])
        for response in [missing, disabled, multiline] { XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602) }
        let inputOnly = try await h.code("session.execute", ["id": id, "command": "ls", "submit": true], as: "input")
        XCTAssertEqual(inputOnly, "PERMISSION_DENIED", "Input capability does not imply execute")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try live.terminal.output().trimmingCharacters(in: .whitespacesAndNewlines), "READY", "Rejected calls sent zero bytes")

        let accepted = try result(try await h.call("session.execute", ["id": id, "command": "ls", "submit": true]))
        XCTAssertEqual(accepted["acceptedBytes"] as? Int, 3)
        try await live.terminal.waitFor("6c 73 0d")
        let received = try live.terminal.output().replacingOccurrences(of: "READY", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(received, "6c 73 0d", "Exactly the command plus one carriage return")
    }

    @MainActor
    func testS024_UT04_disconnectDoesNotReplayOrClose() async throws {
        let h = try Harness()
        try await h.grant("full")
        let token = try await h.grants.create(name: "socket", capabilities: Set(Capability.allCases), windowScope: .all, hostScope: .all, lifetime: 600).token
        let live = try await liveWindow(h)
        defer { live.terminal.close() }
        let sessionID = live.terminal.native.sessionID
        let pid = live.terminal.native.processID
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ts-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(mkdir(root.path, 0o700), 0)
        XCTAssertEqual(mkdir(root.appendingPathComponent("r").path, 0o700), 0)
        let server = ControlServer(endpoint: ControlEndpoint(stateDirectory: root, runtimeRoot: root.appendingPathComponent("r")), handler: h.handler)
        let discovery = try server.start()
        defer { server.stop() }
        let path = discovery.socketPath
        try await Task.detached {
            let client = try BlockingClient(path: path)
            _ = try client.request(#"{"jsonrpc":"2.0","id":1,"method":"auth.authenticate","params":{"protocolVersion":1,"token":"\#(token)"}}"#)
            client.send(#"{"jsonrpc":"2.0","id":2,"method":"session.execute","params":{"id":"\#(sessionID.uuidString)","command":"x","submit":true}}"# + "\n")
            client.close()  // Disconnect without reading the reply.
        }.value
        try await live.terminal.waitFor("78 0d")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(try live.terminal.output().components(separatedBy: "78 0d").count - 1, 1, "No automatic re-send")
        XCTAssertTrue(live.terminal.native.isRunning, "The session keeps running after the client disconnects")
        XCTAssertEqual(live.terminal.native.processID, pid)
        XCTAssertEqual(h.model.snapshot.panes[live.pane]?.sessionID, sessionID, "No restart")
    }

    @MainActor
    func testUndeliveredAutomationInputNeverAlerts() async throws {
        let h = try Harness()
        try await h.grant("full")
        // The process never reads, so most of the input is still queued when it exits.
        let live = try await liveWindow(h, script: "stty raw -echo; printf 'READY\\n'; exec /bin/sleep 1")
        defer { live.terminal.close() }
        let accepted = try result(
            try await h.call("session.sendInput", ["id": live.terminal.native.sessionID.uuidString, "base64": Data(repeating: 0x61, count: 65_536).base64EncodedString()]))
        XCTAssertEqual(accepted["acceptedBytes"] as? Int, 65_536)
        try await live.terminal.waitUntil { live.terminal.native.sessionState == .exited }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(h.model.errorMessage, "API input must not present a blocking alert")
    }

    @MainActor
    func testRestartNeedsAllowRunningAndHostConnectStaysInScope() async throws {
        let h = try Harness()
        try await h.grant("full")
        let live = try await liveWindow(h)
        defer {
            h.model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        let oldSession = live.terminal.native.sessionID
        let unconfirmed = try await h.code("session.restart", ["paneId": live.pane.uuidString])
        XCTAssertEqual(unconfirmed, "CONFIRMATION_REQUIRED")
        XCTAssertTrue(live.terminal.native.isRunning)
        let restarted = try result(try await h.call("session.restart", ["paneId": live.pane.uuidString, "allowRunning": true]))
        let newSession = try XCTUnwrap((restarted["session"] as? [String: Any])?["id"] as? String)
        XCTAssertNotEqual(newSession, oldSession.uuidString)
        XCTAssertFalse(live.terminal.native.isRunning)
        XCTAssertEqual(h.model.terminals[live.pane]?.sessionState, .running)

        // host.connect uses the saved host and stays inside the authorized window.
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent("fake-ssh-\(UUID().uuidString)")
        try Data("#!/bin/sh\nprintf 'FAKE-SSH %s\\n' \"$*\"\nexec /bin/sleep 30\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        defer { try? FileManager.default.removeItem(at: fake) }
        h.model.sshExecutable = fake.path
        let hostID: String = try await h.value("id", "host.create", ["name": "Prod", "destination": "prod"])
        await h.hosts.load()
        h.model.resolveHost = { [hosts = h.hosts] id in await hosts.host(id) }
        let other: String = try await h.value("windowId", "window.create", ["name": "Other"])
        let foreignPane = try XCTUnwrap(h.model.snapshot.windows.first { $0.id.uuidString == other }.flatMap { h.model.snapshot.tabs[$0.activeTabID]?.activePaneID })
        let wrongTarget = try await h.code("host.connect", ["hostId": hostID, "windowId": live.window, "paneId": foreignPane.uuidString, "axis": "x"])
        XCTAssertEqual(wrongTarget, "NOT_FOUND")
        let connected = try result(try await h.call("host.connect", ["hostId": hostID, "windowId": live.window]))
        let session = try XCTUnwrap(connected["session"] as? [String: Any])
        XCTAssertEqual(session["launchKind"] as? String, "host")
        XCTAssertEqual(session["state"] as? String, "running")
        let paneID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(session["paneId"] as? String)))
        XCTAssertEqual(h.model.snapshot.panes[paneID].flatMap { h.model.snapshot.tabs[$0.tabID] }?.title, "Prod")
        try await NativeTerminalHandle(try XCTUnwrap(h.model.terminals[paneID])).waitFor("FAKE-SSH -- prod")
    }
}

/// Test wrapper around a model terminal's retained output.
@MainActor
final class NativeTerminalHandle {
    let native: NativeTerminal
    init(_ native: NativeTerminal) { self.native = native }
    func output() throws -> String { try native.adapter.read(.retainedText) }
    func waitFor(_ text: String) async throws {
        try await waitUntil { (try? self.native.adapter.read(.retainedText).contains(text)) == true }
    }
    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    func close() {
        native.requestTermination(force: true)
        native.adapter.detach()
    }
}

/// Minimal blocking AF_UNIX client (the control tests' client lives in another target).
final class BlockingClient: @unchecked Sendable {
    private let fd: Int32
    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
    func send(_ text: String) { _ = Array(text.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } }
    func request(_ line: String) throws -> String {
        send(line + "\n")
        var buffer = [UInt8](repeating: 0, count: 65_536), received = Data()
        while !received.contains(0x0A) {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { throw POSIXError(.ECONNRESET) }
            received.append(contentsOf: buffer.prefix(count))
        }
        return String(decoding: received, as: UTF8.self)
    }
    func close() { Darwin.close(fd) }
}
