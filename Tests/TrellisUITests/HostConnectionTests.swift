import AppKit
import XCTest
import TrellisCore
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
}
