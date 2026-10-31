import AppKit
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// Agents end to end on this Mac (FR-AG04–FR-AG12). The login shell is a stand-in that runs its `-c` line with /bin/sh,
/// so no user startup file is read; the agents are small scripts.
final class AgentLaunchFlowTests: XCTestCase {
    private var scratch: URL!
    private var project: String!
    private var shell: String!
    private var agentScript: String!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-ag-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let manager = FileManager.default
        for folder in ["bin", "state", "project"] { try manager.createDirectory(at: scratch.appendingPathComponent(folder), withIntermediateDirectories: true) }
        project = scratch.appendingPathComponent("project").path
        shell = scratch.appendingPathComponent("bin/sh").path
        try "#!/bin/sh\nprintf 'SHELL-UP\\n'\n[ \"$2\" = -c ] && exec /bin/sh -c \"$3\"\nexec /bin/cat\n".write(toFile: shell, atomically: true, encoding: .utf8)
        agentScript = scratch.appendingPathComponent("bin/fake-agent").path
        try "#!/bin/sh\nprintf 'FAKE-AGENT-UP %s %s\\n' \"$PWD\" \"$*\"\nexec /bin/sleep 30\n".write(toFile: agentScript, atomically: true, encoding: .utf8)
        for file in [shell!, agentScript!] { try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file) }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private var fake: AgentDefinition {
        AgentDefinition(
            id: "fake", name: "Fake", executable: agentScript, resumeArguments: ["--continue"], integration: .none, icon: .monogram("F"),
            install: ["darwin": AgentInstallRecipe(command: "true")])
    }
    private var missing: AgentDefinition {
        AgentDefinition(id: "missing", name: "Missing", executable: scratch.appendingPathComponent("bin/not-installed").path, install: ["darwin": AgentInstallRecipe(command: "true", requires: ["npm"])])
    }

    @MainActor
    private func makeModel() async throws -> (AppWorkspaceModel, UUID) {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-ag-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        _ = await model.loadWorkspace()
        model.confirmCloseSessions = { _ in true }
        model.workspaceIsFrontmost = { true }
        let saved = await model.saveLaunchSettings(shell: shell, directory: project)
        XCTAssertTrue(saved)
        model.agentCatalog = AgentCatalogSnapshot(definitions: [fake, missing])
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
    func testTheAgentButtonOpensTheAgentBesideThePaneWithItsIconAndTitle() async throws {
        let (model, source) = try await makeModel()
        defer { cleanUp(model) }
        let tab = try XCTUnwrap(model.presentation.selectedTab?.id)
        XCTAssertNil(model.tabAgent(tabID: tab), "A shell tab keeps its terminal icon")

        await model.launchAgent("fake", from: source)
        let agentPane = try XCTUnwrap(model.snapshot.tabs[tab]?.activePaneID)
        XCTAssertNotEqual(agentPane, source)
        XCTAssertEqual(model.snapshot.tabs[tab]?.root.paneIDs, [source, agentPane], "A split beside the source pane")
        XCTAssertEqual(model.agentLaunch(paneID: agentPane)?.agentID, "fake")
        try await waitFor { self.text(model, agentPane).contains("FAKE-AGENT-UP") }
        // $PWD names /private/var where the test's path says /var.
        XCTAssertTrue(text(model, agentPane).contains("/trellis-ag-"), "It starts in the pane's directory")
        XCTAssertTrue(text(model, agentPane).contains("/project \n") || text(model, agentPane).contains("/project "), "It starts in the pane's directory")
        XCTAssertEqual(model.tabAgent(tabID: tab)?.id, "fake", "The tab's icon becomes the agent's")
        XCTAssertEqual(model.paneTitle(agentPane), "Fake · project")
        XCTAssertNil(model.snapshot.panes[source].flatMap { model.agentLaunch(paneID: $0.id) }, "The shell is left untouched")

        model.terminals[agentPane]?.requestTermination(force: true)
        try await waitFor { [.exited, .failed].contains(model.terminals[agentPane]?.sessionState) }
        XCTAssertNil(model.tabAgent(tabID: tab), "Back to the terminal icon once the agent exits")

        await model.restartAgent(paneID: agentPane, resume: true)
        try await waitFor { self.text(model, agentPane).contains("--continue") }
        XCTAssertTrue(text(model, agentPane).contains("/project --continue"), "Resume passes the agent's resume arguments")
    }

    @MainActor
    func testANewTabPlacementAndHookEventsDriveTheTabBadge() async throws {
        let (model, source) = try await makeModel()
        defer { cleanUp(model) }
        let firstTab = try XCTUnwrap(model.presentation.selectedTab?.id)
        await model.launchAgent("fake", from: source, placement: .tab)
        let tab = try XCTUnwrap(model.presentation.selectedTab?.id)
        XCTAssertNotEqual(tab, firstTab)
        let pane = try XCTUnwrap(model.snapshot.tabs[tab]?.activePaneID)
        try await waitFor { self.text(model, pane).contains("FAKE-AGENT-UP") }
        let session = try XCTUnwrap(model.terminals[pane]?.sessionID)

        model.receiveAgentEvent(sessionID: session, event: "working")
        XCTAssertEqual(model.agentBadge(tabID: tab)?.state, .working)
        model.receiveAgentEvent(sessionID: session, event: "not-an-event")
        XCTAssertEqual(model.agentBadge(tabID: tab)?.state, .working, "Unknown events change nothing")
        model.receiveAgentEvent(sessionID: UUID(), event: "error")
        XCTAssertEqual(model.agentBadge(tabID: tab)?.state, .working, "Another session's event never lands here")

        await model.selectTab(firstTab)
        model.receiveAgentEvent(sessionID: session, event: "done")
        XCTAssertEqual(model.agentBadge(tabID: tab)?.state, .done, "Finished out of view: Done shows")
        XCTAssertEqual(model.tabPreviews(windowID: try XCTUnwrap(model.snapshot.activeWindowID)).first { $0.id == tab }?.agentState, .done)
        await model.selectTab(tab)
        XCTAssertNil(model.agentBadge(tabID: tab), "Seeing it clears Done")

        model.terminals[pane]?.onAttentionRequested?()
        XCTAssertEqual(model.agentStates[pane]?.state, .done, "A bell after a finished turn isn't a question")
        model.receiveAgentEvent(sessionID: session, event: "needs-input")
        XCTAssertEqual(model.agentBadge(tabID: tab)?.state, .needsInput)
    }

    @MainActor
    func testAMissingAgentOffersItsInstallerAndRunsItInThePane() async throws {
        let (model, source) = try await makeModel()
        defer { cleanUp(model) }
        await model.launchAgent("missing", from: source)
        try await waitFor { model.agentInstallOffer != nil }
        let offer = try XCTUnwrap(model.agentInstallOffer)
        XCTAssertEqual(offer.agent.id, "missing")
        XCTAssertNil(offer.hostID)
        XCTAssertEqual(offer.recipe?.command, "true")
        XCTAssertFalse(offer.afterInstall)
        XCTAssertEqual(model.agentAvailability["missing"], .missing)

        // The installer runs first in the same pane; the agent is still missing afterwards, which the offer then says.
        await model.installAgent(offer)
        XCTAssertNil(model.agentInstallOffer)
        try await waitFor { model.agentInstallOffer != nil }
        XCTAssertEqual(model.agentInstallOffer?.afterInstall, true)
        XCTAssertEqual(model.agentInstallOffer?.paneID, offer.paneID)
    }

    @MainActor
    func testTheCommandPaletteListsAgentsForTheFocusedPane() async throws {
        let (model, source) = try await makeModel()
        defer { cleanUp(model) }
        let items = model.commandPaletteItems.filter { $0.kind == .agent }
        XCTAssertEqual(items.map(\.title), ["Launch Agent: Fake", "Launch Agent: Missing"])
        await model.performCommandPaletteTarget(.agent("fake"), modifier: .none)
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        XCTAssertEqual(tab.root.paneIDs.first, source)
        XCTAssertEqual(model.agentLaunch(paneID: tab.activePaneID)?.agentID, "fake")
    }
}
