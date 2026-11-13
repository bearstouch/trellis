import AppKit
import Darwin
import TrellisBroker
import TrellisControl
import TrellisCore
import TrellisTerminal
import XCTest

@testable import TrellisUI

/// Protocol 2 remote workspaces over the real model (methods.md#remote-workspaces, FR-RW15): a fake `ssh` runs the
/// bootstrap locally under a temporary `HOME`, so the real helper, bridge, broker and login shell run; only the network
/// is missing. The app's confirmations fail the test if shown: the API never asks in the app.
@MainActor
final class AutomationV2RemoteTests: XCTestCase {
    private var root = ""
    private var home = ""
    private var v: HarnessV2!
    private var host: SavedHost!
    private var remote: RemoteHostsModel!

    private static let opener: Set<CapabilityV2> = [.remoteConnect, .workspaceWrite, .workspaceRead, .sessionStart, .hostRead]

    override func setUp() async throws {
        _ = NSApplication.shared
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent(BrokerProtocol.helperName).path
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw XCTSkip("Run `swift build` first to build \(BrokerProtocol.helperName).") }
        root = try XCTUnwrap(BrokerFiles.realPath(NSTemporaryDirectory())) + "/trellis-v2rw-\(UUID().uuidString.prefix(8))"
        home = root + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        // `$FAKE_SSH_FAIL` makes ssh fail with that text (batch attempts only when `.batch-only` exists beside it).
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

        v = try HarnessV2()
        let model = v.model
        guard case .success(let saved) = await v.base.hosts.save(HostDraft(name: "build-box", destination: "build-box"), editing: nil) else { return XCTFail("No host") }
        host = saved
        remote = RemoteHostsModel(
            settings: RemoteHostSettings(stateDirectory: URL(fileURLWithPath: root + "/state")),
            catalog: RemoteArtifactCatalog.load(remoteDirectory: nil, macHelper: helper), clientID: RemoteClientIdentity.randomHex())
        remote.sshExecutable = root + "/ssh"
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "FAKE_SSH_HOME": home, "FAKE_SSH_FAIL": root + "/fail"]
        remote.environment = { environment }
        remote.confirmInstall = { _, _, _, _ in
            XCTFail("The API showed the install sheet"); return false
        }
        remote.confirmRemove = { _ in
            XCTFail("The API showed the remove confirmation"); return false
        }
        remote.confirmStopSessions = { _, _ in
            XCTFail("The API showed the stop-sessions confirmation"); return false
        }
        model.remoteHosts = remote
        let hosts = v.base.hosts
        model.resolveHost = { id in await hosts.host(id) }
        model.commandPaletteHosts = { hosts.hosts }
        model.confirmStopOrphans = { _ in
            XCTFail("Unexpected orphan prompt"); return false
        }
        // Automatic attempts wait far longer than any test.
        model.remoteReconnector.sleep = { _ in try await Task.sleep(for: .seconds(3_600)) }
    }

    override func tearDown() async throws {
        if let remote, let host {
            try? FileManager.default.removeItem(atPath: root + "/fail")
            if case .success(let link) = await remote.workspaceLink(host, interactive: false, install: .never) {
                link.connection?.sendStopAll()
                try? await Task.sleep(for: .milliseconds(300))
            }
            remote.closeWorkspaceLinks()
        }
        v?.model.remoteReconnector.cancelAll()
        v?.model.terminals.values.forEach { $0.adapter.detach() }
        v?.base.discardPreferences()
        try? FileManager.default.removeItem(atPath: root)
    }

    private func grant(_ name: String, _ capabilities: Set<CapabilityV2>, scope: GrantScope = GrantScope()) async throws {
        try await v.grant(name, settings: GrantSettings(name: name, capabilities: capabilities, scope: scope))
    }

    private func until(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out: \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private var hostID: String { host.id.uuidString.lowercased() }
    private var installed: Bool { FileManager.default.fileExists(atPath: home + "/.trellis/remote") }
    private func fail(with text: String, batchOnly: Bool = false) throws {
        try Data((text + "\n").utf8).write(to: URL(fileURLWithPath: root + "/fail"))
        if batchOnly { try Data().write(to: URL(fileURLWithPath: root + "/fail.batch-only")) }
    }
    private func succeed() {
        try? FileManager.default.removeItem(atPath: root + "/fail")
        try? FileManager.default.removeItem(atPath: root + "/fail.batch-only")
    }

    /// A remote workspace opened through the API with start: its pane runs a shell on the host, its link is shared.
    private func openStarted(as name: String = "full") async throws -> (space: UUID, pane: UUID, session: UUID) {
        let opened = try await v.ok("remote.open", ["hostId": hostID, "start": true], as: name)
        let space = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(object(opened, "space")["id"] as? String)))
        let pane = try XCTUnwrap(UUID(uuidString: try XCTUnwrap((opened["panes"] as? [[String: Any]])?.first?["id"] as? String)))
        let terminal = try XCTUnwrap(v.model.terminals[pane])
        try await until("the remote shell runs") { terminal.sessionState == .running && terminal.remoteTransport != nil }
        return (space, pane, terminal.sessionID)
    }

    // MARK: remote.open

    func testOpenStartsAShellOnTheHostAndJoinsACreatedScope() async throws {
        // An orchestrator that makes its own spaces; remote.manage is its consent to install the missing helper.
        try await grant("full", Self.opener.union([.remoteManage, .sessionOutputRead]), scope: GrantScope(spaces: .created))
        try await grant("other", Self.opener, scope: GrantScope(spaces: .created))
        XCTAssertFalse(installed)
        let spacesBefore = v.model.snapshot.spaces.count
        let opened = try await v.ok("remote.open", ["hostId": hostID, "start": true, "name": "Builds"])
        let space = object(opened, "space")
        XCTAssertEqual(space["name"] as? String, "Builds")
        XCTAssertEqual(space["machine"] as? [String: String], ["kind": "remote", "hostId": hostID])
        XCTAssertNotNil(object(opened, "tab")["id"])
        XCTAssertNotNil(opened["workspaceRevision"])
        let paneID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap((opened["panes"] as? [[String: Any]])?.first?["id"] as? String)))
        let terminal = try XCTUnwrap(v.model.terminals[paneID])
        try await until("the remote shell runs") { terminal.sessionState == .running && terminal.remoteTransport != nil }
        XCTAssertTrue(installed, "Installed with the grant's remote.manage, without the sheet")
        XCTAssertEqual(v.model.snapshot.spaces.count, spacesBefore + 1)
        XCTAssertEqual(v.model.remoteLinks[host.id], .connected)
        guard case .remoteShell(host.id, nil)? = v.model.snapshot.panes[paneID].flatMap({ v.model.snapshot.sessions[$0.sessionID]?.launch }) else {
            return XCTFail("Not a remote shell on the host")
        }
        try terminal.adapter.send(Data("echo remote-$((40+2))\r".utf8))
        try await until("the shell answers") { terminal.screenText.contains("remote-42") }

        // created scope: the opener sees and drives its space; another created-scope grant doesn't.
        let spaceID = try XCTUnwrap(space["id"] as? String)
        _ = try await v.ok("space.get", ["id": spaceID])
        let read = try await v.ok("session.readOutput", ["id": terminal.sessionID.uuidString, "view": "screen"])
        XCTAssertTrue((read["text"] as? String)?.contains("remote-42") == true)
        let hidden = try await v.code("space.get", ["id": spaceID], as: "other")
        XCTAssertEqual(hidden, "NOT_FOUND")

        // The host's helper and link, from remote.status and host.get alike.
        let status = object(try await v.ok("remote.status", ["hostId": hostID]), "remote")
        XCTAssertEqual(status["helper"] as? String, "current")
        XCTAssertEqual(status["autoInstall"] as? Bool, false)
        XCTAssertNotNil(status["checkedAt"] as? String)
        XCTAssertEqual(status["link"] as? [String: String], ["state": "connected"])
        let host = object(try await v.ok("host.get", ["id": hostID]), "host")
        XCTAssertEqual((host["remote"] as? [String: Any])?["link"] as? [String: String], ["state": "connected"])

        // As the space's menu: nothing to reconnect while connected.
        let reconnect = try await v.call("remote.reconnect", ["hostId": hostID])
        XCTAssertEqual(errorCode(reconnect), "INVALID_STATE")
        XCTAssertEqual(details(reconnect)?["state"] as? String, "connected")

        // A second space on the same host shares the link and starts stopped without start.
        let stopped = try await v.ok("remote.open", ["hostId": hostID])
        let stoppedPane = try XCTUnwrap(UUID(uuidString: try XCTUnwrap((stopped["panes"] as? [[String: Any]])?.first?["id"] as? String)))
        XCTAssertEqual(object(stopped, "space")["name"] as? String, "build-box", "Named after the host by default")
        XCTAssertEqual(v.model.terminals[stoppedPane]?.sessionState, .stopped)
    }

    /// The helperInstall rule: a missing helper, the host's auto-install off and no remote.manage is CONFIRMATION_REQUIRED
    /// before anything is created, and nothing is written on the host; the host's own auto-install lets it proceed.
    func testAMissingHelperNeedsConsentAndARefusalLeavesNothing() async throws {
        try await grant("full", Self.opener)
        let spacesBefore = v.model.snapshot.spaces.count
        let refused = try await v.call("remote.open", ["hostId": hostID, "start": true])
        XCTAssertEqual(errorCode(refused), "CONFIRMATION_REQUIRED")
        XCTAssertEqual(details(refused)?["reason"] as? String, "helperInstall")
        XCTAssertEqual(v.model.snapshot.spaces.count, spacesBefore, "No space was created")
        XCTAssertFalse(installed, "Nothing was written on the host")
        // The probe was recorded, and the link says why it stopped, as a code.
        let status = object(try await v.ok("remote.status", ["hostId": hostID]), "remote")
        XCTAssertEqual(status["helper"] as? String, "missing")
        XCTAssertEqual(status["link"] as? [String: String], ["state": "disconnected", "reason": "helperMissing"])

        // A stopped remote workspace connects only when a session starts there, under the same rule.
        let opened = try await v.ok("remote.open", ["hostId": hostID])
        let pane = try XCTUnwrap((opened["panes"] as? [[String: Any]])?.first?["id"] as? String)
        let paneID = try XCTUnwrap(UUID(uuidString: pane))
        let start = try await v.call("session.start", ["paneId": pane])
        XCTAssertEqual(errorCode(start), "CONFIRMATION_REQUIRED")
        XCTAssertEqual(details(start)?["reason"] as? String, "helperInstall")
        XCTAssertEqual(v.model.terminals[paneID]?.sessionState, .stopped, "The pane didn't start")
        let tabs = v.model.snapshot.tabs.count
        let tab = try await v.call("tab.create", ["spaceId": try XCTUnwrap(object(opened, "space")["id"] as? String), "start": true])
        XCTAssertEqual(errorCode(tab), "CONFIRMATION_REQUIRED")
        XCTAssertEqual(v.model.snapshot.tabs.count, tabs, "No tab was created")

        // The host's own auto-install (FR-RW17) is consent given in the app.
        await remote.setAutoInstall(host, true)
        _ = try await v.ok("session.start", ["paneId": pane])
        let terminal = try XCTUnwrap(v.model.terminals[paneID])
        try await until("the remote shell runs") { terminal.sessionState == .running && terminal.remoteTransport != nil }
        XCTAssertTrue(installed)
        XCTAssertEqual(remote.preferences(host).helper?.state, .current)
    }

    // MARK: remote.helper.*

    func testHelperInstallAndRemoveMirrorTheHostLibrary() async throws {
        try await grant("full", [.remoteManage, .hostRead])
        try await grant("connect", [.remoteConnect, .hostRead])
        try await grant("closer", [.remoteManage, .sessionClose, .hostRead])
        let denied = try await v.call("remote.helper.install", ["hostId": hostID], as: "connect")
        XCTAssertEqual(errorCode(denied), "PERMISSION_DENIED")
        XCTAssertEqual(details(denied)?["missing"] as? [String], ["remote.manage"])
        XCTAssertFalse(installed)

        let first = object(try await v.ok("remote.helper.install", ["hostId": hostID]), "remote")
        XCTAssertEqual(first["helper"] as? String, "current")
        XCTAssertTrue(installed)
        XCTAssertEqual(remote.messages[host.id], "The helper is installed.", "The host library shows the outcome too")
        XCTAssertNil(remote.activity[host.id])
        // Already current: the host keeps it (its digest matches), the call still succeeds.
        _ = try await v.ok("remote.helper.install", ["hostId": hostID])

        // A session this Mac left running on the host.
        let link = RemoteHostLink(
            request: .init(sshExecutable: remote.sshExecutable, options: [], destination: host.destination, environment: remote.environment(), clientID: remote.clientID!),
            catalog: remote.catalog)
        _ = try await link.run(.bridge, install: .never).get()
        let spawned = try await XCTUnwrap(link.connection).request(
            .spawnLogin(BrokerLoginRequest(sessionID: UUID(), shell: "/bin/sh", directory: nil, environment: [:], integration: nil, columns: 80, rows: 24)))
        guard case .spawned = spawned else { return XCTFail("\(spawned)") }
        link.close()

        let kept = try await v.call("remote.helper.remove", ["hostId": hostID])
        XCTAssertEqual(errorCode(kept), "CONFIRMATION_REQUIRED")
        XCTAssertEqual(details(kept)?["reason"] as? String, "runningSessions")
        XCTAssertEqual(details(kept)?["count"] as? Int, 1)
        XCTAssertTrue(installed, "Kept with its running session")
        let noClose = try await v.call("remote.helper.remove", ["hostId": hostID, "stopSessions": true])
        XCTAssertEqual(errorCode(noClose), "PERMISSION_DENIED")
        XCTAssertEqual(details(noClose)?["missing"] as? [String], ["session.close"])

        let removed = object(try await v.ok("remote.helper.remove", ["hostId": hostID, "stopSessions": true], as: "closer"), "remote")
        XCTAssertEqual(removed["helper"] as? String, "missing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.trellis"))
    }

    // MARK: remote.reconnect and link reasons

    func testReconnectMirrorsRetryNowAndReconnectAndReportsReasonCodes() async throws {
        try await grant("full", Self.opener.union([.remoteManage, .sessionInput, .sessionOutputRead, .sessionClose]))
        let (_, pane, session) = try await openStarted()
        let terminal = try XCTUnwrap(v.model.terminals[pane])

        // The link drops; the session keeps running on the host.
        remote.closeWorkspaceLink(host.id)
        v.model.remoteLinks[host.id] = .disconnected(nil, reason: .lost)
        try await until("the pane knows the link is down") { terminal.remoteTransport?.linkLost == true }
        let input = try await v.call("session.sendInput", ["id": session.uuidString, "text": "echo nope\r"])
        XCTAssertEqual(errorCode(input), "REMOTE_DISCONNECTED")
        XCTAssertEqual(details(input)?["reason"] as? String, "lost")
        let stop = try await v.call("session.stop", ["id": session.uuidString])
        XCTAssertEqual(errorCode(stop), "REMOTE_DISCONNECTED", "Nothing can reach the session until the link is back")
        _ = try await v.ok("session.readOutput", ["id": session.uuidString, "view": "screen"])

        // Retry Now: an automatic attempt that the host refuses keeps retrying on its own (reconnecting).
        try fail(with: "ssh: connect to host build-box port 22: Connection refused")
        let refused = object(try await v.ok("remote.reconnect", ["hostId": hostID]), "remote")
        XCTAssertEqual((refused["link"] as? [String: Any])?["state"] as? String, "reconnecting")
        XCTAssertEqual((refused["link"] as? [String: Any])?["attempt"] as? Int, 1)
        XCTAssertNotNil((refused["link"] as? [String: Any])?["nextAttemptAt"] as? String)
        // An attempt that needs a credential stops automatic attempts and says what it needs.
        v.model.remoteReconnector.cancelAll()
        v.model.remoteLinks[host.id] = .disconnected(nil, reason: .lost)
        try fail(with: "dev@build-box: Permission denied (publickey).")
        let asks = object(try await v.ok("remote.reconnect", ["hostId": hostID]), "remote")
        XCTAssertEqual(asks["link"] as? [String: String], ["state": "needsInput", "reason": "authFailed"])
        let host = object(try await v.ok("host.get", ["id": hostID]), "host")
        XCTAssertEqual((host["remote"] as? [String: Any])?["link"] as? [String: String], ["state": "needsInput", "reason": "authFailed"])

        // Reconnect…: interactive, so ssh may ask in the console; it connects and the pane resumes.
        try fail(with: "dev@build-box: Permission denied (publickey).", batchOnly: true)
        let back = object(try await v.ok("remote.reconnect", ["hostId": hostID, "interactive": true]), "remote")
        XCTAssertEqual(back["link"] as? [String: String], ["state": "connected"])
        try await until("the pane resumes") { terminal.remoteTransport?.linkLost == false }
        _ = try await v.ok("session.sendInput", ["id": session.uuidString, "text": "echo back-$((1+1))\r"])
        try await until("the shell answers again") { terminal.screenText.contains("back-2") }
        XCTAssertEqual(terminal.sessionState, .running, "The session ran through the outage")

        // A host no workspace uses has nothing to reconnect.
        guard case .success(let spare) = await v.base.hosts.save(HostDraft(name: "spare", destination: "spare"), editing: nil) else { return XCTFail("No host") }
        let none = try await v.call("remote.reconnect", ["hostId": spare.id.uuidString])
        XCTAssertEqual(errorCode(none), "INVALID_STATE")
        XCTAssertEqual(details(none)?["state"] as? String, "noWorkspace")
    }

    func testAnInteractiveFailureReportsWhySshEnded() async throws {
        try await grant("full", Self.opener.union([.remoteManage]))
        try fail(with: "Host key verification failed.")
        let spaces = v.model.snapshot.spaces.count
        let refused = try await v.call("remote.open", ["hostId": hostID, "start": true])
        XCTAssertEqual(errorCode(refused), "REMOTE_DISCONNECTED")
        XCTAssertEqual(details(refused)?["reason"] as? String, "sshExited", "Interactive: ssh ended, its console says why")
        XCTAssertEqual(v.model.snapshot.spaces.count, spaces, "Nothing was created")
        let status = object(try await v.ok("remote.status", ["hostId": hostID]), "remote")
        XCTAssertEqual(status["link"] as? [String: String], ["state": "disconnected", "reason": "sshExited"])
        // Automatic attempts (session.start, tab.create) never prompt: the same failure is classified.
        succeed()
        let opened = try await v.ok("remote.open", ["hostId": hostID])
        try fail(with: "@@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@@\nHost key verification failed.")
        let pane = try XCTUnwrap((opened["panes"] as? [[String: Any]])?.first?["id"] as? String)
        let start = try await v.call("session.start", ["paneId": pane])
        XCTAssertEqual(errorCode(start), "REMOTE_DISCONNECTED")
        XCTAssertEqual(details(start)?["reason"] as? String, "hostKeyChanged")
        XCTAssertEqual(v.model.terminals[try XCTUnwrap(UUID(uuidString: pane))]?.sessionState, .stopped)
    }

    /// Phase 5's fix past phase 6's connect-first check: an install whose launch is refused after the installer mark was
    /// set (the link is up, but the saved host can't be resolved when the pane starts) leaves no stale mark, so a later
    /// start of that pane, perhaps by a grant without agent.install, never runs the installer.
    func testAFailedInstallLaunchAfterTheMarkLeavesNoInstallerMark() async throws {
        try await grant("full", Self.opener.union([.remoteManage, .agentInstall, .agentControl, .sessionExecute]))
        let (space, _, _) = try await openStarted()
        let recipe = AgentInstallRecipe(command: "true")
        v.model.agentCatalog = AgentCatalogSnapshot(
            definitions: v.model.agentCatalog.definitions + [
                AgentDefinition(id: "fake-agent", name: "Fake", executable: "trellis-fake-agent", install: ["darwin": recipe, "linux": recipe])
            ])
        v.model.resolveHost = { _ in nil }
        let failed = try await v.call("agent.install", ["agentId": "fake-agent", "placement": ["kind": "tab", "spaceId": space.uuidString]])
        XCTAssertEqual(errorCode(failed), "LAUNCH_FAILED")
        XCTAssertTrue(v.model.agentInstallPanes.isEmpty, "No stale installer mark")
        // The app's Install and Launch on that pane, refused the same way, leaves none either.
        let definition = try XCTUnwrap(v.model.agentCatalog.definition("fake-agent"))
        let pane = try XCTUnwrap(v.model.snapshot.panes.keys.first { v.model.agentLaunch(paneID: $0)?.agentID == "fake-agent" })
        await v.model.installAgent(
            AgentInstallOffer(id: UUID(), paneID: pane, agent: definition, hostID: host.id, hostName: host.name, recipe: recipe, missingRequirements: [], afterInstall: false))
        XCTAssertEqual(v.model.terminals[pane]?.sessionState, .failed, "The launch was refused after the mark was set")
        XCTAssertTrue(v.model.agentInstallPanes.isEmpty, "No stale installer mark after Install and Launch")
    }

    // MARK: Scope

    func testHostScopeSpaceScopeAndRevisions() async throws {
        try await grant("full", Self.opener)
        try await grant("hidden", Self.opener, scope: GrantScope(hosts: .approved([])))
        try await grant("approved", Self.opener, scope: GrantScope(hosts: .approved([HostApproval(hostID: host.id, connectionRevision: host.connectionRevision)])))
        try await grant("narrow", Self.opener, scope: GrantScope(spaces: .spaces([])))
        try await grant("noRead", [.remoteConnect, .workspaceWrite])
        let spaces = v.model.snapshot.spaces.count
        for method in ["remote.status", "remote.open", "remote.reconnect"] {
            let hidden = try await v.code(method, ["hostId": hostID], as: "hidden")
            XCTAssertEqual(hidden, "NOT_FOUND", "\(method): a host outside scope looks missing")
        }
        _ = try await v.ok("remote.status", ["hostId": hostID], as: "approved")
        let narrow = try await v.code("remote.open", ["hostId": hostID], as: "narrow")
        XCTAssertEqual(narrow, "PERMISSION_DENIED", "Creating a space needs all or created spaces")
        let noRead = try await v.call("remote.status", ["hostId": hostID], as: "noRead")
        XCTAssertEqual(details(noRead)?["missing"] as? [String], ["host.read"])
        let stale = try await v.call("remote.open", ["hostId": hostID, "expectedRevision": v.model.snapshot.revision + 1])
        XCTAssertEqual(errorCode(stale), "CONFLICT")
        let staleHost = try await v.code("remote.reconnect", ["hostId": hostID, "expectedRevision": host.revision + 1])
        XCTAssertEqual(staleHost, "CONFLICT")
        XCTAssertEqual(v.model.snapshot.spaces.count, spaces, "Nothing was created")

        // Changing where the host connects makes the approval stale (its connectionRevision moves).
        var draft = host.draft
        draft.destination = "build-box.example"
        guard case .success(let moved) = await v.base.hosts.save(draft, editing: host) else { return XCTFail("Not saved") }
        XCTAssertGreaterThan(moved.connectionRevision, host.connectionRevision)
        for method in ["remote.status", "remote.open"] {
            let response = try await v.call(method, ["hostId": hostID], as: "approved")
            XCTAssertEqual(errorCode(response), "PERMISSION_DENIED", method)
        }
        XCTAssertEqual(v.model.snapshot.spaces.count, spaces)
    }

    /// FR-RW15 for every session method: acting on a remote workspace session, or reading its output, needs its host;
    /// the record itself stays readable by space scope, without the host's ID.
    func testRemoteSessionsNeedTheirHostForEveryAction() async throws {
        try await grant("full", Set(CapabilityV2.allCases))
        // A host this grant can't use: it isn't in the library.
        let result = try await v.model.automationExecute(.createRemoteSpace(name: "Remote", hostID: UUID()))
        let space = try XCTUnwrap(result.snapshot.spaces.first { $0.id == result.createdSpaceID })
        let pane = try XCTUnwrap(result.snapshot.tabs[space.activeTabID].flatMap { result.snapshot.panes[$0.activePaneID] })
        let session = pane.sessionID.uuidString
        let record = object(try await v.ok("session.get", ["id": session]), "session")
        XCTAssertEqual((record["launch"] as? [String: Any])?["kind"] as? String, "remoteShell")
        XCTAssertNil((record["launch"] as? [String: Any])?["hostId"], "Not this grant's host")
        let calls: [(String, [String: Any])] = [
            ("session.start", ["paneId": pane.id.uuidString]), ("session.restart", ["paneId": pane.id.uuidString]), ("session.stop", ["id": session]),
            ("session.sendInput", ["id": session, "text": "id\r"]), ("session.execute", ["id": session, "command": "id"]),
            ("session.readOutput", ["id": session, "view": "screen"]), ("session.readOutput", ["id": session, "view": "stream"])
        ]
        for (method, params) in calls {
            let code = try await v.code(method, params)
            XCTAssertEqual(code, "PERMISSION_DENIED", method)
        }
        XCTAssertEqual(v.model.snapshot.sessions[pane.sessionID]?.state, .stopped, "Nothing started")
    }
}
