import AppKit
import Darwin
import TrellisBroker
import TrellisCore
import TrellisTerminal
import XCTest

@testable import TrellisUI

/// Remote workspaces end to end on this Mac (FR-RW01, FR-RW04–FR-RW09): a fake `ssh` runs the bootstrap locally under a
/// temporary `HOME`, so the real helper, bridge, broker, login shell and shell integration run; only the network is missing.
@MainActor
final class RemoteWorkspaceTests: XCTestCase {
    private var root = ""
    private var home = ""
    private var host: SavedHost!
    private var models: [AppWorkspaceModel] = []
    private var cleanup: [() -> Void] = []
    private let clientID = RemoteClientIdentity.randomHex()

    override func setUp() async throws {
        _ = NSApplication.shared
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent(BrokerProtocol.helperName).path
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw XCTSkip("Run `swift build` first to build \(BrokerProtocol.helperName).") }
        root = try XCTUnwrap(BrokerFiles.realPath(NSTemporaryDirectory())) + "/trellis-rw-\(UUID().uuidString.prefix(8))"
        home = root + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
        shift; shift
        export HOME="$FAKE_SSH_HOME"
        exec /bin/sh -c "$1"
        """.write(toFile: root + "/ssh", atomically: true, encoding: .utf8)
        chmod(root + "/ssh", 0o755)
        host = SavedHost(id: UUID(), draft: try HostDraft(name: "build-box", destination: "build-box").validated { _ in false }, revision: 1)
    }

    override func tearDown() async throws {
        // Stop everything the helper still runs, then forget the temporary host.
        if let model = models.first, let remote = model.remoteHosts, case .success(let link) = await remote.workspaceLink(host, interactive: false) {
            link.connection?.sendStopAll()
            try? await Task.sleep(for: .milliseconds(300))
        }
        for model in models { model.remoteHosts?.closeWorkspaceLinks(); model.terminals.values.forEach { $0.adapter.detach() } }
        models = []
        cleanup.forEach { $0() }
        cleanup = []
        try? FileManager.default.removeItem(atPath: root)
    }

    private func makeModel() throws -> AppWorkspaceModel {
        let suite = "trellis.tests.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        cleanup.append { preferences.removePersistentDomain(forName: suite) }
        let model = AppWorkspaceModel(
            store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: URL(fileURLWithPath: root + "/state")))
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent(BrokerProtocol.helperName).path
        let remote = RemoteHostsModel(
            settings: RemoteHostSettings(stateDirectory: URL(fileURLWithPath: root + "/state")),
            catalog: RemoteArtifactCatalog.load(remoteDirectory: nil, macHelper: helper), clientID: clientID)
        remote.sshExecutable = root + "/ssh"
        let fakeHome = home
        remote.environment = { ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "FAKE_SSH_HOME": fakeHome] }
        remote.confirmInstall = { _, _, _, _ in true }
        model.remoteHosts = remote
        let host = host!
        model.resolveHost = { _ in host }
        model.commandPaletteHosts = { [host] }
        model.confirmCloseSessions = { _ in true }
        model.confirmForceSessions = { _ in true }
        model.confirmStopOrphans = { _ in
            XCTFail("Unexpected orphan prompt"); return false
        }
        models.append(model)
        return model
    }

    private func until(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out: \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testOpenSplitInheritDetachOnQuitAndReattachAfterRelaunch() async throws {
        let model = try makeModel()
        _ = await model.loadWorkspace()
        let opened = await model.openRemoteWorkspace(host: host)
        let windowID = try XCTUnwrap(opened)
        XCTAssertEqual(model.snapshot.windows.first { $0.id == windowID }?.remoteHostID, host.id)
        let pane = try XCTUnwrap(model.presentation.activePane)
        let terminal = try XCTUnwrap(model.terminals[pane.id])
        try await until("the remote shell runs") { terminal.sessionState == .running }
        XCTAssertNotNil(terminal.remoteTransport)
        XCTAssertEqual(model.remoteLinks[host.id], .connected)
        guard case .remoteShell(host.id, nil)? = model.snapshot.sessions[pane.sessionID]?.launch else { return XCTFail("Not a remote shell") }

        // FR-RW05: integration marks carry the session's nonce, so the directory is authenticated; it is never local.
        let work = home + "/work dir"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try terminal.adapter.send(Data("cd '\(work)' && echo moved-$((20+1))\r".utf8))
        try await until("the shell reports its directory") { model.remoteWorkingDirectory(paneID: pane.id) == work }
        XCTAssertNil(model.currentDirectory(paneID: pane.id), "A host's path is never used as a local one")

        // FR-RW04: a split runs on the same host, in the same directory.
        let created = await model.splitPane(pane.id, axis: .x)
        let split = try XCTUnwrap(created)
        let second = try XCTUnwrap(model.terminals[split])
        try await until("the split's shell runs") { second.sessionState == .running }
        guard case .remoteShell(host.id, work)? = model.snapshot.panes[split].flatMap({ model.snapshot.sessions[$0.sessionID]?.launch }) else {
            return XCTFail("The split didn't inherit the host and directory")
        }
        try await until("the split starts in the directory") { model.remoteWorkingDirectory(paneID: split) == work }

        // Something that keeps running while Trellis is gone.
        try terminal.adapter.send(Data("sleep 2; echo after-$((3+4))-quit\r".utf8))
        try await until("the command echoes") { terminal.screenText.contains("$((3+4))-quit") }

        // FR-RW06: quitting detaches; no signal reaches the host's sessions.
        XCTAssertEqual(model.confirmQuit(), .keepRunning, "Every session is kept, so quitting doesn't ask")
        let detached = await model.detachForQuit()
        XCTAssertTrue(detached)

        // Relaunch: the restored panes adopt their sessions by UUID, with the output produced meanwhile (FR-RW09).
        try await Task.sleep(for: .seconds(2.5))
        let relaunched = try makeModel()
        _ = await relaunched.loadWorkspace()
        let restored = try XCTUnwrap(relaunched.terminals[pane.id])
        try await until("the session is adopted") { restored.sessionState == .running && relaunched.remoteLinks[host.id] == .connected }
        XCTAssertNotNil(restored.remoteTransport)
        try await until("the output from while Trellis was closed") { restored.screenText.contains("after-7-quit") }
        XCTAssertEqual(relaunched.snapshot.windows.first?.remoteHostID, host.id, "The binding was saved")
        // Sessions are adopted one after another as the host answers.
        try await until("both panes came back") { relaunched.terminals[split]?.remoteTransport != nil && relaunched.terminals[split]?.sessionState == .running }
    }

    func testALostLinkRefusesInputThenResumesExactlyAndHangsUpWhatWasClosed() async throws {
        let model = try makeModel()
        _ = await model.loadWorkspace()
        let opened = await model.openRemoteWorkspace(host: host)
        XCTAssertNotNil(opened)
        let pane = try XCTUnwrap(model.presentation.activePane)
        let terminal = try XCTUnwrap(model.terminals[pane.id])
        try await until("the remote shell runs") { terminal.sessionState == .running }
        let created = await model.splitPane(pane.id, axis: .x)
        let split = try XCTUnwrap(created)
        let doomed = try XCTUnwrap(model.terminals[split])
        try await until("the split runs") { doomed.sessionState == .running }
        let doomedSession = doomed.sessionID

        try terminal.adapter.send(Data("sleep 1; echo missed-$((5+5))\r".utf8))
        try await until("the command echoes") { terminal.screenText.contains("$((5+5))") }
        model.remoteHosts?.closeWorkspaceLinks()
        try await until("the pane knows the link is down") { terminal.remoteTransport?.linkLost == true }
        XCTAssertEqual(terminal.sessionState, .running, "Losing the link is not an exit (FR-RW06)")
        XCTAssertThrowsError(try terminal.adapter.send(Data("x".utf8)), "Input is refused, never queued (FR-RW07)")

        // Closing a pane while the host is unreachable lets it go now and hangs it up later.
        await model.closePane(split)
        try await until("the pane closes without the host") { model.snapshot.panes[split] == nil }

        try await Task.sleep(for: .seconds(1.5))
        await model.reconnectRemote(hostID: host.id)
        XCTAssertEqual(model.remoteLinks[host.id], .connected)
        try await until("the missed output arrives") { terminal.screenText.contains("missed-10") }
        XCTAssertEqual(terminal.screenText.components(separatedBy: "missed-10").count - 1, 1, "Shown once (FR-RW08)")
        try terminal.adapter.send(Data("echo back-$((1+1))\r".utf8))
        try await until("input works again") { terminal.screenText.contains("back-2") }

        let connection = try XCTUnwrap(terminal.remoteTransport?.connection)
        var hungUp = false
        let deadline = Date().addingTimeInterval(5)
        while !hungUp, Date() < deadline {
            if case .sessions(let records)? = try? await connection.request(.list) {
                hungUp = records.first { $0.sessionID == doomedSession }?.running != true
            }
            if !hungUp { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertTrue(hungUp, "The pane closed while disconnected was hung up once the host was reachable")
    }

    /// MAC-04 with Stop sessions on: closing the native window detaches remote sessions, the sidebar stops saying
    /// Connected, and a remote pane can still be closed afterwards (it is hung up once the host is reachable again).
    func testWindowCloseDetachesRemoteSessionsAndLeavesThemClosable() async throws {
        let model = try makeModel()
        _ = await model.loadWorkspace()
        let opened = await model.openRemoteWorkspace(host: host)
        XCTAssertNotNil(opened)
        let pane = try XCTUnwrap(model.presentation.activePane)
        let terminal = try XCTUnwrap(model.terminals[pane.id])
        try await until("the remote shell runs") { terminal.sessionState == .running }
        let created = await model.splitPane(pane.id, axis: .x)
        let split = try XCTUnwrap(created)
        let second = try XCTUnwrap(model.terminals[split])
        try await until("the split runs") { second.sessionState == .running }

        let closed = await model.endSessionsForWindowClose()
        XCTAssertTrue(closed)
        XCTAssertEqual(terminal.sessionState, .running, "Window close detaches remote sessions (FR-RW06)")
        try await until("the panes know the link is down") { terminal.remoteTransport?.linkLost == true }
        XCTAssertNotEqual(model.remoteLinks[host.id], .connected, "The sidebar never shows a closed link as Connected")

        await model.closePane(split)
        try await until("the detached pane still closes") { model.snapshot.panes[split] == nil }
        await model.reconnectRemote(hostID: host.id)
        try terminal.adapter.send(Data("echo again-$((2+2))\r".utf8))
        try await until("the first pane resumed") { terminal.screenText.contains("again-4") }
    }

    /// Two reconnects at once (launch re-attach and a Reconnect click) attach each session once: missed output once.
    func testConcurrentReconnectsResumeOnce() async throws {
        let model = try makeModel()
        _ = await model.loadWorkspace()
        let opened = await model.openRemoteWorkspace(host: host)
        XCTAssertNotNil(opened)
        let pane = try XCTUnwrap(model.presentation.activePane)
        let terminal = try XCTUnwrap(model.terminals[pane.id])
        try await until("the remote shell runs") { terminal.sessionState == .running }
        try terminal.adapter.send(Data("sleep 1; echo twice-$((6+6))\r".utf8))
        try await until("the command echoes") { terminal.screenText.contains("$((6+6))") }
        model.remoteHosts?.closeWorkspaceLinks()
        try await until("the pane knows the link is down") { terminal.remoteTransport?.linkLost == true }
        try await Task.sleep(for: .seconds(1.5))
        let hostID = host.id
        async let first: Void = model.reconnectRemote(hostID: hostID)
        async let second: Void = model.reconnectRemote(hostID: hostID)
        _ = await (first, second)
        try await until("the missed output arrives") { terminal.screenText.contains("twice-12") }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(terminal.screenText.components(separatedBy: "twice-12").count - 1, 1, "Shown once (FR-RW08)")
    }
}

/// FR-RW15: typing into or starting a remote workspace session needs access to its host.
@MainActor
final class RemoteWorkspaceAutomationReviewTests: XCTestCase {
    func testRemoteSessionsNeedHostAccessForStartAndInput() async throws {
        let h = try Harness()
        defer { h.discardPreferences() }
        try await h.grant("full")
        // A host this grant can't see: it is not in the library.
        let result = try await h.model.service.execute(.createRemoteWindow(name: "Remote", hostID: UUID()))
        h.model.publish(result.snapshot)
        let window = try XCTUnwrap(result.snapshot.windows.first { $0.id == result.createdWindowID })
        let tab = try XCTUnwrap(result.snapshot.tabs[window.activeTabID])
        let pane = try XCTUnwrap(result.snapshot.panes[tab.activePaneID])
        let start = try await h.code("session.start", ["paneId": pane.id.uuidString])
        XCTAssertEqual(start, "PERMISSION_DENIED")
        let input = try await h.code("session.sendInput", ["id": pane.sessionID.uuidString, "text": "id\n"])
        XCTAssertEqual(input, "PERMISSION_DENIED")
        let execute = try await h.code("session.execute", ["id": pane.sessionID.uuidString, "command": "id", "submit": true])
        XCTAssertEqual(execute, "PERMISSION_DENIED")
        XCTAssertEqual(h.model.snapshot.sessions[pane.sessionID]?.state, .stopped, "Nothing started")
    }

    func testInputToAHostThatIsNotConnectedFailsAsRemoteDisconnected() async throws {
        let h = try Harness()
        defer { h.discardPreferences() }
        try await h.grant("full")
        guard case .success(let host) = await h.hosts.save(HostDraft(name: "build-box", destination: "build-box"), editing: nil) else { return XCTFail("No host") }
        let result = try await h.model.service.execute(.createRemoteWindow(name: "Remote", hostID: host.id))
        h.model.publish(result.snapshot)
        let window = try XCTUnwrap(result.snapshot.windows.first { $0.id == result.createdWindowID })
        let pane = try XCTUnwrap(result.snapshot.tabs[window.activeTabID].flatMap { result.snapshot.panes[$0.activePaneID] })
        h.model.remoteLinks[host.id] = .reconnecting(attempt: 2, at: Date())
        let stopped = try await h.code("session.sendInput", ["id": pane.sessionID.uuidString, "text": "id\n"])
        XCTAssertNotEqual(stopped, "REMOTE_DISCONNECTED", "A session that isn't running fails as not running, not as retryable")
        // Running on the host while its link is down.
        h.model.publish(try await h.model.service.execute(.adoptRunningSession(sessionID: pane.sessionID, processID: 4242)).snapshot)
        let input = try await h.code("session.sendInput", ["id": pane.sessionID.uuidString, "text": "id\n"])
        XCTAssertEqual(input, "REMOTE_DISCONNECTED", "Never queued for later (FR-RW15)")
        let execute = try await h.code("session.execute", ["id": pane.sessionID.uuidString, "command": "id", "submit": true])
        XCTAssertEqual(execute, "REMOTE_DISCONNECTED")
    }
}
