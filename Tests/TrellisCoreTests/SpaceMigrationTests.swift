import XCTest
@testable import TrellisCore

/// Windows were renamed spaces (workspace schema 4) and spaces now record the project they were loaded from (FR-W08).
/// Everything saved before the rename keeps loading.
final class SpaceMigrationTests: XCTestCase {
    private func workspace() async throws -> WorkspaceSnapshot {
        let store = try WorkspaceStore()
        let created = try await store.execute(.createSpace(name: "Build")).snapshot
        _ = try await store.execute(.createTab(spaceID: try XCTUnwrap(created.spaces.first?.id)))
        return await store.snapshot()
    }

    /// Rewrites a current save the way schema 3 wrote it: `windows`, `activeWindowID` and tab `windowID`.
    private func schemaThree(_ data: Data) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var saved = try XCTUnwrap(root["workspace"] as? [String: Any])
        saved["windows"] = saved.removeValue(forKey: "spaces")
        saved["activeWindowID"] = saved.removeValue(forKey: "activeSpaceID")
        saved["tabs"] = try XCTUnwrap(saved["tabs"] as? [[String: Any]]).map { tab in
            var tab = tab
            tab["windowID"] = tab.removeValue(forKey: "spaceID")
            return tab
        }
        root["workspace"] = saved
        root["schemaVersion"] = 3
        return try JSONSerialization.data(withJSONObject: root)
    }

    func testASchemaThreeWorkspaceLoadsAsSpacesAndSavesAsFour() async throws {
        let snapshot = try await workspace()
        let current = try WorkspaceSnapshotCodec.encode(snapshot, settings: WorkspaceSettings())
        let text = String(decoding: current, as: UTF8.self)
        XCTAssertTrue(text.contains("\"spaces\"") && !text.contains("windowID") && !text.contains("\"windows\""))

        let old = try schemaThree(current)
        let restored = try WorkspaceSnapshotCodec.decode(old).snapshot
        XCTAssertEqual(restored.spaces.map(\.id), snapshot.spaces.map(\.id))
        XCTAssertEqual(restored.activeSpaceID, snapshot.activeSpaceID)
        XCTAssertEqual(Set(restored.tabs.values.map(\.spaceID)), Set(snapshot.spaces.map(\.id)))
        XCTAssertTrue(restored.spaces.allSatisfy { $0.projectID == nil } && restored.tabs.values.allSatisfy { $0.projectKey == nil })

        let resaved = try XCTUnwrap(JSONSerialization.jsonObject(with: WorkspaceSnapshotCodec.encode(restored, settings: WorkspaceSettings())) as? [String: Any])
        XCTAssertEqual(resaved["schemaVersion"] as? Int, 4)
    }

    func testTheProjectLinkRoundTrips() async throws {
        var snapshot = try await workspace()
        let project = UUID()
        snapshot.spaces[0].projectID = project
        let tab = try XCTUnwrap(snapshot.spaces[0].tabIDs.first)
        snapshot.tabs[tab]?.projectKey = "t1"
        let restored = try WorkspaceSnapshotCodec.decode(WorkspaceSnapshotCodec.encode(snapshot, settings: WorkspaceSettings())).snapshot
        XCTAssertEqual(restored.spaces[0].projectID, project)
        XCTAssertEqual(restored.tabs[tab]?.projectKey, "t1")
        XCTAssertEqual(restored.spaces[0].tabIDs.compactMap { restored.tabs[$0]?.projectKey }, ["t1"], "The other tab stays temporary")
    }

    /// Customized shortcuts are stored by action name; the Space actions keep the names they had as Window actions.
    func testShortcutsSavedForWindowsApplyToSpaces() throws {
        let chord = String(decoding: try JSONEncoder().encode(KeyChord("n", [.command, .option])), as: UTF8.self)
        let data = Data(#"{"optionAsMeta":false,"overrides":{"newWindow":{"chord":\#(chord)},"nextWindow":{"chord":null}}}"#.utf8)
        let loaded = try JSONDecoder().decode(KeyboardSettings.self, from: data)
        XCTAssertEqual(loaded.shortcuts[.newSpace], KeyChord("n", [.command, .option]))
        XCTAssertNil(loaded.shortcuts[.nextSpace])
        XCTAssertEqual(ShortcutAction.newSpace.title, "New Space")
        XCTAssertEqual(ShortcutAction.nextSpace.menu, .window, "Next and Previous Space stay in the macOS Window menu")
    }

    func testLayoutBindingsSavedForWindowsStillBindSpaces() throws {
        let id = UUID()
        let old = Data(#"{"kind":"window","id":"\#(id.uuidString)"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(LayoutBinding.self, from: old), LayoutBinding(kind: .space, id: id))
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(LayoutBinding(kind: .space, id: id)), as: UTF8.self).contains("\"space\""))
        XCTAssertThrowsError(try JSONDecoder().decode(LayoutBinding.self, from: Data(#"{"kind":"room","id":"\#(id.uuidString)"}"#.utf8)))
        XCTAssertEqual(ProjectLaunch.spaceKey(), "trellis-window", "Projects launched before the rename find their space again")
    }

    // MARK: FR-W08

    private func projectLayout(_ tabs: [String]) -> LayoutDocument {
        LayoutDocument(spaces: [
            LayoutSpace(key: ProjectLaunch.spaceKey(), name: "Shop", tabs: tabs.map { LayoutTab(key: $0, title: $0, root: .pane(key: "\($0)-p", title: nil, launch: .shell(directory: nil))) })
        ])
    }

    private func plan(_ document: LayoutDocument, _ bindings: [String: LayoutBinding], _ snapshot: WorkspaceSnapshot, project: UUID?) -> LayoutPlan {
        LayoutPlanner.plan(
            document, bindings: bindings, snapshot: snapshot, home: "/Users/me", hostExists: { _ in false }, directoryExists: { _ in true },
            keepLiveLaunches: true, keepOmittedPanes: true, projectID: project)
    }

    func testAProjectLaunchLinksItsSpaceAndOnlyItsOwnTabs() async throws {
        let store = try WorkspaceStore()
        let project = UUID()
        let first = plan(projectLayout(["api", "web"]), [:], await store.snapshot(), project: project)
        var snapshot = try await store.execute(.applyLayout(target: try XCTUnwrap(first.target))).snapshot
        let space = try XCTUnwrap(snapshot.spaces.first)
        XCTAssertEqual(space.projectID, project)
        XCTAssertEqual(space.tabIDs.compactMap { snapshot.tabs[$0]?.projectKey }, ["api", "web"])

        // A tab opened by hand, or a duplicate of a project tab, is temporary.
        snapshot = try await store.execute(.createTab(spaceID: space.id)).snapshot
        snapshot = try await store.execute(.duplicateTab(id: space.tabIDs[0])).snapshot
        let temporary = try XCTUnwrap(snapshot.spaces.first).tabIDs.filter { snapshot.tabs[$0]?.projectKey == nil }
        XCTAssertEqual(temporary.count, 2)

        // Re-launching keeps the temporary tabs where they are (FR-PL08) and leaves them temporary.
        let again = plan(projectLayout(["api", "web"]), first.bindings, snapshot, project: project)
        XCTAssertTrue(again.canApply, again.conflicts.map(\.text).joined())
        XCTAssertEqual(Set(again.unmanaged).intersection(temporary), Set(temporary))
        snapshot = try await store.execute(.applyLayout(target: try XCTUnwrap(again.target))).snapshot
        XCTAssertEqual(snapshot.spaces.first?.tabIDs.filter { snapshot.tabs[$0]?.projectKey == nil }.sorted { $0.uuidString < $1.uuidString }, temporary.sorted { $0.uuidString < $1.uuidString })

        // A tab the project stops declaring stays, and becomes temporary.
        let dropped = plan(projectLayout(["api"]), again.bindings, snapshot, project: project)
        let narrowed = try XCTUnwrap(dropped.target)
        XCTAssertEqual(narrowed.spaces.first?.tabIDs.compactMap { narrowed.tabs[$0]?.projectKey }, ["api"])
        XCTAssertEqual(narrowed.spaces.first?.tabIDs.count, snapshot.spaces.first?.tabIDs.count, "Nothing is removed (FR-PL08)")

        // A layout applied through the API is not a project: it links nothing and leaves existing links alone.
        let api = plan(projectLayout(["api", "web"]), again.bindings, snapshot, project: nil)
        let applied = try XCTUnwrap(api.target)
        XCTAssertEqual(applied.spaces.first?.projectID, project)
        XCTAssertEqual(applied.spaces.first?.tabIDs.compactMap { applied.tabs[$0]?.projectKey }, ["api", "web"])
        let plain = plan(LayoutDocument(spaces: [LayoutSpace(key: "other", name: "Other", tabs: projectLayout(["x"]).spaces[0].tabs)]), [:], snapshot, project: nil)
        let other = try XCTUnwrap(plain.target?.spaces.first { $0.name == "Other" })
        XCTAssertNil(other.projectID)
        XCTAssertTrue(other.tabIDs.allSatisfy { plain.target?.tabs[$0]?.projectKey == nil })
    }
}
