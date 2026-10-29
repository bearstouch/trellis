import AppKit
import Darwin
import TrellisBroker
import TrellisCore
import TrellisTerminal
import XCTest

@testable import TrellisUI

/// Automatic reconnects (FR-RW07, FR-RW08) end to end through a fake `ssh` that runs the real bootstrap, helper and broker
/// under a temporary `HOME`. Killing the link's ssh is a dropped connection; a "fail" file makes later attempts fail the way
/// ssh does, for every attempt or only for automatic (`BatchMode`) ones. Backoff waits are recorded and shortened.
@MainActor
final class RemoteReconnectTests: XCTestCase {
    private var root = ""
    private var home = ""
    private var host: SavedHost!
    private var model: AppWorkspaceModel!
    private let log = DelayLog()
    private var delays: [TimeInterval] { log.values }
    private var cleanup: [() -> Void] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent(BrokerProtocol.helperName).path
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw XCTSkip("Run `swift build` first to build \(BrokerProtocol.helperName).") }
        root = try XCTUnwrap(BrokerFiles.realPath(NSTemporaryDirectory())) + "/trellis-rr-\(UUID().uuidString.prefix(8))"
        home = root + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        batch=0
        for a in "$@"; do [ "$a" = "BatchMode=yes" ] && batch=1; done
        while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
        shift; shift
        if [ -f "$FAKE_SSH_FAIL" ] && { [ $batch = 1 ] || [ ! -f "$FAKE_SSH_FAIL.batch-only" ]; }; then cat "$FAKE_SSH_FAIL" >&2; exit 255; fi
        export HOME="$FAKE_SSH_HOME"
        exec /bin/sh -c "$1"
        """.write(toFile: root + "/ssh", atomically: true, encoding: .utf8)
        chmod(root + "/ssh", 0o755)
        host = SavedHost(id: UUID(), draft: try HostDraft(name: "build-box", destination: "build-box").validated { _ in false }, revision: 1)

        let suite = "trellis.tests.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        cleanup.append { preferences.removePersistentDomain(forName: suite) }
        model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: URL(fileURLWithPath: root + "/state")))
        let remote = RemoteHostsModel(
            settings: RemoteHostSettings(stateDirectory: URL(fileURLWithPath: root + "/state")),
            catalog: RemoteArtifactCatalog.load(remoteDirectory: nil, macHelper: helper), clientID: RemoteClientIdentity.randomHex())
        remote.sshExecutable = root + "/ssh"
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "FAKE_SSH_HOME": home, "FAKE_SSH_FAIL": root + "/fail"]
        remote.environment = { environment }
        remote.confirmInstall = { _, _, _, _ in true }
        model.remoteHosts = remote
        let host = host!
        model.resolveHost = { _ in host }
        model.commandPaletteHosts = { [host] }
        model.confirmCloseSessions = { _ in true }
        model.confirmStopOrphans = { _ in
            XCTFail("Unexpected orphan prompt"); return false
        }
        model.remoteReconnector.random = { 0.5 }
        let log = log
        model.remoteReconnector.sleep = { delay in
            await log.record(delay)
            try await Task.sleep(for: .milliseconds(30))
        }
        _ = await model.loadWorkspace()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: root + "/fail")
        if let remote = model?.remoteHosts, case .success(let link) = await remote.workspaceLink(host, interactive: false) {
            link.connection?.sendStopAll()
            try? await Task.sleep(for: .milliseconds(300))
        }
        model?.remoteReconnector.cancelAll()
        model?.remoteHosts?.closeWorkspaceLinks()
        model?.terminals.values.forEach { $0.adapter.detach() }
        model = nil
        cleanup.forEach { $0() }
        cleanup = []
        try? FileManager.default.removeItem(atPath: root)
    }

    private func until(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out: \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A running remote shell and a command whose output lands while the link is down.
    private func openWithPendingOutput(_ token: String) async throws -> NativeTerminal {
        let opened = await model.openRemoteWorkspace(host: host)
        XCTAssertNotNil(opened)
        let pane = try XCTUnwrap(model.presentation.activePane)
        let terminal = try XCTUnwrap(model.terminals[pane.id])
        try await until("the remote shell runs") { terminal.sessionState == .running }
        try terminal.adapter.send(Data("sleep 1; echo \(token)-$((40+2))\r".utf8))
        try await until("the command echoes") { terminal.screenText.contains("\(token)-$((40+2))") }
        return terminal
    }

    /// The connection drops: ssh dies, as when the network goes away under it.
    private func dropConnection() async throws {
        guard case .success(let link) = await model.remoteHosts!.workspaceLink(host, interactive: false), let pid = link.processID else {
            return XCTFail("No link")
        }
        kill(pid, SIGKILL)
        try await until("the link is noticed down") { model.remoteLinks[host.id] != .connected }
    }

    func testALostLinkReconnectsByItselfAndResumesOnce() async throws {
        let terminal = try await openWithPendingOutput("back")
        try await dropConnection()
        XCTAssertEqual(terminal.sessionState, .running, "The session keeps running on the host")
        try await until("reconnected without the person") { model.remoteLinks[host.id] == .connected && terminal.remoteTransport?.linkLost == false }
        try await until("the missed output arrives") { terminal.screenText.contains("back-42") }
        XCTAssertEqual(terminal.screenText.components(separatedBy: "back-42").count - 1, 1, "Shown once (FR-RW08)")
        XCTAssertEqual(delays, [1], "One automatic attempt after the first backoff")
        XCTAssertEqual(model.remoteReconnector.attemptCount(host.id), 0, "The count resets once connected")
    }

    func testANetworkFailureBacksOffThenRecovers() async throws {
        let terminal = try await openWithPendingOutput("late")
        try Data("ssh: connect to host build-box port 22: Connection refused\n".utf8).write(to: URL(fileURLWithPath: root + "/fail"))
        try await dropConnection()
        try await until("three attempts were refused") { delays.count >= 3 }
        guard case .reconnecting(let attempt, _)? = model.remoteLinks[host.id] else { return XCTFail("\(String(describing: model.remoteLinks[host.id]))") }
        XCTAssertGreaterThanOrEqual(attempt, 3)
        try FileManager.default.removeItem(atPath: root + "/fail")
        try await until("reconnected once the host answers") { model.remoteLinks[host.id] == .connected }
        XCTAssertEqual(Array(delays.prefix(3)), [1, 2, 4], "1, 2, 4 s… up to a minute (jitter fixed at the midpoint here)")
        try await until("the missed output arrives") { terminal.screenText.contains("late-42") }
    }

    func testAnAttemptThatNeedsAPasswordStopsAutomaticAttempts() async throws {
        let terminal = try await openWithPendingOutput("asked")
        try Data("dev@build-box: Permission denied (publickey,password).\n".utf8).write(to: URL(fileURLWithPath: root + "/fail"))
        try Data().write(to: URL(fileURLWithPath: root + "/fail.batch-only"))
        try await dropConnection()
        try await until("the reconnect asks for the person") {
            if case .needsInput? = model.remoteLinks[host.id] { true } else { false }
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(delays.count, 1, "A credential is never retried on its own (INT-05)")
        XCTAssertTrue(model.remoteLinks[host.id]?.label == "Reconnect needs you")
        // Reconnect… lets ssh ask, here answered by the fake; the session resumes.
        await model.reconnectRemote(hostID: host.id)
        try await until("reconnected after the person") { model.remoteLinks[host.id] == .connected }
        try await until("the missed output arrives") { terminal.screenText.contains("asked-42") }
    }

    func testOfflinePausesAttemptsAndTheNetworkResumesThem() async throws {
        let terminal = try await openWithPendingOutput("offline")
        model.remoteReconnector.networkChanged(online: false)
        try await dropConnection()
        try await until("the host waits for the network") { model.remoteLinks[host.id] == .offline }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(delays.isEmpty, "Nothing is attempted while offline")
        model.remoteReconnector.networkChanged(online: true)
        try await until("reconnected when the network returns") { model.remoteLinks[host.id] == .connected }
        XCTAssertTrue(delays.isEmpty, "The network's return is tried at once")
        try await until("the missed output arrives") { terminal.screenText.contains("offline-42") }
    }

    /// After sleep the link may be dead without having noticed: wake pings at once instead of waiting for the heartbeat.
    func testWakeFindsASilentlyDeadLinkAndReconnects() async throws {
        let terminal = try await openWithPendingOutput("woke")
        guard case .success(let link) = await model.remoteHosts!.workspaceLink(host, interactive: false), let pid = link.processID else {
            return XCTFail("No link")
        }
        // A frozen ssh keeps its socket open but never answers, like a connection whose network vanished.
        kill(pid, SIGSTOP)
        defer { kill(pid, SIGKILL); kill(pid, SIGCONT) }
        XCTAssertEqual(model.remoteLinks[host.id], .connected, "Nothing has noticed yet")
        model.remoteReconnector.didWake()
        try await until("the wake check notices within its 5 s timeout", timeout: 10) { model.remoteLinks[host.id] != .connected }
        try await until("reconnected on a new connection") { model.remoteLinks[host.id] == .connected }
        try await until("the missed output arrives") { terminal.screenText.contains("woke-42") }
    }

    /// A switch from Wi-Fi to Ethernet keeps the Mac online but can strand the connection: any path update checks links.
    func testANetworkChangeWhileOnlineFindsASilentlyDeadLink() async throws {
        let terminal = try await openWithPendingOutput("moved")
        guard case .success(let link) = await model.remoteHosts!.workspaceLink(host, interactive: false), let pid = link.processID else {
            return XCTFail("No link")
        }
        kill(pid, SIGSTOP)
        defer { kill(pid, SIGKILL); kill(pid, SIGCONT) }
        model.remoteReconnector.networkChanged(online: true)
        try await until("the path update notices within its 5 s timeout", timeout: 10) { model.remoteLinks[host.id] != .connected }
        try await until("reconnected on a new connection") { model.remoteLinks[host.id] == .connected }
        try await until("the missed output arrives") { terminal.screenText.contains("moved-42") }
    }

    func testRetryNowAttemptsAtOnce() async throws {
        _ = try await openWithPendingOutput("retry")
        let log = log
        model.remoteReconnector.sleep = { delay in
            await log.record(delay)
            try await Task.sleep(for: .seconds(60))
        }
        try await dropConnection()
        try await until("an attempt is scheduled") { if case .reconnecting? = model.remoteLinks[host.id] { true } else { false } }
        model.remoteReconnector.retryNow(host.id)
        try await until("Retry Now reconnects without waiting a minute") { model.remoteLinks[host.id] == .connected }
    }
}

@MainActor
private final class DelayLog {
    var values: [TimeInterval] = []
    func record(_ delay: TimeInterval) { values.append(delay) }
}
