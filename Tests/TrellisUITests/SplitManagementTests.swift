import AppKit
import SwiftUI
import XCTest
import TrellisCore
@testable import TrellisUI

final class SplitManagementTests: XCTestCase {
    func testS007_UT01_mixedAxisSplitPreservesLeaf() async throws {
        let store = try WorkspaceStore()
        let initial = try await store.execute(.createWindow(name: "Project")).snapshot
        let original = try XCTUnwrap(initial.panes.values.first)
        let first = try await store.execute(.splitPane(id: original.id, axis: .x, availableSize: TerminalSize(columns: 80, rows: 24)))
        let second = try await store.execute(.splitPane(id: try XCTUnwrap(first.createdPaneID), axis: .y, availableSize: TerminalSize(columns: 40, rows: 24)))
        let tab = try XCTUnwrap(second.snapshot.tabs.values.first)
        guard case .split(_, .x, 0.5, let children) = tab.root,
            case .split(_, .y, 0.5, let nested) = children[1]
        else { return XCTFail("Expected mixed-axis topology") }
        XCTAssertEqual(children[0], .pane(original.id))
        XCTAssertEqual(nested[0], .pane(try XCTUnwrap(first.createdPaneID)))
        XCTAssertEqual(nested[1], .pane(try XCTUnwrap(second.createdPaneID)))
        XCTAssertEqual(second.snapshot.panes[original.id]?.sessionID, original.sessionID)
        XCTAssertEqual(Set(second.snapshot.panes.values.map(\.sessionID)).count, 3)
        try second.snapshot.validate()
    }

    func testS007_UT02_closeCollapsesOnlyParent() async throws {
        let store = try WorkspaceStore()
        let initial = try await store.execute(.createWindow(name: "Project")).snapshot
        let original = try XCTUnwrap(initial.panes.keys.first)
        let x = try await store.execute(.splitPane(id: original, axis: .x, availableSize: TerminalSize(columns: 80, rows: 24)))
        let sibling = try XCTUnwrap(x.createdPaneID)
        let y = try await store.execute(.splitPane(id: sibling, axis: .y, availableSize: TerminalSize(columns: 40, rows: 24)))
        let removed = try XCTUnwrap(y.createdPaneID)
        let survivor = y.snapshot.panes[sibling]
        let result = try await store.execute(.deletePane(id: removed)).snapshot
        XCTAssertEqual(result.tabs.values.first?.root, x.snapshot.tabs.values.first?.root)
        XCTAssertEqual(result.panes[sibling], survivor)
        XCTAssertEqual(result.panes[original], initial.panes[original])
        XCTAssertNil(result.panes[removed])
        XCTAssertEqual(result.tabs.values.first?.activePaneID, sibling)
        try result.validate()
    }

    func testS007_UT03_lastLeafCascadesToEmpty() async throws {
        let store = try WorkspaceStore()
        let created = try await store.execute(.createWindow(name: "Project"))
        let removed = try await store.execute(.deletePane(id: try XCTUnwrap(created.snapshot.panes.keys.first))).snapshot
        XCTAssertTrue(removed.windows.isEmpty)
        XCTAssertTrue(removed.tabs.isEmpty)
        XCTAssertTrue(removed.panes.isEmpty)
        XCTAssertTrue(removed.sessions.isEmpty)
        XCTAssertNil(removed.activeWindowID)
        XCTAssertEqual(removed.revision, created.snapshot.revision + 1)
        try removed.validate()
    }

    func testS007_UT04_rejectSplitLimitsAtomically() async throws {
        let store = try WorkspaceStore()
        var result = try await store.execute(.createWindow(name: "Deep"))
        var leaf = try XCTUnwrap(result.snapshot.panes.keys.first)
        for _ in 0..<16 {
            result = try await store.execute(.splitPane(id: leaf, axis: .x, availableSize: TerminalSize(columns: 40, rows: 5)))
            leaf = try XCTUnwrap(result.createdPaneID)
        }
        let depthBoundary = result.snapshot
        do { _ = try await store.execute(.splitPane(id: leaf, axis: .x, availableSize: TerminalSize(columns: 40, rows: 5))); XCTFail("Accepted depth17") } catch {}
        var unchanged = await store.snapshot()
        XCTAssertEqual(unchanged, depthBoundary)
        let capacity = try WorkspaceStore()
        for index in 0..<99 { _ = try await capacity.execute(.createWindow(name: "Window \(index)")) }
        let original = await capacity.snapshot()
        let target = try XCTUnwrap(original.panes.keys.first)
        let hundred = try await capacity.execute(.splitPane(id: target, axis: .y, availableSize: TerminalSize(columns: 20, rows: 10))).snapshot
        XCTAssertEqual(hundred.panes.count, 100)
        do { _ = try await capacity.execute(.splitPane(id: target, axis: .x, availableSize: TerminalSize(columns: 40, rows: 5))); XCTFail("Accepted101 panes") } catch {}
        unchanged = await capacity.snapshot()
        XCTAssertEqual(unchanged, hundred)
        let cells = try WorkspaceStore()
        let one = try await cells.execute(.createWindow(name: "Cells")).snapshot
        let pane = try XCTUnwrap(one.panes.keys.first)
        for (axis, columns, rows) in [(SplitAxis.x, 39, 5), (.x, 40, 4), (.y, 20, 9), (.y, 19, 10)] {
            do { _ = try await cells.execute(.splitPane(id: pane, axis: axis, availableSize: TerminalSize(columns: columns, rows: rows))); XCTFail("Accepted undersized split") } catch {}
            unchanged = await cells.snapshot()
            XCTAssertEqual(unchanged, one)
        }
    }

    @MainActor
    func testFailedNewSessionKeepsTreeAndOriginalPane() async throws {
        _ = NSApplication.shared
        let name = "trellis.tests.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        preferences.set("/does-not-exist-trellis", forKey: "terminal.shell")
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences)
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createWindow(startSession: false)
        let original = try XCTUnwrap(model.presentation.activePane)
        await model.splitPane(original.id, axis: .x)
        await model.waitForUpdates()
        XCTAssertEqual(model.snapshot.panes.count, 2)
        XCTAssertEqual(model.snapshot.panes[original.id], original)
        let failed = try XCTUnwrap(model.presentation.activePane)
        XCTAssertEqual(model.snapshot.sessions[failed.sessionID]?.state, .failed)
        XCTAssertEqual(model.snapshot.sessions[original.sessionID]?.state, .stopped)
        try model.snapshot.validate()
    }

    @MainActor
    func testCommittedSplitSurvivesConcurrentOriginalPaneClose() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createWindow(startSession: false)
        let original = try XCTUnwrap(model.presentation.activePane?.id)
        let split = Task { await model.splitPane(original, axis: .x, startSession: false) }
        let close = Task { await model.closePane(original) }
        await split.value
        await close.value
        XCTAssertEqual(model.snapshot.panes.count, 1)
        XCTAssertNil(model.snapshot.panes[original])
        XCTAssertEqual(Set(model.terminals.keys), Set(model.snapshot.panes.keys))
        XCTAssertNotNil(model.activeTerminal)
        try model.snapshot.validate()
    }

    @MainActor
    func testConcurrentSplitAndTabCloseReleaseAllNativeTerminals() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createWindow(startSession: false)
        let original = try XCTUnwrap(model.presentation.activePane?.id)
        let tab = try XCTUnwrap(model.presentation.selectedTab?.id)
        let split = Task { await model.splitPane(original, axis: .x, startSession: false) }
        let close = Task { await model.closeTab(tab) }
        await split.value
        await close.value
        XCTAssertTrue(model.snapshot.panes.isEmpty)
        XCTAssertTrue(model.terminals.isEmpty)
        try model.snapshot.validate()
    }

    @MainActor
    func testHostedNestedPaneSurvivesParentCollapse() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createWindow(startSession: false)
        let left = try XCTUnwrap(model.presentation.activePane?.id)
        await model.splitPane(left, axis: .x, startSession: false)
        let top = try XCTUnwrap(model.presentation.activePane?.id)
        await model.splitPane(top, axis: .y, startSession: false)
        let bottom = try XCTUnwrap(model.presentation.activePane?.id)
        let topTerminal = try XCTUnwrap(model.terminals[top])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceRootView(model: model))
        defer { window.close() }
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(topTerminal.view.window === window)
        await model.closePane(bottom)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(topTerminal.view.window === window, "Collapsed parent must retain its surviving terminal in the hosted tree")
        XCTAssertFalse(topTerminal.view.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(model.terminals.count, 2)
    }

    @MainActor
    func testCanvasTooSmallRejectsBeforeMutation() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createWindow(startSession: false)
        let before = model.snapshot
        await model.splitPane(
            try XCTUnwrap(model.presentation.activePane?.id), axis: .y,
            availableCanvas: CanvasDimensions(width: 200, height: 100), startSession: false)
        XCTAssertEqual(model.snapshot, before)
        XCTAssertEqual(model.terminals.count, 1)
        XCTAssertNotNil(model.errorMessage)
    }
}
