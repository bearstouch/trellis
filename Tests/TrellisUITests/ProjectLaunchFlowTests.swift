import AppKit
import TrellisCore
import TrellisTerminal
import XCTest

@testable import TrellisUI

/// Launching a library project on this Mac end to end (FR-PL06–FR-PL08). A fake login shell runs the setup command with
/// a fake `git` first on its PATH, and otherwise echoes typed input (`cat -v`), so the typed commands show on screen.
@MainActor
final class ProjectLaunchFlowTests: XCTestCase {
    private var scratch: URL!
    private weak var model: AppWorkspaceModel?

    override func setUp() async throws {
        _ = NSApplication.shared
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-pl-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("state"), withIntermediateDirectories: true)
        let bin = scratch.appendingPathComponent("bin").path
        try """
        #!/bin/sh
        if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then PATH="\(bin):$PATH" exec /bin/sh -c "$3"; fi
        /bin/stty raw -echo
        printf 'SHELL-UP\\n'
        exec /bin/cat -uv
        """.write(toFile: bin + "/fakesh", atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho \"git $*\" >> \"\(scratch.path)/git.log\"\n[ -n \"$FAKE_GIT_HANG\" ] && exec sleep 30\n[ \"$1\" = clone ] && for last; do :; done && mkdir -p \"$last/.git\"\nexit ${FAKE_GIT_STATUS:-0}\n"
            .write(toFile: bin + "/git", atomically: true, encoding: .utf8)
        for tool in ["fakesh", "git"] { chmod(bin + "/" + tool, 0o755) }
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    private func makeModel() async throws -> AppWorkspaceModel {
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-pl-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        _ = await model.loadWorkspace()
        model.confirmCloseSessions = { _ in true }
        let saved = await model.saveLaunchSettings(shell: scratch.appendingPathComponent("bin/fakesh").path, directory: scratch.path)
        XCTAssertTrue(saved)
        self.model = model
        addTeardownBlock { @MainActor in
            model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        return model
    }

    private func until(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out: \(what) \(model?.projectLaunch.map { "\($0.stage) \($0.terminal?.sessionState as Any) \($0.terminal?.screenText ?? "")" } ?? "")")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The sheet checks on its own when it opens; waits until the latest check settled.
    private func ready(_ session: ProjectLaunchSession, _ model: AppWorkspaceModel) async throws -> ProjectLaunch {
        await model.checkProjectLaunch(session)
        var launch: ProjectLaunch?
        try await until("the target was checked") {
            if case .ready(let ready) = session.stage { launch = ready; return true }
            return false
        }
        return try XCTUnwrap(launch)
    }

    func testSetUpAndOpenClonesThenOpensTheWindowAndRelaunchingReconcilesIt() async throws {
        let model = try await makeModel()
        var launched: [(UUID, ProjectTarget, String)] = []
        model.onProjectLaunched = { launched.append(($0, $1, $2)) }
        let project = ProjectDefinition(
            name: "Shop",
            tabs: [
                ProjectTab(
                    title: "API", directory: "api", repository: ProjectRepository(url: "https://github.com/acme/api.git"),
                    root: .split(axis: .x, ratio: 0.5, first: .pane(ProjectPane(command: "make dev")), second: .pane(ProjectPane(title: "Shell"))))
            ])
        model.beginProjectLaunch(project)
        let session = try XCTUnwrap(model.projectLaunch)
        session.folder = scratch.appendingPathComponent("work/shop").path
        let launch = try await ready(session, model)
        XCTAssertTrue(launch.needsSetup)
        XCTAssertFalse(launch.rootExists)
        XCTAssertEqual(launch.checkouts.map(\.state), [.clone])

        await model.runProjectSetup(session)
        try await until("the window opened") { model.projectLaunch == nil && model.snapshot.windows.contains { $0.name == "Shop" } }
        XCTAssertEqual(try String(contentsOf: scratch.appendingPathComponent("git.log"), encoding: .utf8), "git clone -- https://github.com/acme/api.git ./api\n")
        let window = try XCTUnwrap(model.snapshot.windows.first { $0.name == "Shop" })
        let tab = try XCTUnwrap(model.snapshot.tabs[window.activeTabID])
        XCTAssertEqual(tab.root.paneIDs.count, 2)
        let first = try XCTUnwrap(model.terminals[tab.root.paneIDs[0]])
        // Without integration the command is written as soon as the shell starts; the terminal echoes it.
        try await until("the command was typed") { first.screenText.contains("make dev") }
        // A started shell is frozen to the login shell it ran.
        guard case .process(_, ["-l"], let directory?)? = model.snapshot.sessions[model.snapshot.panes[tab.root.paneIDs[0]]!.sessionID]?.launch else {
            return XCTFail("Not a login shell")
        }
        XCTAssertEqual(directory, scratch.appendingPathComponent("work/shop/api").path)
        // Recorded once every pane was started, which can be after the first command was typed.
        try await until("the launch was recorded") { !launched.isEmpty }
        XCTAssertEqual(launched.map(\.2), [scratch.appendingPathComponent("work/shop").path])

        // Launching again finds everything in place, selects the same window and starts nothing new.
        model.beginProjectLaunch(project)
        let again = try XCTUnwrap(model.projectLaunch)
        again.folder = scratch.appendingPathComponent("work/shop").path
        let ready = try await ready(again, model)
        XCTAssertFalse(ready.needsSetup)
        try await Task.sleep(for: .milliseconds(300))
        let screen = first.screenText
        let windows = model.snapshot.windows.count, sessions = model.snapshot.sessions.count
        await model.openProjectLaunch(again, ready)
        XCTAssertEqual(model.snapshot.windows.count, windows)
        XCTAssertEqual(model.snapshot.sessions.count, sessions)
        XCTAssertEqual(model.snapshot.activeWindowID, window.id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(first.screenText, screen, "No command is typed again")
        XCTAssertTrue(model.pendingProjectCommands.isEmpty)
    }

    /// FR-PL10: a project pane that names an agent opens as that agent's pane, in its folder; the shell beside it stays a shell.
    func testAnAgentPaneOpensAsTheAgentInItsFolder() async throws {
        let model = try await makeModel()
        let agent = scratch.appendingPathComponent("bin/fake-agent").path
        try "#!/bin/sh\nprintf 'AGENT-UP %s\\n' \"$PWD\"\nexec /bin/sleep 30\n".write(toFile: agent, atomically: true, encoding: .utf8)
        chmod(agent, 0o755)
        model.agentCatalog = AgentCatalogSnapshot(definitions: [AgentDefinition(id: "fake", name: "Fake", executable: agent)])
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("work/shop/api"), withIntermediateDirectories: true)
        let project = ProjectDefinition(
            name: "Shop",
            tabs: [
                ProjectTab(
                    title: "API", directory: "api",
                    root: .split(axis: .x, ratio: 0.5, first: .pane(ProjectPane(agent: "fake")), second: .pane(ProjectPane(title: "Shell"))))
            ])
        model.beginProjectLaunch(project)
        let session = try XCTUnwrap(model.projectLaunch)
        session.folder = scratch.appendingPathComponent("work/shop").path
        let launch = try await ready(session, model)
        XCTAssertFalse(launch.needsSetup)
        XCTAssertEqual(launch.agents, ["t1-1": "fake"])
        await model.openProjectLaunch(session, launch)
        try await until("the window opened") { model.snapshot.windows.contains { $0.name == "Shop" } }
        let window = try XCTUnwrap(model.snapshot.windows.first { $0.name == "Shop" })
        let tab = try XCTUnwrap(model.snapshot.tabs[window.activeTabID])
        let agentPane = tab.root.paneIDs[0], shellPane = tab.root.paneIDs[1]
        XCTAssertEqual(model.agentLaunch(paneID: agentPane), AgentLaunch(agentID: "fake", directory: scratch.appendingPathComponent("work/shop/api").path))
        XCTAssertNil(model.agentLaunch(paneID: shellPane))
        let terminal = try XCTUnwrap(model.terminals[agentPane])
        try await until("the agent started") { terminal.screenText.contains("AGENT-UP") }
        XCTAssertTrue(terminal.screenText.contains("/work/shop/api"))
        XCTAssertEqual(model.tabAgent(tabID: tab.id)?.id, "fake")
    }

    func testAFailedSetupKeepsTheSheetAndCancelLeavesNoWindow() async throws {
        let model = try await makeModel()
        setenv("FAKE_GIT_STATUS", "128", 1)
        addTeardownBlock { unsetenv("FAKE_GIT_STATUS") }
        let project = ProjectDefinition(name: "Broken", tabs: [ProjectTab(title: "T", directory: "repo", repository: ProjectRepository(url: "git@github.com:a/b.git"))])
        model.beginProjectLaunch(project)
        let session = try XCTUnwrap(model.projectLaunch)
        session.folder = scratch.appendingPathComponent("broken").path
        _ = try await ready(session, model)
        await model.runProjectSetup(session)
        try await until("setup failed") {
            if case .failed = session.stage { return true }
            return false
        }
        XCTAssertNotNil(session.terminal, "The output stays visible")
        model.cancelProjectLaunch(session)
        XCTAssertNil(model.projectLaunch)
        XCTAssertFalse(model.snapshot.windows.contains { $0.name == "Broken" })
    }

    /// Cancel while setup runs stops it (a hangup, so git can clean up) and keeps the terminal until it has ended.
    func testCancelDuringSetupStopsItAndOpensNothing() async throws {
        let model = try await makeModel()
        setenv("FAKE_GIT_HANG", "1", 1)
        addTeardownBlock { unsetenv("FAKE_GIT_HANG") }
        let project = ProjectDefinition(name: "Slow", tabs: [ProjectTab(title: "T", directory: "repo", repository: ProjectRepository(url: "git@github.com:a/b.git"))])
        model.beginProjectLaunch(project)
        let session = try XCTUnwrap(model.projectLaunch)
        session.folder = scratch.appendingPathComponent("slow").path
        _ = try await ready(session, model)
        await model.runProjectSetup(session)
        weak var terminal = session.terminal
        let log = scratch.appendingPathComponent("git.log").path
        try await until("git is running") { FileManager.default.fileExists(atPath: log) }
        model.cancelProjectLaunch(session)
        XCTAssertNil(model.projectLaunch)
        XCTAssertNotNil(terminal, "Kept until it ends")
        try await until("setup ended and was let go") { terminal == nil }
        XCTAssertFalse(model.snapshot.windows.contains { $0.name == "Slow" })
    }
}
