import AppKit
import Darwin
import TrellisBroker
import TrellisControl
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
        let spaceID = try XCTUnwrap(opened)
        XCTAssertEqual(model.snapshot.spaces.first { $0.id == spaceID }?.remoteHostID, host.id)
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
        XCTAssertEqual(relaunched.snapshot.spaces.first?.remoteHostID, host.id, "The binding was saved")
        // Sessions are adopted one after another as the host answers.
        try await until("both panes came back") { relaunched.terminals[split]?.remoteTransport != nil && relaunched.terminals[split]?.sessionState == .running }
    }

    private func launch(ofPane id: UUID, in model: AppWorkspaceModel) -> SessionLaunch? {
        model.snapshot.panes[id].flatMap { model.snapshot.sessions[$0.sessionID]?.launch }
    }

    /// FR-RW04: a source pane without integration marks (an agent, a shell before its first prompt) still gives its folder on the host.
    func testNewTabAndSplitFromAPaneWithoutMarksStartInItsFolderOnTheHost() async throws {
        let project = home + "/code/keel"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        let model = try makeModel()
        _ = await model.loadWorkspace()
        let opened = await model.openRemoteWorkspace(host: host)
        let spaceID = try XCTUnwrap(opened)
        try await until("the host is connected") { model.remoteLinks[host.id] == .connected }

        // A project's agent pane, stopped so nothing depends on an agent being installed; it never has marks.
        let created = await model.createTab(spaceID: spaceID, startSessions: false)
        let agentTab = try XCTUnwrap(created)
        let agentPane = try XCTUnwrap(model.snapshot.tabs[agentTab]?.activePaneID)
        _ = try await model.service.execute(.configureStoppedSession(paneID: agentPane, launch: .agent(AgentLaunch(agentID: "fake", directory: project, hostID: host.id))))
        await model.refresh()
        XCTAssertNil(model.remoteWorkingDirectory(paneID: agentPane))

        let newTab = await model.createTab()
        let tabPane = try XCTUnwrap(newTab.flatMap { model.snapshot.tabs[$0]?.activePaneID })
        guard case .remoteShell(host.id, project)? = launch(ofPane: tabPane, in: model) else { return XCTFail("The new tab isn't on the host in the project folder") }
        XCTAssertEqual(model.focusedMachine, .host(host.name, link: .connected), "The bottom bar names the host")
        try await until("the new tab's shell reports the folder") { model.remoteWorkingDirectory(paneID: tabPane) == project }

        await model.selectTab(agentTab)
        let newSplit = await model.splitPane(agentPane, axis: .x)
        let splitPane = try XCTUnwrap(newSplit)
        guard case .remoteShell(host.id, project)? = launch(ofPane: splitPane, in: model) else { return XCTFail("The split isn't on the host in the project folder") }
        try await until("the split's shell reports the folder") { model.remoteWorkingDirectory(paneID: splitPane) == project }
    }

    /// API v2 `agent.start` in a remote workspace runs the agent on the host through its helper, in the folder asked for,
    /// exactly as the app's Agents view does there (FR-AG12, methods.md#agents).
    func testAgentStartThroughTheAPIRunsTheAgentOnTheHost() async throws {
        let hosts = HostListModel(library: HostLibrary(storage: MemoryHosts()))
        guard case .success(let saved) = await hosts.save(HostDraft(name: "build-box", destination: "build-box"), editing: nil) else { return XCTFail("No host") }
        host = saved
        let project = home + "/code/agent"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        let agent = home + "/fake-agent"
        try "#!/bin/sh\nprintf 'REMOTE-AGENT-UP %s %s\\n' \"$PWD\" \"$*\"\nexec /bin/sleep 30\n".write(toFile: agent, atomically: true, encoding: .utf8)
        chmod(agent, 0o755)
        let model = try makeModel()
        _ = await model.loadWorkspace()
        let opened = await model.openRemoteWorkspace(host: host)
        let spaceID = try XCTUnwrap(opened)
        try await until("the host is connected") { model.remoteLinks[host.id] == .connected }
        model.agentCatalog = AgentCatalogSnapshot(definitions: [AgentDefinition(id: "fake", name: "Fake", executable: agent, resumeArguments: ["--continue"])])

        let grants = GrantStore(url: nil, secrets: NoSecrets(), now: Date.init)
        let handler = AuthorizingControlHandler(
            grants: grants, domain: AutomationServiceV2(model: model, hosts: hosts), idempotency: IdempotencyCache(now: Date.init))
        let token = try await grants.create(GrantSettings(name: "Bot", capabilities: Set(CapabilityV2.allCases)), lifetime: 3600).token
        let session = ControlSession(peerUID: geteuid(), handler: handler)
        var id = 0
        func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            id += 1
            var data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            data.append(0x0A)
            let output = await session.receive(data).output
            return try XCTUnwrap(JSONSerialization.jsonObject(with: output.prefix { $0 != 0x0A }) as? [String: Any])
        }
        _ = try await call("auth.authenticate", ["protocolVersion": 2, "token": token])
        let response = try await call("agent.start", ["agentId": "fake", "placement": ["kind": "tab", "spaceId": spaceID.uuidString], "directory": project, "resume": true])
        let started = try XCTUnwrap(response["result"] as? [String: Any], "\(response)")
        let run = try XCTUnwrap(started["run"] as? [String: Any])
        XCTAssertEqual(run["origin"] as? String, "managed")
        let launch = try XCTUnwrap((started["session"] as? [String: Any])?["launch"] as? [String: Any])
        XCTAssertEqual(launch["machine"] as? [String: String], ["kind": "remote", "hostId": host.id.uuidString.lowercased()])
        let pane = try XCTUnwrap(UUID(uuidString: try XCTUnwrap((started["pane"] as? [String: Any])?["id"] as? String)))
        guard case .agent(let saved)? = self.launch(ofPane: pane, in: model), saved.hostID == host.id, saved.directory == project else { return XCTFail("Not an agent on the host") }
        let terminal = try XCTUnwrap(model.terminals[pane])
        try await until("the agent runs on the host, in the folder, resumed") {
            terminal.screenText.contains("REMOTE-AGENT-UP \(project) --continue")
        }
        XCTAssertNotNil(terminal.remoteTransport, "Through the host's helper")
    }

    /// FR-RW04: a shell with no marks yet gives the folder it started in; one that started nowhere in particular leaves home to the helper.
    func testNewTabFromAShellWithoutMarksStartsInItsStartingFolderOrHome() async throws {
        let project = home + "/code/keel"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        let model = try makeModel()
        _ = await model.loadWorkspace()
        let opened = await model.openRemoteWorkspace(host: host)
        let spaceID = try XCTUnwrap(opened)
        try await until("the host is connected") { model.remoteLinks[host.id] == .connected }

        // Stopped, so it can't have reported a directory.
        let created = await model.createTab(spaceID: spaceID, startSessions: false)
        let source = try XCTUnwrap(created.flatMap { model.snapshot.tabs[$0]?.activePaneID })
        let fromNoFolder = await model.createTab()
        let homePane = try XCTUnwrap(fromNoFolder.flatMap { model.snapshot.tabs[$0]?.activePaneID })
        guard case .remoteShell(host.id, nil)? = launch(ofPane: homePane, in: model) else { return XCTFail("A source with no folder should leave the new tab in home") }

        _ = try await model.service.execute(.configureStoppedSession(paneID: source, launch: .remoteShell(hostID: host.id, directory: project)))
        await model.refresh()
        await model.selectTab(try XCTUnwrap(created))
        XCTAssertNil(model.remoteWorkingDirectory(paneID: source))
        let fromFolder = await model.createTab()
        let folderPane = try XCTUnwrap(fromFolder.flatMap { model.snapshot.tabs[$0]?.activePaneID })
        guard case .remoteShell(host.id, project)? = launch(ofPane: folderPane, in: model) else { return XCTFail("The new tab isn't in the shell's starting folder") }
    }

    /// FR-RW04: where the shell is now wins over where it started.
    func testNewTabPrefersTheShellsAuthenticatedDirectoryOverItsStartingFolder() async throws {
        let project = home + "/code/keel", work = home + "/code/keel/sub dir"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let model = try makeModel()
        _ = await model.loadWorkspace()
        _ = await model.openRemoteWorkspace(host: host, directory: project)
        let pane = try XCTUnwrap(model.presentation.activePane)
        let terminal = try XCTUnwrap(model.terminals[pane.id])
        try await until("the shell reports its starting folder") { model.remoteWorkingDirectory(paneID: pane.id) == project }
        try terminal.adapter.send(Data("cd 'sub dir'\r".utf8))
        try await until("the shell reports its new directory") { model.remoteWorkingDirectory(paneID: pane.id) == work }

        let newTab = await model.createTab()
        let tabPane = try XCTUnwrap(newTab.flatMap { model.snapshot.tabs[$0]?.activePaneID })
        guard case .remoteShell(host.id, work)? = launch(ofPane: tabPane, in: model) else { return XCTFail("The new tab didn't follow the shell") }
    }

    private func makeDirectoryHistory() -> DirectoryHistory {
        DirectoryHistory(stateDirectory: URL(fileURLWithPath: root + "/history"), sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }, mounts: { [] })
    }

    /// FR-DJ01, FR-DJ02, FR-DJ06, FR-DJ07: visits on a host are that host's, and each row acts only on its own machine.
    func testDirectoryJumpActsOnEachRowsOwnMachine() async throws {
        let model = try makeModel()
        model.directoryHistory = makeDirectoryHistory()
        _ = await model.loadWorkspace()
        let opened = await model.openRemoteWorkspace(host: host)
        let hostSpace = try XCTUnwrap(opened)
        let pane = try XCTUnwrap(model.presentation.activePane)
        let terminal = try XCTUnwrap(model.terminals[pane.id])
        try await until("the remote shell runs") { terminal.sessionState == .running }
        try await until("the first prompt") { model.remoteWorkingDirectory(paneID: pane.id) != nil }

        // /usr passes the skip rules, where the test's temporary folders don't.
        try terminal.adapter.send(Data("cd /usr\r".utf8))
        try await until("the visit is remembered for the host") { model.directoryEntries.contains { $0.path == "/usr" && $0.machine == self.host.id.uuidString } }
        XCTAssertFalse(model.directoryEntries.contains { $0.machine == "local" }, "A host's path is never this Mac's")

        // Return, same machine, idle: `cd` in the same pane.
        let work = home + "/work dir"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try await until("the shell is idle") { model.taskAvailability(paneID: pane.id) == .ready }
        var tabs = model.snapshot.tabs.count
        await model.jumpToDirectory(path: work, machine: host.id.uuidString, modifier: .none)
        try await until("the shell moved") { model.remoteWorkingDirectory(paneID: pane.id) == work }
        XCTAssertEqual(model.snapshot.tabs.count, tabs)

        // ⌘Return: a new tab on the host, in that directory.
        await model.jumpToDirectory(path: "/usr", machine: host.id.uuidString, modifier: .command)
        XCTAssertEqual(model.snapshot.tabs.count, tabs + 1)
        let tabPane = try XCTUnwrap(model.presentation.activePane?.id)
        guard case .remoteShell(host.id, "/usr")? = model.snapshot.panes[tabPane].flatMap({ model.snapshot.sessions[$0.sessionID]?.launch }) else {
            return XCTFail("The tab isn't on the host, in that directory")
        }
        try await until("the tab's shell starts there") { model.remoteWorkingDirectory(paneID: tabPane) == "/usr" }
        tabs += 1

        // A local row from a host's pane: never typed there, and with no local window, a new one.
        let local = root + "/local folder"
        try FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)
        let before = terminal.screenText
        await model.jumpToDirectory(path: local, machine: "local", modifier: .none)
        XCTAssertEqual(model.snapshot.spaces.count, 2)
        let localSpace = try XCTUnwrap(model.snapshot.spaces.first { $0.id == model.snapshot.activeSpaceID })
        XCTAssertNil(localSpace.remoteHostID)
        let localPane = try XCTUnwrap(model.presentation.activePane?.id)
        XCTAssertEqual(model.directoryMachine(paneID: localPane), .local)
        XCTAssertEqual(terminal.screenText, before)

        // A host's row from a local pane: a tab in the host's window, whatever Return would type here.
        await model.jumpToDirectory(path: work, machine: host.id.uuidString, modifier: .none)
        XCTAssertEqual(model.snapshot.activeSpaceID, hostSpace)
        XCTAssertEqual(model.snapshot.tabs.count, tabs + 2, "The local space's tab and this one")
        let backPane = try XCTUnwrap(model.presentation.activePane?.id)
        XCTAssertEqual(model.directoryMachine(paneID: backPane), .host(host.id))
        try await until("the shell starts there") { model.remoteWorkingDirectory(paneID: backPane) == work }

        // ⌥Return from another machine's pane is a new tab, never a split that mixes machines.
        await model.selectSpace(localSpace.id)
        let panes = localSpace.tabIDs.flatMap { model.snapshot.tabs[$0]?.root.paneIDs ?? [] }.count
        await model.jumpToDirectory(path: "/usr", machine: host.id.uuidString, modifier: .option)
        XCTAssertEqual(model.snapshot.activeSpaceID, hostSpace)
        XCTAssertEqual(model.snapshot.spaces.first { $0.id == localSpace.id }.map { $0.tabIDs.flatMap { model.snapshot.tabs[$0]?.root.paneIDs ?? [] }.count }, panes)
        model.terminals[localPane]?.requestTermination(force: true)
    }

    /// FR-DJ06: with no window on the host, a row opens a remote workspace in that directory.
    func testDirectoryJumpOpensARemoteWorkspaceWhenTheHostHasNoSpace() async throws {
        let model = try makeModel()
        _ = await model.loadWorkspace()
        let work = home + "/work"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        await model.jumpToDirectory(path: work, machine: host.id.uuidString, modifier: .none)
        XCTAssertEqual(model.snapshot.spaces.last?.remoteHostID, host.id)
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        try await until("the shell starts there") { model.remoteWorkingDirectory(paneID: pane) == work }
    }

    /// FR-DJ01: reattaching replays the session's marks, which are history, not visits. Nor is the next prompt in that directory.
    func testReplayedPromptsAreNotVisits() async throws {
        let history = makeDirectoryHistory()
        let model = try makeModel()
        model.directoryHistory = history
        _ = await model.loadWorkspace()
        _ = await model.openRemoteWorkspace(host: host)
        let pane = try XCTUnwrap(model.presentation.activePane)
        let terminal = try XCTUnwrap(model.terminals[pane.id])
        try await until("the remote shell runs") { terminal.sessionState == .running }
        try await until("the first prompt") { model.remoteWorkingDirectory(paneID: pane.id) != nil }
        try terminal.adapter.send(Data("cd /usr\r".utf8))
        try await until("the visit") { model.directoryEntries.first { $0.path == "/usr" }?.visits == 1 }
        let detached = await model.detachForQuit()
        XCTAssertTrue(detached)

        let relaunched = try makeModel()
        relaunched.directoryHistory = history
        _ = await relaunched.loadWorkspace()
        let restored = try XCTUnwrap(relaunched.terminals[pane.id])
        try await until("the session is adopted") { restored.sessionState == .running && relaunched.remoteLinks[host.id] == .connected }
        try await until("the replayed directory") { relaunched.remoteWorkingDirectory(paneID: pane.id) == "/usr" }
        try restored.adapter.send(Data("true\r".utf8))
        try await until("the shell ran the command") { relaunched.shellStates[pane.id]?.lastExitCode != nil || restored.screenText.contains("true") }
        try await Task.sleep(for: .milliseconds(400))
        let entries = await history.all()
        XCTAssertEqual(entries.first { $0.path == "/usr" }?.visits, 1)
    }

    /// FR-RW01: the command palette opens a saved host as a remote workspace, next to its Connect item.
    func testThePaletteOpensARemoteWorkspace() async throws {
        let model = try makeModel()
        _ = await model.loadWorkspace()
        let items = model.commandPaletteItems.filter { $0.kind == .host }
        XCTAssertEqual(items.map(\.target), [.host(host.id), .remoteWorkspace(host.id)])
        XCTAssertEqual(items.last?.title, "Open Remote Workspace: build-box")
        await model.performCommandPaletteTarget(.remoteWorkspace(host.id), modifier: .none)
        XCTAssertEqual(model.snapshot.spaces.last?.remoteHostID, host.id)
        let pane = try XCTUnwrap(model.presentation.activePane)
        let terminal = try XCTUnwrap(model.terminals[pane.id])
        try await until("the remote shell runs") { terminal.sessionState == .running }
        let remote = model.remoteHosts
        model.remoteHosts = nil
        XCTAssertEqual(model.commandPaletteItems.filter { $0.kind == .host }.map(\.target), [.host(host.id)], "Only when remote workspaces exist")
        model.remoteHosts = remote  // so tearDown can stop the host's sessions
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
    func testSpaceCloseDetachesRemoteSessionsAndLeavesThemClosable() async throws {
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
        XCTAssertEqual(terminal.sessionState, .running, "Space close detaches remote sessions (FR-RW06)")
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
        async let first = model.reconnectRemote(hostID: hostID)
        async let second = model.reconnectRemote(hostID: hostID)
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
        let result = try await h.model.service.execute(.createRemoteSpace(name: "Remote", hostID: UUID()))
        h.model.publish(result.snapshot)
        let space = try XCTUnwrap(result.snapshot.spaces.first { $0.id == result.createdSpaceID })
        let tab = try XCTUnwrap(result.snapshot.tabs[space.activeTabID])
        let pane = try XCTUnwrap(result.snapshot.panes[tab.activePaneID])
        let start = try await h.code("session.start", ["paneId": pane.id.uuidString])
        XCTAssertEqual(start, "PERMISSION_DENIED")
        let input = try await h.code("session.sendInput", ["id": pane.sessionID.uuidString, "text": "id\n"])
        XCTAssertEqual(input, "PERMISSION_DENIED")
        let execute = try await h.code("session.execute", ["id": pane.sessionID.uuidString, "command": "id"])
        XCTAssertEqual(execute, "PERMISSION_DENIED")
        XCTAssertEqual(h.model.snapshot.sessions[pane.sessionID]?.state, .stopped, "Nothing started")
    }

    func testInputToAHostThatIsNotConnectedFailsAsRemoteDisconnected() async throws {
        let h = try Harness()
        defer { h.discardPreferences() }
        try await h.grant("full")
        guard case .success(let host) = await h.hosts.save(HostDraft(name: "build-box", destination: "build-box"), editing: nil) else { return XCTFail("No host") }
        let created = try await h.model.service.execute(.createRemoteSpace(name: "Remote", hostID: host.id))
        h.model.publish(created.snapshot)
        let space = try XCTUnwrap(created.snapshot.spaces.first { $0.id == created.createdSpaceID })
        let pane = try XCTUnwrap(created.snapshot.tabs[space.activeTabID].flatMap { created.snapshot.panes[$0.activePaneID] })
        h.model.remoteLinks[host.id] = .reconnecting(attempt: 2, at: Date())
        let session: [String: Any] = try await h.value("session", "session.get", ["id": pane.sessionID.uuidString])
        XCTAssertEqual((session["launch"] as? [String: Any])?["kind"] as? String, "remoteShell")
        XCTAssertEqual((session["launch"] as? [String: Any])?["hostId"] as? String, lower(host.id))
        let remote: [String: Any] = try await h.value("remote", "remote.status", ["hostId": lower(host.id)])
        XCTAssertEqual((remote["link"] as? [String: Any])?["state"] as? String, "reconnecting")
        let stopped = try await h.code("session.sendInput", ["id": pane.sessionID.uuidString, "text": "id\n"])
        XCTAssertNotEqual(stopped, "REMOTE_DISCONNECTED", "A session that isn't running fails as not running, not as retryable")
        // Running on the host while its link is down.
        h.model.publish(try await h.model.service.execute(.adoptRunningSession(sessionID: pane.sessionID, processID: 4242)).snapshot)
        let input = try await h.code("session.sendInput", ["id": pane.sessionID.uuidString, "text": "id\n"])
        XCTAssertEqual(input, "REMOTE_DISCONNECTED", "Never queued for later (FR-RW15)")
        let execute = try await h.code("session.execute", ["id": pane.sessionID.uuidString, "command": "id"])
        XCTAssertEqual(execute, "REMOTE_DISCONNECTED")
    }
}
