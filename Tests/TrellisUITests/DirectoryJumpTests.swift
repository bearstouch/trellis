import AppKit
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// Directory jump end to end (FR-DJ01, FR-DJ05–FR-DJ08). As in `TaskRunnerTests`, the fake `zsh` gets shell integration
/// injected but echoes every typed byte visibly, and each test sends the marks itself.
final class DirectoryJumpTests: XCTestCase {
    private var scratch: URL!
    private var project: String!
    private var other: String!
    private var shell: String!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-dj-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let manager = FileManager.default
        for folder in ["bin", "state", "history", "project", "other folder"] { try manager.createDirectory(at: scratch.appendingPathComponent(folder), withIntermediateDirectories: true) }
        project = scratch.appendingPathComponent("project").path
        other = scratch.appendingPathComponent("other folder").path
        shell = scratch.appendingPathComponent("bin/zsh").path
        try "#!/bin/sh\n/bin/stty raw -echo\nprintf 'SHELL-UP\\n'\nexec /bin/cat -uv\n".write(toFile: shell, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private final class HangingFiles: LaunchFileAccess, @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)
        func isExecutableFile(_ path: String) -> Bool { true }
        func isAccessibleDirectory(_ path: String) -> Bool {
            release.wait()
            return true
        }
    }

    /// Rows and visits use paths under the temporary folder, which the skip rules refuse, so tests that jump put their
    /// rows straight into the model.
    @MainActor
    private func makeModel(started: Bool = true) async throws -> (AppWorkspaceModel, UUID) {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-dj-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        _ = await model.loadWorkspace()
        model.confirmCloseSessions = { _ in true }
        model.directoryHistory = DirectoryHistory(stateDirectory: scratch.appendingPathComponent("history"), sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }, mounts: { [] })
        let saved = await model.saveLaunchSettings(shell: shell, directory: project)
        XCTAssertTrue(saved)
        _ = await model.createSpace(name: "W", startSession: started)
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        if started {
            try await waitFor { self.text(model, pane).contains("SHELL-UP") }
            XCTAssertEqual(model.terminals[pane]?.sessionState, .running)
        }
        return (model, pane)
    }

    @MainActor
    private func cleanUp(_ model: AppWorkspaceModel) {
        model.terminals.values.forEach {
            $0.requestTermination(force: true); $0.adapter.detach()
        }
    }

    @MainActor
    private func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    @MainActor
    private func text(_ model: AppWorkspaceModel, _ pane: UUID) -> String { (try? model.terminals[pane]?.adapter.read(.retainedText)) ?? "" }

    @MainActor
    private func mark(_ model: AppWorkspaceModel, _ pane: UUID, _ event: ShellIntegrationEvent) throws {
        try XCTUnwrap(model.terminals[pane]).onShellIntegrationEvent?(event)
    }

    /// Records through the store's real path and waits until the model has the result.
    @MainActor
    private func visit(_ model: AppWorkspaceModel, _ pane: UUID, _ path: String, expecting count: Int) async throws {
        try mark(model, pane, .promptStart(directory: path))
        try await waitFor { model.directoryEntries.reduce(0) { $0 + $1.visits } == count }
        XCTAssertEqual(model.directoryEntries.reduce(0) { $0 + $1.visits }, count, path)
    }

    @MainActor
    private func row(_ path: String, machine: String = "local", visits: Int = 1) -> DirectoryHistoryEntry {
        DirectoryHistoryEntry(path: path, machine: machine, visits: visits, lastVisit: Date())
    }

    @MainActor
    private func startDirectory(_ model: AppWorkspaceModel, _ paneID: UUID) throws -> String? {
        let pane = try XCTUnwrap(model.snapshot.panes[paneID])
        switch try XCTUnwrap(model.snapshot.sessions[pane.sessionID]).launch {
        case .shell(let directory), .process(_, _, let directory), .remoteShell(_, let directory): return directory
        default: return nil
        }
    }

    // MARK: Recording (FR-DJ01)

    @MainActor
    func testVisitsCountEachMoveNotEachPrompt() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        try await visit(model, pane, "/code/a", expecting: 1)
        try await visit(model, pane, "/code/b", expecting: 2)
        try await visit(model, pane, "/code/a", expecting: 3)
        // Prompts in the same directory, with a command between them.
        try mark(model, pane, .commandStart(commandLine: "ls"))
        try mark(model, pane, .commandFinished(exitCode: 0))
        try mark(model, pane, .promptStart(directory: "/code/a"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.directoryEntries.first { $0.path == "/code/a" }?.visits, 2)
        XCTAssertEqual(model.directoryEntries.first { $0.path == "/code/b" }?.visits, 1)
        XCTAssertEqual(model.directoryEntries.first?.machine, "local")
    }

    @MainActor
    func testSkippedDirectoriesAreNeverRemembered() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        for path in ["/tmp/x", "/Users/me/.ssh", "/net/share", "/proc/1"] { try mark(model, pane, .promptStart(directory: path)) }
        try await visit(model, pane, "/code/a", expecting: 1)
        XCTAssertEqual(model.directoryEntries.map(\.path), ["/code/a"])
    }

    @MainActor
    func testTurnedOffRecordsNothingKeepsRowsAndStaysOffAfterRelaunch() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        try await visit(model, pane, "/code/a", expecting: 1)
        XCTAssertTrue(model.directoryHistoryEnabled)
        model.setDirectoryHistoryEnabled(false)
        try mark(model, pane, .promptStart(directory: "/code/b"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.directoryEntries.map(\.path), ["/code/a"], "Rows stay; nothing new")
        XCTAssertFalse(AppWorkspaceModel(store: try WorkspaceStore(), preferences: model.preferences).directoryHistoryEnabled)
    }

    @MainActor
    func testUnverifiedMarksOfAnSSHPaneAreNeverRemembered() async throws {
        let (model, pane) = try await makeModel(started: false)
        defer { cleanUp(model) }
        let host = UUID()
        _ = try await model.service.execute(.configureStoppedSession(paneID: pane, launch: .host(host)))
        await model.refresh()
        XCTAssertNil(model.directoryMachine(paneID: pane))
        try XCTUnwrap(model.terminals[pane]).observeRemoteShellMarks()
        try mark(model, pane, .promptStart(directory: "/code/remote"))
        XCTAssertEqual(model.remoteDirectory(paneID: pane), "/code/remote", "The mark did arrive, and is shown")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.directoryEntries.isEmpty)
    }

    // MARK: Palette (FR-DJ05)

    @MainActor
    func testCommandJOpensTheScopeWithTheRankedRowsAndTheScopeRowNeedsAHistory() async throws {
        let (model, _) = try await makeModel(started: false)
        defer { cleanUp(model) }
        XCTAssertFalse(model.commandPaletteItems.contains { $0.target == .scope(.directories) }, "No row while there's nothing to list")
        model.openDirectoryJump()
        XCTAssertEqual(model.commandPaletteScope, .directories)
        XCTAssertTrue(model.commandPaletteSections.isEmpty, "⌘J still opens it, and the view explains the empty list")
        model.closeCommandPalette()

        let home = NSHomeDirectory()
        model.directoryEntries = [row(home + "/code/a", visits: 3), row("/srv/b")]
        model.canPerformShortcutAction = { _ in true }
        model.openDirectoryJump()
        let rows = model.commandPaletteSections.flatMap(\.matches).map(\.item)
        XCTAssertEqual(rows.map(\.title), ["~/code/a", "/srv/b"])
        XCTAssertEqual(rows[0].subtitle, "Local · 3 visits · just now")
        XCTAssertEqual(rows[1].subtitle, "Local · 1 visit · just now")
        XCTAssertEqual(model.commandPaletteSelection, rows[0].id)
        model.closeCommandPalette()

        model.openCommandPalette()
        XCTAssertTrue(model.commandPaletteItems.contains { $0.target == .scope(.directories) && $0.shortcut == KeyChord("j") })
        XCTAssertFalse(model.commandPaletteItems.contains { $0.target == .action(.jumpToDirectory) }, "Its scope row stands for it")
        model.setCommandPaletteQuery("code/a")
        XCTAssertEqual(model.commandPaletteSections.first?.matches.first?.item.title, "~/code/a", "General search finds rows too")
        model.closeCommandPalette()
    }

    @MainActor
    func testRowsAreRankedAgainWhenThePaletteOpensBecauseScoresFallWithTime() async throws {
        let (model, _) = try await makeModel(started: false)
        defer { cleanUp(model) }
        // Listed best-first as they were when last ranked; three days on, the recent visit wins.
        let old = DirectoryHistoryEntry(path: "/code/old", machine: "local", visits: 10, lastVisit: Date().addingTimeInterval(-3 * 86_400))
        let recent = DirectoryHistoryEntry(path: "/code/recent", machine: "local", visits: 3, lastVisit: Date().addingTimeInterval(-60))
        model.directoryEntries = [old, recent]
        model.openDirectoryJump()
        XCTAssertEqual(model.commandPaletteSections.flatMap { $0.matches.map(\.item.title) }, ["/code/recent", "/code/old"])
        model.closeCommandPalette()
    }

    @MainActor
    func testRowsOfTheFocusedMachineComeFirstAndADeletedHostsAreHidden() async throws {
        let (model, _) = try await makeModel(started: false)
        defer { cleanUp(model) }
        let draft = try HostDraft(name: "build-box", destination: "build-box").validated { _ in false }
        let host = SavedHost(id: UUID(), draft: draft, revision: 1)
        model.commandPaletteHosts = { [host] }
        model.remoteHosts = RemoteHostsModel(
            settings: RemoteHostSettings(stateDirectory: nil), catalog: RemoteArtifactCatalog.load(remoteDirectory: nil, macHelper: nil), clientID: RemoteClientIdentity.randomHex())
        model.directoryEntries = [row("/host/top", machine: host.id.uuidString, visits: 9), row("/local/next"), row("/gone/x", machine: UUID().uuidString)]
        model.openDirectoryJump()
        let sections = model.commandPaletteSections
        XCTAssertEqual(sections.map(\.title), ["Local", "build-box"])
        XCTAssertEqual(sections.flatMap { $0.matches.map(\.item.title) }, ["/local/next", "/host/top"])
        model.closeCommandPalette()
    }

    // MARK: Jumping (FR-DJ06)

    @MainActor
    func testReturnAtAnIdlePromptTypesCdInTheFocusedPaneWithoutFollowingItAsATask() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        try mark(model, pane, .promptStart(directory: project))
        model.directoryEntries = [row(other)]
        let tabs = model.snapshot.tabs.count
        model.openDirectoryJump()
        model.runCommandPaletteItem()
        try await waitFor { self.text(model, pane).contains("cd '") }
        XCTAssertTrue(text(model, pane).contains("^E^Ucd '\(other!)'^M"), text(model, pane))
        XCTAssertEqual(model.snapshot.tabs.count, tabs)
        XCTAssertTrue(model.taskRuns.isEmpty)
        XCTAssertFalse(model.commandPaletteVisible)
    }

    @MainActor
    func testReturnInTheDirectoryAlreadyThereLeavesHalfTypedInputAlone() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        try mark(model, pane, .promptStart(directory: project))
        let tabs = model.snapshot.tabs.count
        await model.jumpToDirectory(path: project, machine: "local", modifier: .none)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(text(model, pane).contains("^U"), text(model, pane))
        XCTAssertEqual(model.snapshot.tabs.count, tabs)
    }

    @MainActor
    func testReturnWithAProgramRunningOpensATabThereAndSendsItNothing() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        try mark(model, pane, .promptStart(directory: project))
        try mark(model, pane, .commandStart(commandLine: "vim"))
        let before = text(model, pane)
        let tabs = model.snapshot.tabs.count
        await model.jumpToDirectory(path: other, machine: "local", modifier: .none)
        XCTAssertEqual(model.snapshot.tabs.count, tabs + 1)
        let created = try XCTUnwrap(model.presentation.activePane?.id)
        XCTAssertNotEqual(created, pane)
        XCTAssertEqual(try startDirectory(model, created), other)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(text(model, pane), before, "Never typed into a running program")
    }

    @MainActor
    func testReturnWithoutShellIntegrationOpensATab() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        XCTAssertEqual(model.taskAvailability(paneID: pane), .noIntegration)
        let tabs = model.snapshot.tabs.count
        await model.jumpToDirectory(path: other, machine: "local", modifier: .none)
        XCTAssertEqual(model.snapshot.tabs.count, tabs + 1)
        XCTAssertFalse(text(model, pane).contains("cd '"))
    }

    @MainActor
    func testCommandReturnAlwaysOpensATabEvenAtAnIdlePrompt() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        try mark(model, pane, .promptStart(directory: project))
        let tabs = model.snapshot.tabs.count
        await model.jumpToDirectory(path: other, machine: "local", modifier: .command)
        XCTAssertEqual(model.snapshot.tabs.count, tabs + 1)
        XCTAssertEqual(try startDirectory(model, try XCTUnwrap(model.presentation.activePane?.id)), other)
        XCTAssertFalse(text(model, pane).contains("cd '"))
    }

    @MainActor
    func testOptionReturnSplitsBesideTheFocusedPaneAndIsRefusedWhileMaximized() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        let tabs = model.snapshot.tabs.count, panes = model.snapshot.panes.count
        await model.jumpToDirectory(path: other, machine: "local", modifier: .option)
        XCTAssertEqual(model.snapshot.tabs.count, tabs)
        XCTAssertEqual(model.snapshot.panes.count, panes + 1)
        let created = try XCTUnwrap(model.presentation.activePane?.id)
        XCTAssertEqual(try startDirectory(model, created), other)

        await model.selectPane(pane)
        await model.toggleMaximize(pane)
        await model.jumpToDirectory(path: project, machine: "local", modifier: .option)
        XCTAssertEqual(model.snapshot.panes.count, panes + 1, "A hidden split would hide the shell")
        XCTAssertEqual(model.errorMessage, "Restore panes before opening a directory in a split.")
    }

    @MainActor
    func testAMissingDirectoryIsReportedDroppedAndNothingIsTypedOrOpened() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        try await visit(model, pane, "/code/gone-for-good", expecting: 1)
        try mark(model, pane, .promptStart(directory: project))
        let tabs = model.snapshot.tabs.count
        await model.jumpToDirectory(path: "/code/gone-for-good", machine: "local", modifier: .none)
        XCTAssertTrue(try XCTUnwrap(model.errorMessage).contains("no longer available"))
        XCTAssertTrue(model.directoryEntries.isEmpty)
        XCTAssertEqual(model.snapshot.tabs.count, tabs)
        XCTAssertFalse(text(model, pane).contains("cd '"))
    }

    /// A row can lead to a dead share through a symbolic link: the look at it never answers, and the app carries on.
    @MainActor
    func testADirectoryThatNeverAnswersBlocksNothingOpensNothingAndKeepsItsRow() async throws {
        let (model, pane) = try await makeModel()
        let hung = HangingFiles()
        defer {
            hung.release.signal()
            cleanUp(model)
        }
        try mark(model, pane, .promptStart(directory: project))
        try await visit(model, pane, "/code/share", expecting: 1)
        try mark(model, pane, .promptStart(directory: project))
        model.directoryJumpFiles = hung
        model.directoryJumpTimeout = 0.05
        let tabs = model.snapshot.tabs.count
        await model.jumpToDirectory(path: "/code/share", machine: "local", modifier: .none)
        XCTAssertTrue(try XCTUnwrap(model.errorMessage).contains("isn't responding"))
        XCTAssertEqual(model.directoryEntries.map(\.path), ["/code/share"])
        XCTAssertEqual(model.snapshot.tabs.count, tabs)
        XCTAssertFalse(text(model, pane).contains("cd '"))
    }

    @MainActor
    func testAPlainSSHPaneAlwaysGetsANewTabForALocalRow() async throws {
        let (model, pane) = try await makeModel(started: false)
        defer { cleanUp(model) }
        _ = try await model.service.execute(.configureStoppedSession(paneID: pane, launch: .host(UUID())))
        await model.refresh()
        let tabs = model.snapshot.tabs.count
        await model.jumpToDirectory(path: other, machine: "local", modifier: .option)
        XCTAssertEqual(model.snapshot.tabs.count, tabs + 1, "Even ⌥Return: a split there would mix machines")
        XCTAssertEqual(try startDirectory(model, try XCTUnwrap(model.presentation.activePane?.id)), other)
    }

    @MainActor
    func testWithNoSpaceALocalRowOpensOne() async throws {
        let (model, _) = try await makeModel(started: false)
        defer { cleanUp(model) }
        await model.closeAllWorkspaces()
        XCTAssertTrue(model.snapshot.spaces.isEmpty)
        await model.jumpToDirectory(path: other, machine: "local", modifier: .none)
        XCTAssertEqual(model.snapshot.spaces.count, 1)
        XCTAssertEqual(try startDirectory(model, try XCTUnwrap(model.presentation.activePane?.id)), other)
    }

    @MainActor
    func testARowOfAHostThatIsNoLongerSavedOpensNothing() async throws {
        let (model, _) = try await makeModel(started: false)
        defer { cleanUp(model) }
        let tabs = model.snapshot.tabs.count
        await model.jumpToDirectory(path: "/srv/app", machine: UUID().uuidString, modifier: .none)
        XCTAssertEqual(model.snapshot.tabs.count, tabs)
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: A real shell

    /// The whole loop with `/bin/zsh` and the bundled integration: `cd` is remembered, Return moves the shell, and a running
    /// program gets a tab instead. /usr passes the skip rules, where the test's temporary folders don't.
    @MainActor
    func testARealZshIsRememberedMovedAndNeverTypedIntoWhileBusy() async throws {
        let (model, pane) = try await makeModel(started: false)
        defer { cleanUp(model) }
        let saved = await model.saveLaunchSettings(shell: "/bin/zsh", directory: project)
        XCTAssertTrue(saved)
        let space = await model.createSpace(name: "zsh")
        XCTAssertNotNil(space)
        let shellPane = try XCTUnwrap(model.presentation.activePane?.id)
        XCTAssertNotEqual(shellPane, pane)
        let terminal = try XCTUnwrap(model.terminals[shellPane])
        try await waitFor(15) { model.taskAvailability(paneID: shellPane) == .ready }
        XCTAssertEqual(model.taskAvailability(paneID: shellPane), .ready, "Needs the bundled integration:\n\(terminal.screenText)")

        try terminal.adapter.send(Data("cd /usr\r".utf8))
        try await waitFor { model.directoryEntries.contains { $0.path == "/usr" } }
        XCTAssertEqual(model.directoryEntries.first { $0.path == "/usr" }?.visits, 1)
        XCTAssertEqual(model.directoryEntries.first { $0.path == "/usr" }?.machine, "local")

        // Through the palette, as ⌘J then Return would.
        model.directoryEntries.append(row("/usr/bin"))
        model.openDirectoryJump()
        model.selectCommandPaletteItem("directory:local:/usr/bin")
        model.runCommandPaletteItem()
        try await waitFor { model.currentDirectory(paneID: shellPane) == "/usr/bin" }
        XCTAssertEqual(model.currentDirectory(paneID: shellPane), "/usr/bin", terminal.screenText)

        try terminal.adapter.send(Data("sleep 30\r".utf8))
        try await waitFor { model.taskAvailability(paneID: shellPane) == .busy }
        XCTAssertEqual(model.taskAvailability(paneID: shellPane), .busy)
        let tabs = model.snapshot.tabs.count
        await model.jumpToDirectory(path: "/usr", machine: "local", modifier: .none)
        XCTAssertEqual(model.snapshot.tabs.count, tabs + 1)
        let created = try XCTUnwrap(model.presentation.activePane?.id)
        XCTAssertNotEqual(created, shellPane)
        try await waitFor(15) { model.currentDirectory(paneID: created) == "/usr" }
        XCTAssertEqual(model.currentDirectory(paneID: created), "/usr", "The tab's own shell starts there")
        XCTAssertEqual(model.currentDirectory(paneID: shellPane), "/usr/bin", "The busy shell didn't move")
    }

    // MARK: Clearing and startup (FR-DJ08)

    @MainActor
    func testClearAsksFirstDeletesTheFileAndTheCurrentFolderDoesNotComeStraightBack() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        try await visit(model, pane, "/code/a", expecting: 1)
        await model.directoryHistory?.flush()
        let file = scratch.appendingPathComponent("history").appendingPathComponent(DirectoryHistory.fileName).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: file))

        model.confirmClearDirectoryHistory = { false }
        await model.clearDirectoryHistory()
        XCTAssertEqual(model.directoryEntries.count, 1, "Cancel keeps everything")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file))

        model.confirmClearDirectoryHistory = { true }
        await model.clearDirectoryHistory()
        XCTAssertTrue(model.directoryEntries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))

        try mark(model, pane, .commandStart(commandLine: "ls"))
        try mark(model, pane, .commandFinished(exitCode: 0))
        try mark(model, pane, .promptStart(directory: "/code/a"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.directoryEntries.isEmpty)
    }

    @MainActor
    func testClearReportsAFileThatStays() async throws {
        let (model, _) = try await makeModel(started: false)
        defer { cleanUp(model) }
        let file = scratch.appendingPathComponent("history").appendingPathComponent(DirectoryHistory.fileName)
        try Data("{\"version\":2,\"entries\":[]}".utf8).write(to: file)
        model.confirmClearDirectoryHistory = { true }
        await model.clearDirectoryHistory()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor
    func testLoadingDropsDeletedHostsOnlyWhenTheHostLibraryCouldBeRead() async throws {
        let (model, _) = try await makeModel(started: false)
        defer { cleanUp(model) }
        let history = try XCTUnwrap(model.directoryHistory)
        await history.record(path: "/code/a", on: .local)
        await history.record(path: "/srv/b", on: .host(UUID()))
        await model.loadDirectoryHistory(hosts: nil)
        XCTAssertEqual(model.directoryEntries.count, 2, "An unreadable host library says nothing about which hosts exist")
        await model.loadDirectoryHistory(hosts: [])
        XCTAssertEqual(model.directoryEntries.map(\.path), ["/code/a"])
    }

    @MainActor
    func testQuittingWritesABatchedVisit() async throws {
        let (model, pane) = try await makeModel()
        try await visit(model, pane, "/code/a", expecting: 1)
        let file = scratch.appendingPathComponent("history").appendingPathComponent(DirectoryHistory.fileName).path
        XCTAssertFalse(FileManager.default.fileExists(atPath: file), "Still batched")
        _ = await model.shutdown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file))
    }

    @MainActor
    func testQuittingWithKeepRunningWritesABatchedVisit() async throws {
        let (model, pane) = try await makeModel()
        try await visit(model, pane, "/code/a", expecting: 1)
        let file = scratch.appendingPathComponent("history").appendingPathComponent(DirectoryHistory.fileName).path
        XCTAssertFalse(FileManager.default.fileExists(atPath: file), "Still batched")
        let detached = await model.detachForQuit()
        XCTAssertTrue(detached)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file))
    }
}
