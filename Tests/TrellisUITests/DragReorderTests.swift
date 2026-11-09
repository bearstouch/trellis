import AppKit
import XCTest
import TrellisCore
@testable import TrellisUI

/// FR-T10: dragging a tab onto another takes the target's place.
@MainActor
final class TabDragReorderTests: XCTestCase {
    private func makeThreeTabs() async throws -> (AppWorkspaceModel, UUID, [UUID]) {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        let spaceResult = await model.createSpace(name: "One", startSession: false)
        let space = try XCTUnwrap(spaceResult)
        let first = try XCTUnwrap(model.presentation.selectedTab?.id)
        let secondResult = await model.createTab(spaceID: space, startSessions: false)
        let thirdResult = await model.createTab(spaceID: space, startSessions: false)
        return (model, space, [first, try XCTUnwrap(secondResult), try XCTUnwrap(thirdResult)])
    }

    private func order(_ model: AppWorkspaceModel, _ space: UUID) -> [UUID] { model.snapshot.spaces.first { $0.id == space }?.tabIDs ?? [] }

    func testDraggingRightLandsAfterTargetAndLeftLandsBefore() async throws {
        let (model, space, tabs) = try await makeThreeTabs()
        let (a, b, c) = (tabs[0], tabs[1], tabs[2])
        await model.moveTab(a, to: c)
        XCTAssertEqual(order(model, space), [b, c, a])
        await model.moveTab(a, to: b)
        XCTAssertEqual(order(model, space), [a, b, c])
        await model.moveTab(c, to: b)
        XCTAssertEqual(order(model, space), [a, c, b])
        XCTAssertNil(model.errorMessage)
    }

    func testDragKeepsSelectionAndPanes() async throws {
        let (model, space, tabs) = try await makeThreeTabs()
        let selected = try XCTUnwrap(model.presentation.selectedTab?.id)
        let panes = model.snapshot.panes
        await model.moveTab(tabs[0], to: tabs[2])
        XCTAssertEqual(model.presentation.selectedTab?.id, selected)
        XCTAssertEqual(model.snapshot.panes, panes)
        XCTAssertEqual(model.presentation.visibleTabs.map(\.id), order(model, space))
    }

    func testDropOnItselfUnknownOrOtherSpaceTabChangesNothing() async throws {
        let (model, space, tabs) = try await makeThreeTabs()
        _ = await model.createSpace(name: "Two", startSession: false)
        let other = try XCTUnwrap(model.presentation.selectedTab?.id)
        let before = model.snapshot
        await model.moveTab(tabs[1], to: tabs[1])
        await model.moveTab(UUID(), to: tabs[1])
        await model.moveTab(tabs[1], to: UUID())
        await model.moveTab(other, to: tabs[0])
        await model.moveTab(tabs[0], to: other)
        XCTAssertEqual(model.snapshot, before)
        XCTAssertEqual(order(model, space), tabs)
        XCTAssertNil(model.errorMessage)
    }
}

/// FR-W07: dragging a window onto another takes the target's place.
@MainActor
final class SpaceDragReorderTests: XCTestCase {
    private func makeThreeSpaces() async throws -> (AppWorkspaceModel, [UUID]) {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        var ids: [UUID] = []
        for name in ["A", "B", "C"] {
            let result = await model.createSpace(name: name, startSession: false)
            ids.append(try XCTUnwrap(result))
        }
        return (model, ids)
    }

    func testDraggingDownLandsBelowTargetAndUpLandsAbove() async throws {
        let (model, ids) = try await makeThreeSpaces()
        let (a, b, c) = (ids[0], ids[1], ids[2])
        await model.moveSpace(a, to: c)
        XCTAssertEqual(model.snapshot.spaces.map(\.id), [b, c, a])
        await model.moveSpace(a, to: b)
        XCTAssertEqual(model.snapshot.spaces.map(\.id), [a, b, c])
        XCTAssertNil(model.errorMessage)
    }

    func testDragKeepsSelectionTabsAndPanes() async throws {
        let (model, ids) = try await makeThreeSpaces()
        let active = model.snapshot.activeSpaceID
        let (tabs, panes) = (model.snapshot.tabs, model.snapshot.panes)
        await model.moveSpace(ids[2], to: ids[0])
        XCTAssertEqual(model.snapshot.spaces.map(\.id), [ids[2], ids[0], ids[1]])
        XCTAssertEqual(model.snapshot.activeSpaceID, active)
        XCTAssertEqual(model.snapshot.tabs, tabs)
        XCTAssertEqual(model.snapshot.panes, panes)
    }

    func testDropOnItselfOrUnknownOrATabChangesNothing() async throws {
        let (model, ids) = try await makeThreeSpaces()
        let tab = try XCTUnwrap(model.presentation.selectedTab?.id)
        let before = model.snapshot
        await model.moveSpace(ids[1], to: ids[1])
        await model.moveSpace(UUID(), to: ids[1])
        await model.moveSpace(ids[1], to: UUID())
        await model.moveSpace(tab, to: ids[0])
        await model.moveSpace(ids[0], to: tab)
        XCTAssertEqual(model.snapshot, before)
        XCTAssertNil(model.errorMessage)
    }
}
