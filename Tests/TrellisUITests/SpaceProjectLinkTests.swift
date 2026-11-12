import XCTest
import TrellisControl
import TrellisCore
@testable import TrellisUI

/// FR-W08: a space loaded from a project knows it, and tabs the project doesn't define read as temporary, in the UI
/// and over the API. The API still answers to the old window names (deprecated).
final class SpaceProjectLinkTests: XCTestCase {
    @MainActor
    func testProjectSpacesMarkTemporaryTabsAndTheAPIReportsThem() async throws {
        let h = try Harness()
        defer { h.model.terminals.values.forEach { $0.adapter.detach() }; h.discardPreferences() }
        try await h.grant("full")
        let project = ProjectDefinition(name: "Shop", tabs: [ProjectTab(title: "API")])
        var library = [project]
        h.model.commandPaletteProjects = { library }
        let document = LayoutDocument(spaces: [
            LayoutSpace(key: ProjectLaunch.spaceKey(), name: "Shop", tabs: [LayoutTab(key: "t1", title: "API", root: .pane(key: "t1-1", title: nil, launch: .shell(directory: nil)))])
        ])
        let plan = LayoutPlanner.plan(
            document, bindings: [:], snapshot: h.model.snapshot, home: "/tmp", hostExists: { _ in false }, directoryExists: { _ in true }, keepLiveLaunches: true,
            keepOmittedPanes: true, projectID: project.id)
        h.model.publish(try await h.model.service.execute(.applyLayout(target: try XCTUnwrap(plan.target))).snapshot)
        let space = try XCTUnwrap(h.model.snapshot.spaces.first)
        let projectTab = try XCTUnwrap(space.tabIDs.first.flatMap { h.model.snapshot.tabs[$0] })
        let created = await h.model.createTab(spaceID: space.id, startSessions: false)
        let added = try XCTUnwrap(created)
        let temporaryTab = try XCTUnwrap(h.model.snapshot.tabs[added])

        XCTAssertEqual(h.model.projectName(of: space), "Shop")
        XCTAssertFalse(h.model.isTemporaryTab(projectTab))
        XCTAssertTrue(h.model.isTemporaryTab(temporaryTab))

        let detail: [String: Any] = try await h.value("space", "space.get", ["id": space.id.uuidString])
        XCTAssertEqual((detail["project"] as? [String: Any])?["id"] as? String, lower(project.id))
        // Protocol 1's names are gone: window.* and windowId are refused, never mapped.
        let window = try await h.call("window.list")
        XCTAssertEqual((window["error"] as? [String: Any])?["code"] as? Int, -32601)
        let windowID = try await h.call("tab.list", ["windowId": space.id.uuidString])
        XCTAssertEqual((windowID["error"] as? [String: Any])?["code"] as? Int, -32602)
        let tabList = try result(try await h.call("tab.list", ["spaceId": space.id.uuidString]))
        let tabs = try XCTUnwrap(tabList["tabs"] as? [[String: Any]])
        XCTAssertEqual(tabs.map { $0["role"] as? String }, ["project", "temporary"])

        // A deleted project leaves a plain space: no project name, no temporary tabs.
        library = []
        XCTAssertNil(h.model.projectName(of: space))
        XCTAssertFalse(h.model.isTemporaryTab(temporaryTab))
        XCTAssertEqual(h.model.snapshot.spaces.first?.projectID, project.id, "The link itself is kept")
    }
}
