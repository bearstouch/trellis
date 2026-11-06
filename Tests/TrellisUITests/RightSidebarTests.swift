import AppKit
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// The right sidebar and its dock (FR-SB02–FR-SB05) and the Agents view's list (FR-AG07, FR-AG16), at the model level. As in
/// `AgentLaunchFlowTests`, the login shell is a stand-in that runs its `-c` line with /bin/sh and the agent is a script.
final class RightSidebarTests: XCTestCase {
    private var scratch: URL!
    private var project: String!
    private var shell: String!
    private var agentScript: String!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-sb-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let manager = FileManager.default
        for folder in ["bin", "state", "project"] { try manager.createDirectory(at: scratch.appendingPathComponent(folder), withIntermediateDirectories: true) }
        project = scratch.appendingPathComponent("project").path
        shell = scratch.appendingPathComponent("bin/sh").path
        try "#!/bin/sh\nprintf 'SHELL-UP\\n'\n[ \"$2\" = -c ] && exec /bin/sh -c \"$3\"\nexec /bin/cat\n".write(toFile: shell, atomically: true, encoding: .utf8)
        agentScript = scratch.appendingPathComponent("bin/fake-agent").path
        try "#!/bin/sh\nprintf 'FAKE-AGENT-UP\\n'\nexec /bin/sleep 30\n".write(toFile: agentScript, atomically: true, encoding: .utf8)
        for file in [shell!, agentScript!] { try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file) }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private var fake: AgentDefinition {
        AgentDefinition(id: "fake", name: "Fake", executable: agentScript, resumeArguments: ["--continue"], integration: .none, icon: .monogram("F"))
    }

    @MainActor
    private func makeModel() async throws -> (AppWorkspaceModel, UUID) {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-sb-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        _ = await model.loadWorkspace()
        model.confirmCloseSessions = { _ in true }
        model.workspaceIsFrontmost = { true }
        let saved = await model.saveLaunchSettings(shell: shell, directory: project)
        XCTAssertTrue(saved)
        model.agentCatalog = AgentCatalogSnapshot(definitions: [fake])
        _ = await model.createWindow(name: "W")
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        try await waitFor { self.text(model, pane).contains("SHELL-UP") }
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
    func testOneSharedSidebarSwitchesAndHidesViewsWithoutChangingTheWorkspace() async throws {
        let (model, _) = try await makeModel()
        defer { cleanUp(model) }
        let before = model.snapshot
        XCTAssertNil(model.visibleSidebarView)
        for view in SidebarView.allCases { XCTAssertNil(model.sidebarUnavailableReason(view), "A local shell can use \(view.title)") }

        let request = model.scratchpadFocusRequest
        model.toggleSidebarView(.scratchpad)
        XCTAssertEqual(model.visibleSidebarView, .scratchpad)
        XCTAssertEqual(model.scratchpadFocusRequest, request + 1, "Showing the scratchpad focuses its editor")
        model.toggleSidebarView(.tasks)
        XCTAssertEqual(model.visibleSidebarView, .tasks, "Another icon switches the one sidebar")
        XCTAssertFalse(model.scratchpadVisible)
        XCTAssertEqual(model.scratchpadFocusRequest, request + 1, "Only the scratchpad takes focus")
        model.toggleSidebarView(.agents)
        XCTAssertEqual(model.visibleSidebarView, .agents)
        model.toggleSidebarView(.agents)
        XCTAssertNil(model.visibleSidebarView, "The shown view's icon hides the sidebar")
        model.toggleSidebarView(.tasks)
        model.closeSidebar()
        XCTAssertNil(model.sidebarView)
        XCTAssertEqual(model.snapshot, before, "Showing, switching and hiding views is never a workspace change")
        XCTAssertEqual(SidebarView(shortcut: .toggleAgents), .agents)
        XCTAssertNil(SidebarView(shortcut: .toggleSidebar))
    }

    @MainActor
    func testAnSSHPaneDimsEveryViewAndTheSidebarComesBackWithFocus() async throws {
        let (model, local) = try await makeModel()
        defer { cleanUp(model) }
        let split = await model.splitPane(local, axis: .x, startSession: false)
        let ssh = try XCTUnwrap(split)
        _ = try await model.service.execute(.configureStoppedSession(paneID: ssh, launch: .host(UUID())))
        await model.refresh()

        _ = await model.selectPane(local)
        model.toggleSidebarView(.tasks)
        XCTAssertEqual(model.visibleSidebarView, .tasks)

        _ = await model.selectPane(ssh)
        for view in SidebarView.allCases {
            XCTAssertEqual(model.sidebarUnavailableReason(view), "\(view.title) isn't available in SSH panes.")
        }
        XCTAssertNil(model.visibleSidebarView, "The sidebar hides on a pane its view doesn't apply to")
        XCTAssertEqual(model.sidebarView, .tasks, "but remembers it")
        model.toggleSidebarView(.agents)
        XCTAssertEqual(model.sidebarView, .tasks, "A dimmed icon does nothing")
        await model.launchAgentFromSidebar("fake", resume: false)
        XCTAssertEqual(model.agentSessionRows, [], "Nothing opens for an SSH pane")

        _ = await model.selectPane(local)
        XCTAssertEqual(model.visibleSidebarView, .tasks, "It comes back when focus returns")
    }

    @MainActor
    func testTheBadgesAndRunningListCountAcrossPanesAndWindows() async throws {
        let (model, source) = try await makeModel()
        defer { cleanUp(model) }
        XCTAssertEqual(model.activeTaskCount, 0)
        model.taskRuns[source] = TaskRun(taskID: "test", name: "test", at: Date())
        XCTAssertEqual(model.activeTaskCount, 1)

        XCTAssertEqual(model.agentTarget?.machine, "this Mac")
        model.agentPlacement = .split
        await model.launchAgentFromSidebar("fake", resume: false, flipPlacement: true)
        let firstTab = try XCTUnwrap(model.snapshot.tabs[try XCTUnwrap(model.snapshot.panes[source]).tabID])
        XCTAssertEqual(firstTab.root.paneIDs, [source], "⌥ flips Split Beside Pane to a new tab")
        let agentPane = try XCTUnwrap(model.presentation.activePane?.id)
        XCTAssertNotEqual(agentPane, source)
        try await waitFor { model.terminals[agentPane]?.sessionState == .running && self.text(model, agentPane).contains("FAKE-AGENT-UP") }
        let session = try XCTUnwrap(model.terminals[agentPane]?.sessionID)

        XCTAssertEqual(model.agentSessionRows.map(\.id), [agentPane])
        XCTAssertEqual(model.agentSessionRows.first?.windowName, "W")
        XCTAssertEqual(model.agentSessionRows.first?.status, "Ready")
        XCTAssertEqual(model.agentsNeedingYouCount, 0)
        model.receiveAgentEvent(sessionID: session, event: "needs-input")
        XCTAssertEqual(model.agentsNeedingYouCount, 1)
        XCTAssertEqual(model.agentSessionRows.first?.state, .needsInput)
        XCTAssertEqual(model.agentSessionRows.first?.status, "Needs you")

        _ = await model.createWindow(name: "Other")
        XCTAssertNotEqual(model.snapshot.activeWindowID, model.snapshot.panes[agentPane].flatMap { model.snapshot.tabs[$0.tabID]?.windowID })
        XCTAssertEqual(model.agentsNeedingYouCount, 1, "Counted in every window")
        XCTAssertEqual(model.agentSessionRows.map(\.id), [agentPane], "Listed from every window")
        await model.revealPane(agentPane)
        XCTAssertEqual(model.presentation.activePane?.id, agentPane, "Choosing a row shows its pane")

        model.terminals[agentPane]?.requestTermination(force: true)
        try await waitFor { [.exited, .failed].contains(model.terminals[agentPane]?.sessionState) }
        XCTAssertEqual(model.agentsNeedingYouCount, 0, "An agent that stopped doesn't need you")
        XCTAssertNil(model.agentSessionRows.first?.state)
        XCTAssertTrue(model.agentSessionRows.first?.status.hasPrefix("Exited") == true || model.agentSessionRows.first?.status == "Failed to start")
    }
}
