import AppKit
import SwiftUI
import XCTest
import TrellisCore
@testable import TrellisUI

final class PaneInteractionTests: XCTestCase {
    func testRejectInvalidRatios() async throws {
        let store = try WorkspaceStore()
        let initial = try await store.execute(.createSpace(name: "Project")).snapshot
        let first = try XCTUnwrap(initial.panes.keys.first)
        let split = try await store.execute(.splitPane(id: first, axis: .x, availableSize: TerminalSize(columns: 80, rows: 24))).snapshot
        let tab = try XCTUnwrap(split.tabs.values.first)
        guard case .split(let branch, _, _, _) = tab.root else { return XCTFail("Missing split") }
        let canvas = CanvasDimensions(width: 800, height: 600)
        for ratio in [Double.nan, .infinity, -.infinity, 0.09, 0.91, 0.1, 0.9] {
            do { _ = try await store.execute(.resizeSplit(tabID: tab.id, splitID: branch, ratio: ratio, canvas: canvas)); XCTFail("Accepted invalid/impossible ratio") } catch {}
            let unchanged = await store.snapshot()
            XCTAssertEqual(unchanged, split)
        }
        for invalid in [CanvasDimensions(width: .nan, height: 600), CanvasDimensions(width: 800, height: .infinity), CanvasDimensions(width: 800, height: 80)] {
            do { _ = try await store.execute(.resizeSplit(tabID: tab.id, splitID: branch, ratio: 0.5, canvas: invalid)); XCTFail("Accepted invalid canvas") } catch {}
        }
        let valid = try await store.execute(.resizeSplit(tabID: tab.id, splitID: branch, ratio: 0.25, canvas: canvas)).snapshot
        XCTAssertEqual(valid.tabs[tab.id]?.root, tab.root.resizing(splitID: branch, ratio: 0.25))
        XCTAssertEqual(valid.sessions, split.sessions)
        XCTAssertEqual(valid.panes, split.panes)
    }

    func testDraggedDividerStopsAtPaneMinimumsAndStoreAcceptsIt() async throws {
        let store = try WorkspaceStore()
        let initial = try await store.execute(.createSpace(name: "Project")).snapshot
        let first = try XCTUnwrap(initial.panes.keys.first)
        let once = try await store.execute(.splitPane(id: first, axis: .x, availableSize: TerminalSize(columns: 200, rows: 60))).snapshot
        let second = try XCTUnwrap(once.tabs.values.first?.activePaneID)
        let twice = try await store.execute(.splitPane(id: second, axis: .x, availableSize: TerminalSize(columns: 100, rows: 60))).snapshot
        let tab = try XCTUnwrap(twice.tabs.values.first)
        guard case .split(let outer, _, _, let children) = tab.root, case .split = children[1] else { return XCTFail("Missing nested split") }
        // Left pane | (middle | right): the nested split needs 321 points, a single pane 160.
        let canvas = CanvasDimensions(width: 1001, height: 600)
        let free = try XCTUnwrap(CanvasDimensions.dividerRatio(nearest: 0.4004, in: tab.root, length: canvas.width))
        XCTAssertEqual(free * 1000, 400, accuracy: 1e-6, "The first pane gets whole points")
        let low = try XCTUnwrap(CanvasDimensions.dividerRatio(nearest: -3, in: tab.root, length: canvas.width))
        let high = try XCTUnwrap(CanvasDimensions.dividerRatio(nearest: 7, in: tab.root, length: canvas.width))
        XCTAssertEqual(low * 1000, 160, accuracy: 1e-3)
        XCTAssertEqual((1 - high) * 1000, 321, accuracy: 1e-3)
        for ratio in [low, high, free] {
            let resized = try await store.execute(.resizeSplit(tabID: tab.id, splitID: outer, ratio: ratio, canvas: canvas)).snapshot
            XCTAssertEqual(resized.tabs[tab.id]?.root, tab.root.resizing(splitID: outer, ratio: ratio))
        }
        // A wide canvas stops at the 10–90% range instead.
        XCTAssertEqual(try XCTUnwrap(CanvasDimensions.dividerRatio(nearest: 0, in: tab.root, length: 5001)), 0.1, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(CanvasDimensions.dividerRatio(nearest: 1, in: tab.root, length: 5001)), 0.9, accuracy: 1e-6)
        // No room to move, not a split, or a meaningless request: the divider stays where it is.
        XCTAssertNil(CanvasDimensions.dividerRatio(nearest: 0.5, in: tab.root, length: 400))
        XCTAssertNil(CanvasDimensions.dividerRatio(nearest: 0.5, in: .pane(first), length: 1000))
        XCTAssertNil(CanvasDimensions.dividerRatio(nearest: .nan, in: tab.root, length: 1000))
    }

    func testDirectionalFocusUsesGeometry() {
        let left = UUID(), top = UUID(), bottom = UUID()
        let layout = PaneLayout.split(
            id: UUID(), axis: .x, ratio: 0.35,
            children: [
                .pane(left),
                .split(id: UUID(), axis: .y, ratio: 0.3, children: [.pane(top), .pane(bottom)])
            ])
        let geometry = PaneGeometry(layout: layout, canvas: CanvasDimensions(width: 1000, height: 700))
        XCTAssertEqual(geometry.neighbor(of: left, direction: .right), bottom)
        XCTAssertEqual(geometry.neighbor(of: top, direction: .down), bottom)
        XCTAssertEqual(geometry.neighbor(of: bottom, direction: .up), top)
        XCTAssertEqual(geometry.neighbor(of: top, direction: .left), left)
        XCTAssertEqual(geometry.neighbor(of: bottom, direction: .left), left)
        XCTAssertNil(geometry.neighbor(of: top, direction: .right))
        XCTAssertNil(geometry.neighbor(of: left, direction: .up))
        XCTAssertNil(geometry.neighbor(of: UUID(), direction: .left))
    }

    @MainActor
    func testMaximizeRoundTrip() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createSpace()
        let first = try XCTUnwrap(model.presentation.activePane?.id)
        await model.splitPane(first, axis: .x)
        let second = try XCTUnwrap(model.presentation.activePane?.id)
        let tabID = try XCTUnwrap(model.presentation.selectedTab?.id)
        await model.waitForUpdates()
        let before = model.snapshot
        let terminals = model.terminals
        let pids = model.terminals.mapValues(\.processID)
        await model.toggleMaximize(second)
        XCTAssertEqual(model.maximizedPanes[tabID], second)
        XCTAssertEqual(model.snapshot, before)
        await model.toggleMaximize(second)
        XCTAssertNil(model.maximizedPanes[tabID])
        XCTAssertEqual(model.snapshot, before)
        XCTAssertEqual(model.terminals.mapValues(\.processID), pids)
        for (id, terminal) in terminals { XCTAssertTrue(model.terminals[id] === terminal); XCTAssertTrue(terminal.isRunning) }
        await model.shutdown()
    }

    func testClosedFocusChoosesSurvivor() async throws {
        let store = try WorkspaceStore()
        let initial = try await store.execute(.createSpace(name: "First")).snapshot
        let firstSpace = try XCTUnwrap(initial.activeSpaceID)
        let left = try XCTUnwrap(initial.panes.keys.first)
        let x = try await store.execute(.splitPane(id: left, axis: .x, availableSize: TerminalSize(columns: 80, rows: 24)))
        let top = try XCTUnwrap(x.createdPaneID)
        let y = try await store.execute(.splitPane(id: top, axis: .y, availableSize: TerminalSize(columns: 40, rows: 24)))
        let bottom = try XCTUnwrap(y.createdPaneID)
        let after = try await store.execute(.deletePane(id: bottom)).snapshot
        XCTAssertEqual(after.tabs.values.first?.activePaneID, top)
        _ = try await store.execute(.deletePane(id: top))
        let fallback = try await store.execute(.createSpace(name: "Second"))
        let other = fallback.createdSpaceID
        _ = try await store.execute(.selectSpace(id: firstSpace))
        let last = try await store.execute(.deletePane(id: left)).snapshot
        XCTAssertEqual(last.activeSpaceID, other)
        try last.validate()
    }

    @MainActor
    func testHostedMaximizeRestoresHiddenViewsAndExactLayout() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createSpace(startSession: false)
        let first = try XCTUnwrap(model.presentation.activePane?.id)
        await model.splitPane(first, axis: .x, startSession: false)
        let second = try XCTUnwrap(model.presentation.activePane?.id)
        let original = model.snapshot
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceRootView(model: model))
        defer { window.close() }
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        await model.toggleMaximize(second)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.terminals[second]?.view.window === window)
        XCTAssertNil(model.terminals[first]?.view.window)
        await model.toggleMaximize(second)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        for terminal in model.terminals.values { XCTAssertTrue(terminal.view.window === window) }
        XCTAssertEqual(model.snapshot, original)
    }

    @MainActor
    func testNavigationAndKeyboardResizeUseActiveTabCanvas() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createSpace(startSession: false)
        let left = try XCTUnwrap(model.presentation.activePane?.id)
        await model.splitPane(left, axis: .x, startSession: false)
        let right = try XCTUnwrap(model.presentation.activePane?.id)
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        model.setCanvasSize(CanvasDimensions(width: 1000, height: 700), tabID: tab.id)
        await model.focusPane(.left)
        XCTAssertEqual(model.presentation.activePane?.id, left)
        await model.resizeFocusedPane(.right)
        guard case .split(_, _, let ratio, _) = model.presentation.selectedTab?.root else { return XCTFail("Missing split") }
        XCTAssertEqual(ratio, 0.55, accuracy: 0.0001)
        await model.toggleMaximize(left)
        let saved = model.snapshot
        await model.focusPane(.right)
        XCTAssertEqual(model.presentation.activePane?.id, right)
        XCTAssertEqual(model.maximizedPanes[tab.id], right)
        await model.closePane(right)
        XCTAssertNil(model.maximizedPanes[tab.id])
        XCTAssertEqual(model.presentation.activePane?.id, left)
        XCTAssertEqual(model.snapshot.sessions.count, saved.sessions.count - 1)
    }

    @MainActor
    func testMaximizeAndNavigationCannotRestoreAClosingPane() async throws {
        _ = NSApplication.shared
        for _ in 0..<12 {
            let model = AppWorkspaceModel(store: try WorkspaceStore())
            model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
            await model.createSpace(startSession: false)
            let first = try XCTUnwrap(model.presentation.activePane?.id)
            await model.splitPane(first, axis: .x, startSession: false)
            let second = try XCTUnwrap(model.presentation.activePane?.id)
            let tabID = try XCTUnwrap(model.presentation.selectedTab?.id)
            model.setCanvasSize(CanvasDimensions(width: 1000, height: 700), tabID: tabID)
            await model.toggleMaximize(first)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await model.toggleMaximize(second) }
                group.addTask { await model.focusPane(.right) }
                group.addTask { await model.closePane(second) }
            }
            XCTAssertNil(model.snapshot.panes[second])
            for (tab, pane) in model.maximizedPanes {
                XCTAssertTrue(model.snapshot.tabs[tab]?.root.paneIDs.contains(pane) == true)
            }
            let selected = await model.selectPane(second)
            XCTAssertFalse(selected)
            XCTAssertNil(model.errorMessage)
        }
    }

    @MainActor
    func testSameSizedTabSwitchRegistersCanvasForKeyboardResize() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createSpace(startSession: false)
        let first = try XCTUnwrap(model.presentation.activePane?.id)
        await model.splitPane(first, axis: .x, startSession: false)
        let originalTab = try XCTUnwrap(model.presentation.selectedTab?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceRootView(model: model))
        defer { window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        await model.createTab(duplicate: originalTab, startSessions: false)
        let duplicate = try XCTUnwrap(model.presentation.selectedTab?.id)
        try await Task.sleep(for: .milliseconds(100))
        await model.resizeFocusedPane(.right)
        guard case .split(_, _, let ratio, _) = model.snapshot.tabs[duplicate]?.root else { return XCTFail("Missing split") }
        XCTAssertEqual(ratio, 0.55, accuracy: 0.0001)
        XCTAssertNil(model.errorMessage)
    }

}
