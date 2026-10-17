import AppKit
import Foundation
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// A fake `zsh` reports what it was launched with, so no real dotfiles are read.
final class ShellIntegrationUITests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-si-ui-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project dir"), withIntermediateDirectories: true)
        let shell = root.appendingPathComponent("bin/zsh")
        try """
        #!/bin/sh
        printf 'ARGS=%s NONCE=%s ZDOTDIR=%s\\n' "$*" "${TRELLIS_SHELL_INTEGRATION_NONCE:+set}" "${ZDOTDIR-}"
        printf '\\nPWD=%s|\\n' "$(/bin/pwd -P | /usr/bin/sed 's|.*/||')"
        exec /bin/sleep 30
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @MainActor
    private func makeModel(enabled: Bool? = nil, persistence: WorkspacePersistence? = nil) async throws -> AppWorkspaceModel {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-si-\(UUID().uuidString)"))
        if let enabled { preferences.set(enabled, forKey: "terminal.shellIntegration") }
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: persistence)
        if persistence != nil { _ = await model.loadWorkspace() }
        // Never show the modal close confirmation in tests.
        model.confirmCloseSessions = { _ in true }
        let saved = await model.saveLaunchSettings(shell: root.appendingPathComponent("bin/zsh").path, directory: root.path)
        XCTAssertTrue(saved)
        return model
    }

    @MainActor
    private func cleanUp(_ model: AppWorkspaceModel) {
        model.terminals.values.forEach {
            $0.requestTermination(force: true); $0.adapter.detach()
        }
    }

    /// Waits for `text`; the fake shell prints its `ARGS=` line before `PWD=`, so wait for `PWD=` to assert a whole `ARGS=` line.
    @MainActor
    private func output(_ model: AppWorkspaceModel, _ pane: UUID, containing text: String) async throws -> String {
        let terminal = try XCTUnwrap(model.terminals[pane])
        let deadline = Date().addingTimeInterval(5)
        while !((try? terminal.adapter.read(.retainedText))?.contains(text) ?? false), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return try terminal.adapter.read(.retainedText)
    }

    @MainActor
    private func emit(_ model: AppWorkspaceModel, _ pane: UUID, _ events: ShellIntegrationEvent...) throws {
        let terminal = try XCTUnwrap(model.terminals[pane])
        for event in events { terminal.onShellIntegrationEvent?(event) }
    }

    @MainActor
    func testLocalShellIsInjectedByDefaultAndNotWhenDisabled() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        XCTAssertTrue(model.shellIntegrationEnabled)
        await model.createWindow(name: "On")
        let first = try XCTUnwrap(model.presentation.activePane?.id)
        let injected = try await output(model, first, containing: "PWD=")
        XCTAssertTrue(injected.contains("NONCE=set"), injected)
        XCTAssertTrue(injected.contains("ShellIntegration/zsh"), injected)

        model.setShellIntegrationEnabled(false)
        await model.createWindow(name: "Off")
        let second = try XCTUnwrap(model.presentation.activePane?.id)
        let plain = try await output(model, second, containing: "PWD=")
        XCTAssertTrue(plain.contains("ARGS=-l NONCE= ZDOTDIR=\n"), plain)

        let restored = try await makeModel()
        defer { cleanUp(restored) }
        XCTAssertTrue(restored.shellIntegrationEnabled, "a fresh preference domain defaults to on")
    }

    @MainActor
    func testCustomProcessesAndFixturesAreNeverInjected() async throws {
        let model = try await makeModel(enabled: true)
        defer { cleanUp(model) }
        await model.createWindow(name: "Custom", startSession: false)
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        let fake = root.appendingPathComponent("bin/zsh").path
        _ = try await model.service.execute(.configureStoppedSession(paneID: pane, launch: .process(executable: fake, arguments: ["-i"], directory: "/tmp")))
        await model.refresh()
        await model.start(paneID: pane)
        let text = try await output(model, pane, containing: "PWD=")
        XCTAssertTrue(text.contains("ARGS=-i NONCE= ZDOTDIR=\n"), text)
    }

    @MainActor
    func testALoginShellOtherThanTheDefaultKeepsIntegration() async throws {
        // A pane frozen with the previous default shell (picked before a Settings change) still restarts integrated.
        let bash = root.appendingPathComponent("bin/bash")
        try FileManager.default.copyItem(at: root.appendingPathComponent("bin/zsh"), to: bash)
        let model = try await makeModel()
        defer { cleanUp(model) }
        await model.createWindow(name: "Previous shell", startSession: false)
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        _ = try await model.service.execute(.configureStoppedSession(paneID: pane, launch: .process(executable: bash.path, arguments: ["-l"], directory: "/tmp")))
        await model.refresh()
        await model.start(paneID: pane)
        let text = try await output(model, pane, containing: "PWD=")
        XCTAssertTrue(text.contains("ARGS=--rcfile "), text)
        XCTAssertTrue(text.contains("NONCE=set"), text)
    }

    @MainActor
    func testSplitsAndNewTabsStartInTheReportedDirectory() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        await model.createWindow(name: "Work")
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        _ = try await output(model, pane, containing: "ARGS=")
        let project = root.appendingPathComponent("project dir").path
        try emit(model, pane, .promptStart(directory: project))
        XCTAssertEqual(model.currentDirectory(paneID: pane), project)

        let splitResult = await model.splitPane(pane, axis: .x)
        let split = try XCTUnwrap(splitResult)
        let splitText = try await output(model, split, containing: "|")
        XCTAssertTrue(splitText.contains("PWD=project dir|"), splitText)

        _ = await model.selectPane(pane)
        let tabResult = await model.createTab()
        let tab = try XCTUnwrap(tabResult)
        let tabPane = try XCTUnwrap(model.snapshot.tabs[tab]?.activePaneID)
        let tabText = try await output(model, tabPane, containing: "|")
        XCTAssertTrue(tabText.contains("PWD=project dir|"), tabText)

        // A pane without reports, or a vanished directory, falls back to the default.
        let plainResult = await model.splitPane(tabPane, axis: .y)
        let plain = try XCTUnwrap(plainResult)
        let plainText = try await output(model, plain, containing: "|")
        XCTAssertTrue(plainText.contains("PWD=\(root.lastPathComponent)|"), plainText)
        try emit(model, plain, .promptStart(directory: root.appendingPathComponent("gone").path))
        let fallbackResult = await model.splitPane(plain, axis: .x)
        let fallback = try XCTUnwrap(fallbackResult)
        let fallbackText = try await output(model, fallback, containing: "|")
        XCTAssertTrue(fallbackText.contains("PWD=\(root.lastPathComponent)|"), fallbackText)
    }

    @MainActor
    func testAutomaticTitlesRespectRenamedTabs() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        await model.createWindow(name: "Titles")
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        let pane = tab.activePaneID
        XCTAssertEqual(model.displayTitle(tab), "Terminal", "no claims without integration (INT-01)")
        try emit(model, pane, .promptStart(directory: root.appendingPathComponent("project dir").path))
        XCTAssertEqual(model.displayTitle(try XCTUnwrap(model.presentation.selectedTab)), "project dir")
        XCTAssertEqual(model.paneTitle(pane), "project dir")
        try emit(model, pane, .commandStart(commandLine: "/usr/bin/vim notes.txt"))
        XCTAssertEqual(model.displayTitle(try XCTUnwrap(model.presentation.selectedTab)), "vim")
        XCTAssertEqual(model.accessibility.tabs.first?.label, "Tab vim")
        try emit(model, pane, .commandFinished(exitCode: 0), .promptStart(directory: FileManager.default.homeDirectoryForCurrentUser.path))
        XCTAssertEqual(model.displayTitle(try XCTUnwrap(model.presentation.selectedTab)), "~")

        await model.renameTab(tab.id, title: "Server")
        try emit(model, pane, .commandStart(commandLine: "top"))
        XCTAssertEqual(model.displayTitle(try XCTUnwrap(model.presentation.selectedTab)), "Server")
        XCTAssertEqual(model.paneTitle(pane), "top")
    }

    @MainActor
    func testFailedCommandIsAnnouncedAndClearsOnTheNextCommand() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        await model.createWindow(name: "Status")
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        _ = try await output(model, pane, containing: "ARGS=")
        try emit(model, pane, .promptStart(directory: "/tmp"), .commandStart(commandLine: "false"), .commandFinished(exitCode: 1))
        XCTAssertEqual(model.failedCommandExit(paneID: pane), 1)
        XCTAssertTrue(model.accessibility.panes.first?.value.contains("Last command failed (exit 1)") == true, "\(model.accessibility.panes)")
        try emit(model, pane, .promptStart(directory: "/tmp"), .commandStart(commandLine: "true"))
        XCTAssertNil(model.failedCommandExit(paneID: pane))
        try emit(model, pane, .commandFinished(exitCode: 0))
        XCTAssertNil(model.failedCommandExit(paneID: pane))
    }

    @MainActor
    func testShellStateIsDroppedWhenTheSessionEndsOrThePaneCloses() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        await model.createWindow(name: "Lifecycle")
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        _ = try await output(model, pane, containing: "ARGS=")
        try emit(model, pane, .promptStart(directory: "/tmp"))
        XCTAssertNotNil(model.shellStates[pane])
        let terminal = try XCTUnwrap(model.terminals[pane])
        terminal.requestTermination(force: true)
        let deadline = Date().addingTimeInterval(5)
        while model.shellStates[pane] != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(model.shellStates[pane], "an exited shell's directory is no longer claimed")

        await model.restartPane(pane)
        try emit(model, pane, .promptStart(directory: "/tmp"))
        await model.closePane(pane)
        XCTAssertTrue(model.shellStates.isEmpty)
    }

    @MainActor
    func testQuitSavesTheLastReportedDirectoryAndRestoreStartsThere() async throws {
        let state = root.appendingPathComponent("state")
        let model = try await makeModel(persistence: WorkspacePersistence(directory: state))
        defer { cleanUp(model) }
        await model.createWindow(name: "Resume")
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        _ = try await output(model, pane, containing: "ARGS=")
        let project = root.appendingPathComponent("project dir").path
        try emit(model, pane, .promptStart(directory: project))

        // Unreported panes, vanished directories and custom processes keep their launch directory.
        let quietResult = await model.splitPane(pane, axis: .x, startSession: false)
        let quiet = try XCTUnwrap(quietResult)
        let goneResult = await model.splitPane(quiet, axis: .y)
        let gone = try XCTUnwrap(goneResult)
        _ = try await output(model, gone, containing: "ARGS=")
        let vanished = root.appendingPathComponent("vanished")
        try FileManager.default.createDirectory(at: vanished, withIntermediateDirectories: true)
        try emit(model, gone, .promptStart(directory: vanished.path))
        try FileManager.default.removeItem(at: vanished)
        let customResult = await model.splitPane(gone, axis: .x, startSession: false)
        let custom = try XCTUnwrap(customResult)
        let fake = root.appendingPathComponent("bin/zsh").path
        _ = try await model.service.execute(.configureStoppedSession(paneID: custom, launch: .process(executable: fake, arguments: ["-i"], directory: "/tmp")))
        await model.refresh()
        await model.start(paneID: custom)
        _ = try await output(model, custom, containing: "ARGS=")
        try emit(model, custom, .promptStart(directory: project))
        let launches = model.snapshot.panes.mapValues { model.snapshot.sessions[$0.sessionID]?.launch }

        // Quit stops every session, which drops runtime shell state, before the final save.
        model.stopAll()
        let closed = await model.shutdown()
        XCTAssertTrue(closed)
        XCTAssertNil(model.shellStates[pane])
        let saved = await model.flushWorkspaceSave()
        XCTAssertTrue(saved)
        XCTAssertEqual(model.snapshot.sessions[model.snapshot.panes[pane]!.sessionID]?.launch, launches[pane], "the store keeps the original launch")

        let restored = try await makeModel(persistence: WorkspacePersistence(directory: state))
        defer { cleanUp(restored) }
        func launch(_ id: UUID) -> SessionLaunch? { restored.snapshot.panes[id].flatMap { restored.snapshot.sessions[$0.sessionID]?.launch } }
        XCTAssertEqual(launch(pane), .process(executable: fake, arguments: ["-l"], directory: project))
        XCTAssertEqual(launch(quiet), .process(executable: fake, arguments: ["-l"], directory: nil))
        XCTAssertEqual(launch(gone), launches[gone], "a started pane keeps the directory it was launched in")
        XCTAssertEqual(launch(custom), .process(executable: "", arguments: [], directory: "/tmp"))
        await restored.start(paneID: pane)
        let text = try await output(restored, pane, containing: "|")
        XCTAssertTrue(text.contains("PWD=project dir|"), text)
    }

    @MainActor
    func testARestartedPaneDoesNotResumeThePreviousShellsDirectory() async throws {
        let state = root.appendingPathComponent("state")
        let model = try await makeModel(persistence: WorkspacePersistence(directory: state))
        defer { cleanUp(model) }
        await model.createWindow(name: "Restart")
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        _ = try await output(model, pane, containing: "ARGS=")
        try emit(model, pane, .promptStart(directory: root.appendingPathComponent("project dir").path))
        let launch = model.snapshot.panes[pane].flatMap { model.snapshot.sessions[$0.sessionID]?.launch }
        model.terminals[pane]?.requestTermination(force: true)
        let deadline = Date().addingTimeInterval(5)
        while model.snapshot.panes[pane].flatMap({ model.snapshot.sessions[$0.sessionID] }).map({ [.exited, .failed].contains($0.state) }) != true, Date() < deadline {
            await model.waitForUpdates(); try await Task.sleep(for: .milliseconds(20))
        }
        await model.restartPane(pane, startSession: false)
        let saved = await model.flushWorkspaceSave()
        XCTAssertTrue(saved)

        let restored = try await makeModel(persistence: WorkspacePersistence(directory: state))
        defer { cleanUp(restored) }
        XCTAssertEqual(restored.snapshot.panes[pane].flatMap { restored.snapshot.sessions[$0.sessionID]?.launch }, launch)
    }
}
