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
        let windowResult = await model.createWindow(name: "One", startSession: false)
        let window = try XCTUnwrap(windowResult)
        let first = try XCTUnwrap(model.presentation.selectedTab?.id)
        let secondResult = await model.createTab(windowID: window, startSessions: false)
        let thirdResult = await model.createTab(windowID: window, startSessions: false)
        return (model, window, [first, try XCTUnwrap(secondResult), try XCTUnwrap(thirdResult)])
    }

    private func order(_ model: AppWorkspaceModel, _ window: UUID) -> [UUID] { model.snapshot.windows.first { $0.id == window }?.tabIDs ?? [] }

    func testDraggingRightLandsAfterTargetAndLeftLandsBefore() async throws {
        let (model, window, tabs) = try await makeThreeTabs()
        let (a, b, c) = (tabs[0], tabs[1], tabs[2])
        await model.moveTab(a, to: c)
        XCTAssertEqual(order(model, window), [b, c, a])
        await model.moveTab(a, to: b)
        XCTAssertEqual(order(model, window), [a, b, c])
        await model.moveTab(c, to: b)
        XCTAssertEqual(order(model, window), [a, c, b])
        XCTAssertNil(model.errorMessage)
    }

    func testDragKeepsSelectionAndPanes() async throws {
        let (model, window, tabs) = try await makeThreeTabs()
        let selected = try XCTUnwrap(model.presentation.selectedTab?.id)
        let panes = model.snapshot.panes
        await model.moveTab(tabs[0], to: tabs[2])
        XCTAssertEqual(model.presentation.selectedTab?.id, selected)
        XCTAssertEqual(model.snapshot.panes, panes)
        XCTAssertEqual(model.presentation.visibleTabs.map(\.id), order(model, window))
    }

    func testDropOnItselfUnknownOrOtherWindowTabChangesNothing() async throws {
        let (model, window, tabs) = try await makeThreeTabs()
        _ = await model.createWindow(name: "Two", startSession: false)
        let other = try XCTUnwrap(model.presentation.selectedTab?.id)
        let before = model.snapshot
        await model.moveTab(tabs[1], to: tabs[1])
        await model.moveTab(UUID(), to: tabs[1])
        await model.moveTab(tabs[1], to: UUID())
        await model.moveTab(other, to: tabs[0])
        await model.moveTab(tabs[0], to: other)
        XCTAssertEqual(model.snapshot, before)
        XCTAssertEqual(order(model, window), tabs)
        XCTAssertNil(model.errorMessage)
    }
}

/// FR-W07: dragging a window onto another takes the target's place.
@MainActor
final class WindowDragReorderTests: XCTestCase {
    private func makeThreeWindows() async throws -> (AppWorkspaceModel, [UUID]) {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        var ids: [UUID] = []
        for name in ["A", "B", "C"] {
            let result = await model.createWindow(name: name, startSession: false)
            ids.append(try XCTUnwrap(result))
        }
        return (model, ids)
    }

    func testDraggingDownLandsBelowTargetAndUpLandsAbove() async throws {
        let (model, ids) = try await makeThreeWindows()
        let (a, b, c) = (ids[0], ids[1], ids[2])
        await model.moveWindow(a, to: c)
        XCTAssertEqual(model.snapshot.windows.map(\.id), [b, c, a])
        await model.moveWindow(a, to: b)
        XCTAssertEqual(model.snapshot.windows.map(\.id), [a, b, c])
        XCTAssertNil(model.errorMessage)
    }

    func testDragKeepsSelectionTabsAndPanes() async throws {
        let (model, ids) = try await makeThreeWindows()
        let active = model.snapshot.activeWindowID
        let (tabs, panes) = (model.snapshot.tabs, model.snapshot.panes)
        await model.moveWindow(ids[2], to: ids[0])
        XCTAssertEqual(model.snapshot.windows.map(\.id), [ids[2], ids[0], ids[1]])
        XCTAssertEqual(model.snapshot.activeWindowID, active)
        XCTAssertEqual(model.snapshot.tabs, tabs)
        XCTAssertEqual(model.snapshot.panes, panes)
    }

    func testDropOnItselfOrUnknownOrATabChangesNothing() async throws {
        let (model, ids) = try await makeThreeWindows()
        let tab = try XCTUnwrap(model.presentation.selectedTab?.id)
        let before = model.snapshot
        await model.moveWindow(ids[1], to: ids[1])
        await model.moveWindow(UUID(), to: ids[1])
        await model.moveWindow(ids[1], to: UUID())
        await model.moveWindow(tab, to: ids[0])
        await model.moveWindow(ids[0], to: tab)
        XCTAssertEqual(model.snapshot, before)
        XCTAssertNil(model.errorMessage)
    }
}
