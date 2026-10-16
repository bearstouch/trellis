import AppKit
import SwiftUI
import XCTest
import TrellisCore
@testable import TrellisUI

final class PaneInteractionTests: XCTestCase {
    func testS008_UT01_rejectInvalidRatios() async throws {
        let store = try WorkspaceStore()
        let initial = try await store.execute(.createWindow(name: "Project")).snapshot
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

    func testS008_UT02_directionalFocusUsesGeometry() {
        let left = UUID(), top = UUID(), bottom = UUID()
        let layout = PaneLayout.split(id: UUID(), axis: .x, ratio: 0.35, children: [.pane(left),
            .split(id: UUID(), axis: .y, ratio: 0.3, children: [.pane(top), .pane(bottom)])])
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
    func testS008_UT03_maximizeRoundTrip() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true } // Explicit cleanup authorization for owned test processes.
        await model.createWindow()
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

    func testS008_UT04_closedFocusChoosesSurvivor() async throws {
        let store = try WorkspaceStore()
        let initial = try await store.execute(.createWindow(name: "First")).snapshot
        let firstWindow = try XCTUnwrap(initial.activeWindowID)
        let left = try XCTUnwrap(initial.panes.keys.first)
        let x = try await store.execute(.splitPane(id: left, axis: .x, availableSize: TerminalSize(columns: 80, rows: 24)))
        let top = try XCTUnwrap(x.createdPaneID)
        let y = try await store.execute(.splitPane(id: top, axis: .y, availableSize: TerminalSize(columns: 40, rows: 24)))
        let bottom = try XCTUnwrap(y.createdPaneID)
        let after = try await store.execute(.deletePane(id: bottom)).snapshot
        XCTAssertEqual(after.tabs.values.first?.activePaneID, top)
        _ = try await store.execute(.deletePane(id: top))
        let fallback = try await store.execute(.createWindow(name: "Second"))
        let other = fallback.createdWindowID
        _ = try await store.execute(.selectWindow(id: firstWindow))
        let last = try await store.execute(.deletePane(id: left)).snapshot
        XCTAssertEqual(last.activeWindowID, other)
        try last.validate()
    }

    @MainActor
    func testHostedMaximizeRestoresHiddenViewsAndExactLayout() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true } // Explicit cleanup authorization for owned test processes.
        await model.createWindow(startSession: false)
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
        model.confirmForceSessions = { _ in true } // Explicit cleanup authorization for owned test processes.
        await model.createWindow(startSession: false)
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
            model.confirmForceSessions = { _ in true } // Explicit cleanup authorization for owned test processes.
            await model.createWindow(startSession: false)
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
        model.confirmForceSessions = { _ in true } // Explicit cleanup authorization for owned test processes.
        await model.createWindow(startSession: false)
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
