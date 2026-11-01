import AppKit
import XCTest
@testable import TrellisCore
import TrellisTerminal
@testable import TrellisUI

@MainActor
private final class Notifications: DesktopNotifier {
    var posted: [DesktopNotification] = []
    func post(_ notification: DesktopNotification) { posted.append(notification) }
}

final class HostConnectionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-ssh-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    /// A stand-in for /usr/bin/ssh: records its argv as one line (one write, so
    /// concurrent fixtures cannot interleave), then stays alive or fails.
    private func fakeSSH(exitCode: Int32?) throws -> (path: String, log: URL) {
        let log = directory.appendingPathComponent("invocations.log")
        let script = directory.appendingPathComponent(exitCode == nil ? "ssh-live" : "ssh-fail")
        let tail = exitCode.map { "printf 'ssh: connect to host failed\\n'; exit \($0)" } ?? "printf 'FAKE-SSH-READY\\n'; exec /bin/sleep 30"
        try Data("#!/bin/sh\nprintf '%s\\n' \"$(printf '%s|' \"$@\")\" >> '\(log.path)'\n\(tail)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (script.path, log)
    }

    @MainActor
    private func makeModel(host: SavedHost, ssh: String) async throws -> AppWorkspaceModel {
        _ = NSApplication.shared
        // Isolated preferences: some tests change the shell-integration setting.
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: try XCTUnwrap(UserDefaults(suiteName: "trellis-host-\(UUID().uuidString)")))
        model.confirmCloseSessions = { _ in true }
        model.confirmForceSessions = { _ in true }
        model.sshExecutable = ssh
        model.resolveHost = { $0 == host.id ? host : nil }
        await model.createWindow(name: "Ops", startSession: false)
        return model
    }

    @MainActor
    private func waitUntil(_ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while try !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(try condition())
    }

    @MainActor
    func testConnectCreatesIndependentSession() async throws {
        let fake = try fakeSSH(exitCode: nil)
        let host = SavedHost(id: UUID(), draft: try HostDraft(name: "Prod", destination: "prod", user: "deploy", port: "2222").validated { _ in false }, revision: 3)
        let model = try await makeModel(host: host, ssh: fake.path)
        defer {
            model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        let window = try XCTUnwrap(model.presentation.selectedWindow?.id)

        let firstResult = await model.connect(host: host)
        let first = try XCTUnwrap(firstResult)
        let secondResult = await model.connect(host: host)
        let second = try XCTUnwrap(secondResult)
        let splitResult = await model.connect(host: host, placement: .split(.x))
        let split = try XCTUnwrap(splitResult)
        let panes = [first, second, split]
        XCTAssertEqual(Set(panes).count, 3)
        for pane in panes {
            let terminal = try XCTUnwrap(model.terminals[pane])
            try await waitUntil { try terminal.adapter.read(.retainedText).contains("FAKE-SSH-READY") }
        }
        await model.waitForUpdates()
        let snapshot = model.snapshot
        let sessions = panes.compactMap { snapshot.panes[$0]?.sessionID }
        XCTAssertEqual(Set(sessions).count, 3)
        XCTAssertEqual(Set(panes.compactMap { model.terminals[$0]?.processID }).count, 3, "Each attempt owns its own process")
        for session in sessions {
            XCTAssertEqual(snapshot.sessions[session]?.launch, .host(host.id), "The saved-host reference is kept for reconnect and restore")
            XCTAssertEqual(snapshot.sessions[session]?.state, .running)
        }
        // New tabs land in the selected window; the split stays in the second tab.
        let firstTab = try XCTUnwrap(snapshot.panes[first]?.tabID), secondTab = try XCTUnwrap(snapshot.panes[second]?.tabID)
        XCTAssertNotEqual(firstTab, secondTab)
        XCTAssertEqual(snapshot.panes[split]?.tabID, secondTab)
        XCTAssertEqual(snapshot.tabs[firstTab]?.windowID, window)
        XCTAssertEqual(snapshot.tabs[firstTab]?.title, "Prod")
        XCTAssertEqual(snapshot.tabs[secondTab]?.root.paneIDs, [second, split])
        let lines = try String(contentsOf: fake.log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines, Array(repeating: "-p|2222|-l|deploy|--|prod|", count: 3))
    }

    @MainActor
    func testConnectInNewWindowCreatesNamedWindow() async throws {
        let fake = try fakeSSH(exitCode: nil)
        let host = SavedHost(id: UUID(), draft: try HostDraft(name: "Prod", destination: "prod").validated { _ in false }, revision: 1)
        let model = try await makeModel(host: host, ssh: fake.path)
        defer {
            model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        let original = try XCTUnwrap(model.presentation.selectedWindow)
        let frozen = Date()
        model.activityNow = { frozen }

        let result = await model.connect(host: host, placement: .newWindow)
        let pane = try XCTUnwrap(result)
        let terminal = try XCTUnwrap(model.terminals[pane])
        try await waitUntil { try terminal.adapter.read(.retainedText).contains("FAKE-SSH-READY") }
        await model.waitForUpdates()
        let snapshot = model.snapshot
        XCTAssertEqual(snapshot.windows.count, 2)
        let window = try XCTUnwrap(snapshot.windows.last)
        XCTAssertNotEqual(window.id, original.id)
        XCTAssertEqual(window.name, "Prod")
        XCTAssertEqual(snapshot.activeWindowID, window.id)
        XCTAssertEqual(window.tabIDs.count, 1)
        let tab = try XCTUnwrap(snapshot.tabs[window.activeTabID])
        XCTAssertEqual(tab.title, "Prod")
        XCTAssertEqual(tab.root.paneIDs, [pane])
        let session = try XCTUnwrap(snapshot.panes[pane]?.sessionID)
        XCTAssertEqual(snapshot.sessions[session]?.launch, .host(host.id))
        XCTAssertEqual(snapshot.sessions[session]?.state, .running)
        XCTAssertEqual(snapshot.windows.first { $0.id == original.id }?.tabIDs, original.tabIDs, "The original window is untouched")
        // Output without integration or recent input marks the tab busy until it goes quiet (FR-T05).
        XCTAssertEqual(model.busyTabIDs, [tab.id])
        model.activityNow = { frozen.addingTimeInterval(PaneOutputActivity.quietInterval + 0.1) }
        try await waitUntil { model.busyTabIDs.isEmpty }
    }

    @MainActor
    func testFailedConnectionDoesNotRetry() async throws {
        let fake = try fakeSSH(exitCode: 255)
        let host = SavedHost(id: UUID(), draft: try HostDraft(name: "Down", destination: "down").validated { _ in false }, revision: 1)
        let model = try await makeModel(host: host, ssh: fake.path)
        defer {
            model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        let paneResult = await model.connect(host: host)
        let pane = try XCTUnwrap(paneResult)
        let terminal = try XCTUnwrap(model.terminals[pane])
        try await waitUntil { terminal.sessionState == .exited }
        await model.waitForUpdates()
        let session = try XCTUnwrap(model.snapshot.panes[pane]?.sessionID)
        XCTAssertEqual(terminal.exitCode, 255)
        XCTAssertEqual(model.snapshot.sessions[session]?.state, .exited)
        XCTAssertEqual(model.snapshot.sessions[session]?.exitCode, 255)
        XCTAssertEqual(model.accessibility.status, "Exited (255)")

        // No timer-driven relaunch: the failure stays inspectable and unchanged.
        try await Task.sleep(for: .milliseconds(1500))
        await model.waitForUpdates()
        XCTAssertEqual(model.snapshot.panes[pane]?.sessionID, session)
        XCTAssertEqual(model.snapshot.sessions[session]?.state, .exited)
        XCTAssertTrue(try terminal.adapter.read(.retainedText).contains("connect to host failed"))
        XCTAssertEqual(try String(contentsOf: fake.log, encoding: .utf8).split(separator: "\n").count, 1)

        // Reconnect is explicit and creates a new session in the same pane.
        await model.restartPane(pane)
        let reconnected = try XCTUnwrap(model.terminals[pane])
        try await waitUntil { reconnected.sessionState == .exited }
        XCTAssertNotEqual(model.snapshot.panes[pane]?.sessionID, session)
        XCTAssertEqual(try String(contentsOf: fake.log, encoding: .utf8).split(separator: "\n").count, 2)
    }

    @MainActor
    func testDeletedHostFailsWithoutLaunching() async throws {
        let fake = try fakeSSH(exitCode: 255)
        let host = SavedHost(id: UUID(), draft: try HostDraft(name: "Gone", destination: "gone").validated { _ in false }, revision: 1)
        let model = try await makeModel(host: host, ssh: fake.path)
        model.resolveHost = { _ in nil }
        let paneResult = await model.connect(host: host)
        let pane = try XCTUnwrap(paneResult)
        defer { model.terminals.values.forEach { $0.adapter.detach() } }
        let session = try XCTUnwrap(model.snapshot.panes[pane]?.sessionID)
        XCTAssertEqual(model.snapshot.sessions[session]?.state, .failed)
        XCTAssertEqual(model.snapshot.sessions[session]?.failureMessage, "This saved host is no longer available.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fake.log.path), "ssh was never spawned")
        // The pane itself reports Failed (not a startable Stopped pane) and explains why.
        let terminal = try XCTUnwrap(model.terminals[pane])
        XCTAssertEqual(terminal.sessionState, .failed)
        XCTAssertTrue(try terminal.adapter.read(.retainedText).contains("saved host was deleted"))
        // Reconnect stays explicit and fails the same way once more, still without spawning.
        await model.restartPane(pane)
        let next = try XCTUnwrap(model.snapshot.panes[pane]?.sessionID)
        XCTAssertNotEqual(next, session)
        XCTAssertEqual(model.snapshot.sessions[next]?.state, .failed)
        XCTAssertEqual(model.terminals[pane]?.sessionState, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fake.log.path))
    }

    @MainActor
    func testSplitConnectionIsRefusedWhileTabIsMaximized() async throws {
        let fake = try fakeSSH(exitCode: 255)
        let host = SavedHost(id: UUID(), draft: try HostDraft(name: "Max", destination: "max").validated { _ in false }, revision: 1)
        let model = try await makeModel(host: host, ssh: fake.path)
        defer { model.terminals.values.forEach { $0.adapter.detach() } }
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        await model.toggleMaximize(tab.activePaneID)
        XCTAssertEqual(model.maximizedPanes[tab.id], tab.activePaneID)
        let result = await model.connect(host: host, placement: .split(.x))
        XCTAssertNil(result)
        XCTAssertEqual(model.snapshot.tabs[tab.id]?.root.paneIDs, [tab.activePaneID], "No hidden pane is created behind the maximized one")
        XCTAssertEqual(model.errorMessage, "Restore panes before connecting in a split.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fake.log.path))
    }

    /// A stand-in ssh that runs `$SSH_ASKPASS` as its direct child twice, like a real password
    /// retry, logging what it received; without askpass variables it only logs their absence.
    private func askingSSH() throws -> (path: String, log: URL) {
        let log = directory.appendingPathComponent("askpass.log")
        let script = directory.appendingPathComponent("ssh-askpass")
        let body = """
            #!/bin/sh
            if [ -z "$SSH_ASKPASS" ]; then printf 'NO-ASKPASS\\n' >> '\(log.path)'; else
            printf 'REQUIRE=%s\\n' "$SSH_ASKPASS_REQUIRE" >> '\(log.path)'
            "$SSH_ASKPASS" "deploy@prod's password: " > '\(directory.path)/first' </dev/null
            printf 'FIRST=%s\\n' "$(cat '\(directory.path)/first')" >> '\(log.path)'
            "$SSH_ASKPASS" "deploy@prod's password: " > '\(directory.path)/second' </dev/null
            printf 'SECOND=%s\\n' "$(cat '\(directory.path)/second')" >> '\(log.path)'
            fi
            printf 'FAKE-SSH-READY\\n'; exec /bin/sleep 30

            """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (script.path, log)
    }

    @MainActor
    func testSavedPasswordReachesSSHOnlyThroughOneAskpassAnswer() async throws {
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent(AskpassBroker.helperName).path
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw XCTSkip("Run `swift build` first to build \(AskpassBroker.helperName).") }
        let fake = try askingSSH()
        var host = SavedHost(id: UUID(), draft: try HostDraft(name: "Prod", destination: "prod", user: "deploy").validated { _ in false }, revision: 3)
        host.savedPassword = SavedPasswordPolicy(requiresUserPresence: false)
        let model = try await makeModel(host: host, ssh: fake.path)
        let broker = AskpassBroker(helperPath: helper)
        defer {
            broker.stop()
            model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        model.askpass = broker
        let expected = host.connectionRevision, id = host.id
        model.savedPassword = { hostID, revision in hostID == id && revision == expected ? Data("s3cret-PASSWORD".utf8) : nil }

        let paneResult = await model.connect(host: host)
        let pane = try XCTUnwrap(paneResult)
        let terminal = try XCTUnwrap(model.terminals[pane])
        // The retry is asked on the pane itself, like ssh's own prompt; the person types it.
        try await waitUntil { try terminal.adapter.read(.retainedText).contains("deploy@prod's password:") }
        try terminal.adapter.send(Data("typed-by-person\r".utf8))
        try await waitUntil { try terminal.adapter.read(.retainedText).contains("FAKE-SSH-READY") }
        let log = try String(contentsOf: fake.log, encoding: .utf8)
        XCTAssertTrue(log.contains("REQUIRE=force"))
        XCTAssertTrue(log.contains("FIRST=s3cret-PASSWORD\n"), log)
        XCTAssertTrue(log.contains("SECOND=typed-by-person\n"), "A second prompt is never answered from the Keychain: \(log)")
        XCTAssertFalse(try terminal.adapter.read(.retainedText).contains("s3cret"), "The password never appears in the pane")
        terminal.requestTermination(force: true)
        try await waitUntil { broker.registeredCount == 0 }
    }

    @MainActor
    func testHostWithoutSavedPasswordGetsNoAskpass() async throws {
        let fake = try askingSSH()
        let host = SavedHost(id: UUID(), draft: try HostDraft(name: "Prod", destination: "prod").validated { _ in false }, revision: 1)
        let model = try await makeModel(host: host, ssh: fake.path)
        let broker = AskpassBroker(helperPath: "/fixture/trellis-askpass")
        defer {
            broker.stop()
            model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        model.askpass = broker
        model.savedPassword = { _, _ in
            XCTFail("No password is read for this host"); return nil
        }
        let paneResult = await model.connect(host: host)
        let terminal = try XCTUnwrap(model.terminals[try XCTUnwrap(paneResult)])
        try await waitUntil { try terminal.adapter.read(.retainedText).contains("FAKE-SSH-READY") }
        XCTAssertEqual(try String(contentsOf: fake.log, encoding: .utf8), "NO-ASKPASS\n")
        XCTAssertEqual(broker.registeredCount, 0)
    }

    /// A stand-in remote shell named `ssh` that prints passive, nonce-less marks the way a remote shell's own integration
    /// does (FR-SI09). It reports this fixture's directory, which exists on this Mac too, so any leak would be visible.
    private func markingSSH() throws -> String {
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("ssh")
        let body = """
            #!/bin/sh
            printf '\\033]133;A\\007\\033]7;file://web-1\(directory.path)\\007\\033]1337;RemoteHost=deploy@web-1\\007'
            printf '\\033]133;C;cmdline_url=make%%20all\\007building\\n\\033]133;D;3\\007\\033]133;A\\007MARKS-DONE\\n'
            exec /bin/sleep 30

            """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script.path
    }

    /// FR-AG15: anything printed in an SSH pane can forge a mark, so its command name stays a plain title.
    @MainActor
    func testAnUnverifiedRemoteMarkNeverNamesAnAgent() async throws {
        let ssh = try markingSSH()
        let h = try Harness()
        try await h.grant("full")
        let model = h.model
        defer {
            model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        let host = SavedHost(id: UUID(), draft: try HostDraft(name: "Prod", destination: "prod").validated { _ in false }, revision: 1)
        model.sshExecutable = ssh
        model.resolveHost = { $0 == host.id ? host : nil }
        await model.createWindow(name: "Ops", startSession: false)
        let paneResult = await model.connect(host: host)
        let pane = try XCTUnwrap(paneResult)
        let terminal = try XCTUnwrap(model.terminals[pane])
        try await waitUntil { try terminal.adapter.read(.retainedText).contains("MARKS-DONE") }
        await model.waitForUpdates()
        XCTAssertEqual(model.shellStates[pane]?.origin, .remote)

        terminal.onShellIntegrationEvent?(.commandStart(commandLine: "claude"))
        XCTAssertEqual(model.shellStates[pane]?.commandName, "claude")
        XCTAssertNil(model.detectedAgent(paneID: pane))
        XCTAssertNil(model.tabAgent(tabID: try XCTUnwrap(model.snapshot.panes[pane]?.tabID)))
        XCTAssertEqual(model.paneTitle(pane), "claude")
    }

    @MainActor
    func testRemoteMarksDriveDisplayStateButNeverLocalPaths() async throws {
        let ssh = try markingSSH()
        let h = try Harness()
        try await h.grant("full")
        let model = h.model
        defer {
            model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        let host = SavedHost(id: UUID(), draft: try HostDraft(name: "Prod", destination: "prod").validated { _ in false }, revision: 1)
        model.sshExecutable = ssh
        model.resolveHost = { $0 == host.id ? host : nil }
        await model.createWindow(name: "Ops", startSession: false)
        let paneResult = await model.connect(host: host)
        let pane = try XCTUnwrap(paneResult)
        let terminal = try XCTUnwrap(model.terminals[pane])
        try await waitUntil { try terminal.adapter.read(.retainedText).contains("MARKS-DONE") }
        await model.waitForUpdates()

        XCTAssertEqual(terminal.shellMarkOrigin, .remote)
        XCTAssertEqual(model.shellStates[pane]?.origin, .remote)
        XCTAssertEqual(model.remoteDirectory(paneID: pane), "web-1:\(directory.path)", "The header shows SSH · host:/path")
        XCTAssertEqual(model.paneTitle(pane), directory.lastPathComponent)
        XCTAssertEqual(model.failedCommandExit(paneID: pane), 3)
        XCTAssertNil(model.currentDirectory(paneID: pane), "A remote path is never this Mac's directory")
        XCTAssertNil(model.fileLinkContext(paneID: pane))
        XCTAssertNil(terminal.fileLinkContext())
        let tab = try XCTUnwrap(model.snapshot.panes[pane]?.tabID)
        XCTAssertEqual(model.snapshot.tabs[tab]?.title, "Prod", "The host-named tab keeps its title")

        let session = try XCTUnwrap(model.snapshot.panes[pane]?.sessionID)
        let reported = try result(try await h.call("session.get", ["id": session.uuidString]))
        let shell = try XCTUnwrap(reported["shellIntegration"] as? [String: Any])
        XCTAssertEqual(shell["remote"] as? Bool, true)
        XCTAssertEqual(shell["lastExitStatus"] as? Double, 3)
        XCTAssertEqual(shell["commandRunning"] as? Bool, false)
        XCTAssertNil(shell["currentDirectory"], "Never a remote path, even with execute permission")

        // A split from the SSH pane starts a local shell in the default directory, not the remote path.
        let splitResult = await model.splitPane(pane, axis: .x, startSession: false)
        let split = try XCTUnwrap(splitResult)
        XCTAssertEqual(model.snapshot.panes[split].flatMap { model.snapshot.sessions[$0.sessionID]?.launch }, .shell(directory: nil))

        // FR-SI08 and FR-T09 follow remote marks too.
        let notifier = Notifications()
        model.desktopNotifier = notifier
        model.workspaceIsFrontmost = { false }
        var now = Date(timeIntervalSince1970: 1000)
        model.activityNow = { now }
        terminal.onProgress?(TerminalProgressReport(kind: .set, value: 40))
        XCTAssertNotNil(model.progress[pane])
        terminal.onShellIntegrationEvent?(.commandStart(commandLine: "make deploy"))
        now.addTimeInterval(20)
        terminal.onShellIntegrationEvent?(.commandFinished(exitCode: 0))
        XCTAssertEqual(notifier.posted.map(\.title), ["Command finished"])
        XCTAssertEqual(notifier.posted.map(\.body), ["make ran for 20 s"])
        terminal.onShellIntegrationEvent?(.promptStart(directory: nil))
        XCTAssertNil(model.progress[pane], "Progress clears at the next remote prompt")
    }

    @MainActor
    func testSSHProcessPaneTakesRemoteMarksAndNeverSavesTheirDirectory() async throws {
        let ssh = try markingSSH()
        _ = NSApplication.shared
        let state = directory.appendingPathComponent("state")
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-remote-\(UUID().uuidString)"))
        func makeModel() async throws -> AppWorkspaceModel {
            let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: state))
            _ = await model.loadWorkspace()
            model.confirmCloseSessions = { _ in true }
            return model
        }
        let model = try await makeModel()
        defer {
            model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        await model.createWindow(name: "Direct", startSession: false)
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        // `ssh -l` matches the login-shell argument list that FR-SI07 would otherwise resume in a reported directory.
        let launch = SessionLaunch.process(executable: ssh, arguments: ["-l"], directory: "/tmp")
        _ = try await model.service.execute(.configureStoppedSession(paneID: pane, launch: launch))
        await model.refresh()
        await model.start(paneID: pane)
        let terminal = try XCTUnwrap(model.terminals[pane])
        try await waitUntil { try terminal.adapter.read(.retainedText).contains("MARKS-DONE") }
        XCTAssertEqual(model.remoteDirectory(paneID: pane), "web-1:\(directory.path)")
        XCTAssertEqual(model.failedCommandExit(paneID: pane), 3)
        XCTAssertNil(model.currentDirectory(paneID: pane))
        XCTAssertNil(model.fileLinkContext(paneID: pane))

        model.stopAll()
        let closed = await model.shutdown()
        XCTAssertTrue(closed)
        let saved = await model.flushWorkspaceSave()
        XCTAssertTrue(saved)
        let restored = try await makeModel()
        defer { restored.terminals.values.forEach { $0.adapter.detach() } }
        XCTAssertEqual(restored.snapshot.panes[pane].flatMap { restored.snapshot.sessions[$0.sessionID]?.launch }, launch, "The remote path is never saved")
    }

    @MainActor
    func testLocalPaneIgnoresTheSameNonceLessMarks() async throws {
        let ssh = try markingSSH()
        let model = try await makeModel(host: SavedHost(id: UUID(), draft: try HostDraft(name: "X", destination: "x").validated { _ in false }, revision: 1), ssh: ssh)
        defer {
            model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        _ = try await model.service.execute(.configureStoppedSession(paneID: pane, launch: .process(executable: "/bin/sh", arguments: [ssh], directory: "/tmp")))
        await model.refresh()
        await model.start(paneID: pane)
        let terminal = try XCTUnwrap(model.terminals[pane])
        try await waitUntil { try terminal.adapter.read(.retainedText).contains("MARKS-DONE") }
        await model.waitForUpdates()
        XCTAssertNil(terminal.shellMarkOrigin)
        XCTAssertNil(model.shellStates[pane], "Forged marks in a local pane change nothing")
        XCTAssertNil(model.failedCommandExit(paneID: pane))
        XCTAssertNil(model.remoteDirectory(paneID: pane))
        XCTAssertEqual(model.paneTitle(pane), WorkspaceTab.defaultTitle)
        XCTAssertNotNil(model.fileLinkContext(paneID: pane))
    }

    @MainActor
    func testDisabledShellIntegrationIgnoresRemoteMarks() async throws {
        let ssh = try markingSSH()
        let host = SavedHost(id: UUID(), draft: try HostDraft(name: "Prod", destination: "prod").validated { _ in false }, revision: 1)
        let model = try await makeModel(host: host, ssh: ssh)
        model.setShellIntegrationEnabled(false)
        defer {
            model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        let paneResult = await model.connect(host: host)
        let pane = try XCTUnwrap(paneResult)
        let terminal = try XCTUnwrap(model.terminals[pane])
        try await waitUntil { try terminal.adapter.read(.retainedText).contains("MARKS-DONE") }
        XCTAssertNil(terminal.shellMarkOrigin)
        XCTAssertNil(model.shellStates[pane])
        XCTAssertNil(model.remoteDirectory(paneID: pane))
    }

    private final class Secrets: HostSecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UUID: Data] = [:]
        func store(_ password: Data, hostID: UUID) throws { lock.withLock { values[hostID] = password } }
        func read(hostID: UUID) throws -> Data? { lock.withLock { values[hostID] } }
        func remove(hostID: UUID) { _ = lock.withLock { values.removeValue(forKey: hostID) } }
    }

    private struct Gate: UserPresenceGate {
        let allow: Bool
        func authorize(reason: String) async -> Bool { allow }
    }

    @MainActor
    func testTurningOffTouchIDRequirementNeedsConfirmation() async throws {
        let model = HostListModel(library: HostLibrary(storage: MemoryHosts(), secrets: Secrets()))
        let created = try await model.library.create(HostDraft(name: "Prod", destination: "prod"))
        let gated = try await model.library.setPassword(id: created.id, .save(Data("pw".utf8), requiresUserPresence: true), expectedRevision: created.revision)
        model.userPresence = Gate(allow: false)
        let declined = await model.setPassword(gated, .policy(requiresUserPresence: false))
        XCTAssertEqual(declined, .failure(.notAuthorized))
        let unchanged = await model.library.hosts.first
        XCTAssertEqual(unchanged?.savedPassword?.requiresUserPresence, true)
        model.userPresence = Gate(allow: true)
        let allowed = await model.setPassword(gated, .policy(requiresUserPresence: false))
        XCTAssertEqual(try allowed.get().savedPassword?.requiresUserPresence, false)
    }
}
