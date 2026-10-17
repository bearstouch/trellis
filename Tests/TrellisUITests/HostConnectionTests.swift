import AppKit
import XCTest
@testable import TrellisCore
import TrellisTerminal
@testable import TrellisUI

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
        let model = AppWorkspaceModel(store: try WorkspaceStore())
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
