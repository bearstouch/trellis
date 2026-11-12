import AppKit
import Foundation
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

@MainActor
private final class TypedAgentNotifications: DesktopNotifier {
    var posted: [DesktopNotification] = []
    func post(_ notification: DesktopNotification) { posted.append(notification) }
}

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
        await model.createSpace(name: "On")
        let first = try XCTUnwrap(model.presentation.activePane?.id)
        let injected = try await output(model, first, containing: "PWD=")
        XCTAssertTrue(injected.contains("NONCE=set"), injected)
        XCTAssertTrue(injected.contains("ShellIntegration/zsh"), injected)

        model.setShellIntegrationEnabled(false)
        await model.createSpace(name: "Off")
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
        await model.createSpace(name: "Custom", startSession: false)
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
        await model.createSpace(name: "Previous shell", startSession: false)
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
        await model.createSpace(name: "Work")
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
    func testFileLinkContextUsesReportedDirectoryAndExcludesHosts() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        await model.createSpace(name: "Links")
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        let terminal = try XCTUnwrap(model.terminals[pane])
        XCTAssertNotNil(terminal.fileLinkContext(), "Local shells resolve absolute and home paths")
        XCTAssertNil(terminal.fileLinkContext()?.currentDirectory, "Relative paths wait for a reported directory")
        let project = root.appendingPathComponent("project dir").path
        try emit(model, pane, .promptStart(directory: project))
        XCTAssertEqual(terminal.fileLinkContext()?.currentDirectory, project)
        XCTAssertEqual(terminal.fileLinkContext()?.homeDirectory, NSHomeDirectory())

        _ = try await model.service.execute(.splitPane(id: pane, axis: .x, availableSize: try TerminalSize(columns: 160, rows: 40)))
        await model.refresh()
        let second = try XCTUnwrap(model.snapshot.panes.keys.first { $0 != pane })
        _ = try await model.service.execute(.configureStoppedSession(paneID: second, launch: .host(UUID())))
        await model.refresh()
        XCTAssertNil(model.fileLinkContext(paneID: second), "A saved SSH host's paths name remote files")
        _ = try await model.service.execute(.configureStoppedSession(paneID: second, launch: .process(executable: "/usr/bin/ssh", arguments: ["box"], directory: nil)))
        await model.refresh()
        XCTAssertNil(model.fileLinkContext(paneID: second), "A pane started as ssh shows remote paths")
    }

    @MainActor
    func testClipboardWritesFollowTheSettingAndOnlyTrustedSSHPanes() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        let pane = try await makeShellPane(model)
        func allowed() -> Bool { model.terminals[pane]?.allowsClipboardWrite() ?? false }
        XCTAssertFalse(allowed(), "Off by default")
        var settings = model.appearance; settings.clipboardWriteAccess = .ssh
        XCTAssertTrue(model.applyAppearance(settings))
        XCTAssertFalse(allowed(), "A local shell isn't an SSH pane")
        try emit(model, pane, .commandStart(commandLine: "ssh -p 2222 me@box"))
        XCTAssertTrue(allowed(), "The authenticated shell is running ssh")
        try emit(model, pane, .commandFinished(exitCode: 0), .commandStart(commandLine: "vim ssh"))
        XCTAssertFalse(allowed(), "Only the program name counts, and only while it runs")
        for line in ["ssh -V; cat notes.txt", "ssh box && curl example.com", "ssh box | sh", "ssh box & cat log", "ssh $(cat host)", "ssh box\ncat log"] {
            try emit(model, pane, .commandFinished(exitCode: 0), .commandStart(commandLine: line))
            XCTAssertFalse(allowed(), "Local programs on the same line aren't trusted: \(line)")
        }
        try emit(model, pane, .commandFinished(exitCode: 0), .commandStart(commandLine: "env mosh box"))
        XCTAssertTrue(allowed())
        settings.clipboardWriteAccess = .off; XCTAssertTrue(model.applyAppearance(settings))
        XCTAssertFalse(allowed(), "Turning it off applies to running panes at once")
        try emit(model, pane, .commandFinished(exitCode: 0))
        settings.clipboardWriteAccess = .everywhere; XCTAssertTrue(model.applyAppearance(settings))
        XCTAssertTrue(allowed(), "Any pane when allowed everywhere")

        settings.clipboardWriteAccess = .ssh; XCTAssertTrue(model.applyAppearance(settings))
        for launch: SessionLaunch in [.host(UUID()), .process(executable: "/usr/bin/ssh", arguments: ["box"], directory: nil)] {
            _ = try await model.service.execute(.splitPane(id: pane, axis: .x, availableSize: try TerminalSize(columns: 160, rows: 40)))
            await model.refresh()
            let other = try XCTUnwrap(model.snapshot.panes.keys.first { $0 != pane && !model.isSSHPane(paneID: $0) })
            _ = try await model.service.execute(.configureStoppedSession(paneID: other, launch: launch))
            await model.refresh()
            XCTAssertTrue(model.clipboardWriteAllowed(paneID: other), "\(launch)")
        }
    }

    @MainActor
    func testAutomaticTitlesRespectRenamedTabs() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        await model.createSpace(name: "Titles")
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

    // MARK: FR-AG15

    /// Waits for the session to run: `tabAgent` only considers running panes.
    @MainActor
    private func makeShellPane(_ model: AppWorkspaceModel) async throws -> UUID {
        await model.createSpace(name: "Typed agent")
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        _ = try await output(model, pane, containing: "ARGS=")
        try emit(model, pane, .promptStart(directory: root.appendingPathComponent("project dir").path))
        return pane
    }

    @MainActor
    func testATypedAgentShowsItsIconAndTitleWithoutBecomingAnAgentPane() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        let pane = try await makeShellPane(model)
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        let launch = model.snapshot.panes[pane].flatMap { model.snapshot.sessions[$0.sessionID]?.launch }
        XCTAssertNil(model.tabAgent(tabID: tab.id))

        try emit(model, pane, .commandStart(commandLine: "claude --continue"))
        XCTAssertEqual(model.detectedAgent(paneID: pane)?.id, "trellis-claude-code")
        XCTAssertEqual(model.tabAgent(tabID: tab.id)?.id, "trellis-claude-code")
        XCTAssertEqual(model.tabPreviews(spaceID: tab.spaceID).first?.agent?.id, "trellis-claude-code", "the hover card shows it too")
        XCTAssertEqual(model.paneTitle(pane), "Claude Code · project dir")
        XCTAssertEqual(model.displayTitle(try XCTUnwrap(model.presentation.selectedTab)), "Claude Code · project dir")

        // A shell pane, still: nothing about its launch or its lifecycle changes, and no state is claimed.
        XCTAssertNil(model.agentLaunch(paneID: pane))
        XCTAssertNil(model.agentDefinition(paneID: pane))
        XCTAssertNil(model.agentBadge(tabID: tab.id))
        XCTAssertNil(model.agentStates[pane])
        XCTAssertEqual(model.snapshot.panes[pane].flatMap { model.snapshot.sessions[$0.sessionID]?.launch }, launch)
    }

    @MainActor
    func testATypedAgentIsMatchedByItsProgramNameOnly() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        let pane = try await makeShellPane(model)
        for line in ["env claude", "FOO=1 claude", "/Users/me/.local/bin/claude -p hi", "command claude"] {
            try emit(model, pane, .commandStart(commandLine: line))
            XCTAssertEqual(model.detectedAgent(paneID: pane)?.id, "trellis-claude-code", line)
            try emit(model, pane, .commandFinished(exitCode: 0))
        }
        for line in ["vim claude", "claude-foo", "cd api && claude", "ls"] {
            try emit(model, pane, .commandStart(commandLine: line))
            XCTAssertNil(model.detectedAgent(paneID: pane), line)
            try emit(model, pane, .commandFinished(exitCode: 0))
        }
    }

    @MainActor
    func testATypedAgentClearsWhenItsCommandEndsOrThePromptReturns() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        let pane = try await makeShellPane(model)
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        try emit(model, pane, .commandStart(commandLine: "codex"))
        XCTAssertEqual(model.tabAgent(tabID: tab.id)?.id, "trellis-codex")
        try emit(model, pane, .commandFinished(exitCode: 0))
        XCTAssertNil(model.tabAgent(tabID: tab.id))
        XCTAssertEqual(model.paneTitle(pane), "project dir")

        // A shell that lost its finish mark still reports the next prompt.
        try emit(model, pane, .commandStart(commandLine: "codex"))
        XCTAssertNotNil(model.tabAgent(tabID: tab.id))
        try emit(model, pane, .promptStart(directory: nil))
        XCTAssertNil(model.tabAgent(tabID: tab.id))
    }

    @MainActor
    func testTerminalSignalsGiveATypedAgentNoState() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        let pane = try await makeShellPane(model)
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        try emit(model, pane, .commandStart(commandLine: "claude"))
        for signal in [AgentSignal.inputSubmitted, .attention, .progress(active: true)] { model.applyAgentSignal(signal, paneID: pane) }
        XCTAssertNil(model.agentStates[pane], "without hooks nothing would ever end a Working")
        XCTAssertNil(model.agentBadge(tabID: tab.id))
    }

    // MARK: FR-AG18

    @MainActor
    func testATypedAgentsOwnHooksDriveItsStateAndItIsListedWhileItRuns() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        let pane = try await makeShellPane(model)
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        let session = try XCTUnwrap(model.terminals[pane]?.sessionID)
        XCTAssertTrue(model.agentSessionRows.isEmpty)

        model.receiveAgentEvent(sessionID: session, event: "working")
        XCTAssertNil(model.agentStates[pane], "an event while no typed agent runs changes nothing")

        try emit(model, pane, .commandStart(commandLine: "claude"))
        var row = try XCTUnwrap(model.agentSessionRows.first)
        XCTAssertEqual(model.agentSessionRows.count, 1)
        XCTAssertEqual(row.id, pane)
        XCTAssertEqual(row.agent.id, "trellis-claude-code")
        XCTAssertTrue(row.typed)
        XCTAssertNil(row.state)
        XCTAssertEqual(row.status, "Running", "without hooks it claims no state")
        model.applyAgentSignal(.attention, paneID: pane)
        XCTAssertNil(model.agentStates[pane], "a bell before any hook still sets nothing")

        model.receiveAgentEvent(sessionID: session, event: "working")
        XCTAssertEqual(model.agentBadge(tabID: tab.id)?.state, .working)
        row = try XCTUnwrap(model.agentSessionRows.first)
        XCTAssertEqual(row.state, .working)
        XCTAssertEqual(row.status, "Working")
        model.applyAgentSignal(.attention, paneID: pane)
        XCTAssertEqual(model.agentStates[pane]?.state, .needsInput, "once hooked, the terminal's signals apply as for a launched agent")
        XCTAssertEqual(model.agentsNeedingYouCount, 1)
        XCTAssertNil(model.agentDefinition(paneID: pane), "still a shell pane: no Start, Resume or installer")
        XCTAssertNil(model.agentLaunch(paneID: pane))

        try emit(model, pane, .commandFinished(exitCode: 0))
        XCTAssertNil(model.agentStates[pane], "the state ends with the command")
        XCTAssertNil(model.agentBadge(tabID: tab.id))
        XCTAssertTrue(model.agentSessionRows.isEmpty)
        model.receiveAgentEvent(sessionID: session, event: "done")
        XCTAssertNil(model.agentStates[pane], "a late hook after the command ended changes nothing")

        // A new command never inherits the last one's state, even when the finish mark was lost.
        try emit(model, pane, .commandStart(commandLine: "codex"))
        model.receiveAgentEvent(sessionID: session, event: "needs-input")
        XCTAssertEqual(model.agentBadge(tabID: tab.id)?.agent.id, "trellis-codex")
        try emit(model, pane, .commandStart(commandLine: "codex"))
        XCTAssertNil(model.agentStates[pane])
    }

    @MainActor
    func testATypedAgentNotifiesWhenItNeedsYouOutOfView() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        let notifier = TypedAgentNotifications()
        model.desktopNotifier = notifier
        model.workspaceIsFrontmost = { false }
        let pane = try await makeShellPane(model)
        let session = try XCTUnwrap(model.terminals[pane]?.sessionID)
        try emit(model, pane, .commandStart(commandLine: "claude"))
        model.receiveAgentEvent(sessionID: session, event: "needs-input")
        XCTAssertEqual(notifier.posted.map(\.title), ["Claude Code needs you"])
    }

    @MainActor
    func testALocalShellGetsTheTypedAgentChannelOnlyWhileTheSettingIsOn() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        let broker = FakeSessionBroker()
        broker.hookHelperPath = "/App/Helpers/trellis-broker"
        broker.agentSocketPath = "/tmp/broker/agent.sock"
        model.sessionBroker = broker
        XCTAssertTrue(model.typedAgentWiringEnabled, "on by default")

        func environment() async throws -> [String: String] {
            let session = try XCTUnwrap(model.presentation.activePane.flatMap { model.terminals[$0.id]?.sessionID })
            let deadline = Date().addingTimeInterval(5)
            while broker.transports[session]?.configuration == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            return try XCTUnwrap(broker.transports[session]?.configuration?.environment)
        }

        await model.createSpace(name: "Wired")
        let wired = try await environment()
        XCTAssertEqual(wired["TRELLIS_AGENT_SOCKET"], "/tmp/broker/agent.sock", "the broker holds the session, so it maps the nonce")
        XCTAssertEqual(wired["TRELLIS_AGENT_NONCE"]?.count, 32)
        XCTAssertTrue(model.agentHookNonces.isEmpty)
        let records = try XCTUnwrap(wired[ShellIntegrationInjection.agentWiringVariable]).split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
        let byName = Dictionary(uniqueKeysWithValues: records.map { ($0[0], Array($0.dropFirst())) })
        XCTAssertEqual(Set(byName.keys), ["claude", "codex", "pi"])
        XCTAssertEqual(byName["claude"]?.prefix(2), ["0", "--settings"])
        XCTAssertTrue(byName["claude"]?[2].contains("/App/Helpers/trellis-broker agent-hook working") == true)
        XCTAssertEqual(byName["pi"]?.prefix(3), ["1", "TRELLIS_AGENT_HOOK=/App/Helpers/trellis-broker", "-e"])
        XCTAssertEqual(byName["codex"]?.prefix(2), ["0", "-c"])

        model.typedAgentWiringEnabled = false
        await model.createSpace(name: "Plain")
        let plain = try await environment()
        XCTAssertNotNil(plain["TRELLIS_SHELL_INTEGRATION_NONCE"], "shell integration itself is unaffected")
        XCTAssertTrue(plain.keys.filter { $0.hasPrefix("TRELLIS_AGENT") }.isEmpty, "\(plain.keys.sorted())")
    }

    @MainActor
    func testAShellOutsideTheBrokerUsesTheAppsSocketAndDropsItsNonceWhenItEnds() async throws {
        let model = try await makeModel()
        defer { cleanUp(model); model.stopAgentHooks() }
        let broker = FakeSessionBroker()
        broker.ready = false
        broker.hookHelperPath = "/App/Helpers/trellis-broker"
        model.sessionBroker = broker
        model.typedAgentWiringEnabled = true
        await model.createSpace(name: "Local")
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        _ = try await output(model, pane, containing: "ARGS=")
        let session = try XCTUnwrap(model.terminals[pane]?.sessionID)
        XCTAssertEqual(Array(model.agentHookNonces.values), [session])

        model.terminals[pane]?.requestTermination(force: true)
        let deadline = Date().addingTimeInterval(5)
        while ![.exited, .failed].contains(model.terminals[pane]?.sessionState), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.agentHookNonces.isEmpty)
    }

    @MainActor
    func testATypedAgentInTheHomeFolderIsTitledWithATilde() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        let pane = try await makeShellPane(model)
        try emit(model, pane, .promptStart(directory: FileManager.default.homeDirectoryForCurrentUser.path), .commandStart(commandLine: "claude"))
        XCTAssertEqual(model.paneTitle(pane), "Claude Code · ~")
    }

    @MainActor
    func testARenamedTabKeepsItsNameWhileATypedAgentRuns() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        let pane = try await makeShellPane(model)
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        await model.renameTab(tab.id, title: "Server")
        try emit(model, pane, .commandStart(commandLine: "claude"))
        XCTAssertEqual(model.displayTitle(try XCTUnwrap(model.presentation.selectedTab)), "Server")
        XCTAssertEqual(model.tabAgent(tabID: tab.id)?.id, "trellis-claude-code", "the icon still shows")
    }

    @MainActor
    func testFailedCommandIsAnnouncedAndClearsOnTheNextCommand() async throws {
        let model = try await makeModel()
        defer { cleanUp(model) }
        await model.createSpace(name: "Status")
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
        await model.createSpace(name: "Lifecycle")
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
        await model.createSpace(name: "Resume")
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
        await model.createSpace(name: "Restart")
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
