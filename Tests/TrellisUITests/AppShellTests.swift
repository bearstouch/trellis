import AppKit
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

final class AppShellTests: XCTestCase {
    func testS004_UT01_emptyStateProjection() {
        let projection = WorkspacePresentation(snapshot: WorkspaceSnapshot())
        XCTAssertTrue(projection.isEmpty)
        XCTAssertTrue(projection.visibleTabs.isEmpty)
        XCTAssertNil(projection.activePane)
    }

    func testS004_UT02_selectedWindowOwnsTabBar() async throws {
        let store = try WorkspaceStore()
        let first = try await store.execute(.createWindow(name: "Project"))
        let second = try await store.execute(.createWindow(name: "Operations"))
        let id = try XCTUnwrap(first.createdWindowID)
        let selected = try await store.execute(.selectWindow(id: id))
        let projection = WorkspacePresentation(snapshot: selected.snapshot)
        XCTAssertEqual(projection.selectedWindow?.name, "Project")
        XCTAssertEqual(projection.visibleTabs.map(\.id), first.snapshot.windows[0].tabIDs)
        XCTAssertFalse(projection.visibleTabs.contains { $0.windowID == second.createdWindowID })
    }

    func testS004_UT03_constrainOffscreenGeometry() {
        let display = WindowRectangle(x: 0, y: 0, width: 1440, height: 900)
        let rect = WindowRectangle(x: -3000, y: 4000, width: 1800, height: 1200).constrained(to: [display])
        XCTAssertGreaterThanOrEqual(rect.x, display.x)
        XCTAssertGreaterThanOrEqual(rect.y, display.y)
        XCTAssertLessThanOrEqual(rect.x + rect.width, display.width)
        XCTAssertLessThanOrEqual(rect.y + rect.height, display.height)
        let invalid = WindowRectangle(x: .nan, y: .infinity, width: -1, height: 0).constrained(to: [display])
        XCTAssertTrue([invalid.x, invalid.y, invalid.width, invalid.height].allSatisfy(\.isFinite))
    }

    func testS004_UT04_smallCanvasRetainsLayout() {
        let a = UUID(), b = UUID(), c = UUID()
        let tree = PaneLayout.split(id: UUID(), axis: .x, ratio: 0.25, children: [
            .pane(a), .split(id: UUID(), axis: .y, ratio: 0.5, children: [.pane(b), .pane(c)])
        ])
        let original = tree
        let minimum = CanvasDimensions.minimum(for: tree)
        let small = minimum.fitting(width: 100, height: 50)
        XCTAssertGreaterThanOrEqual((small.width - 1) * 0.25, 160)
        XCTAssertGreaterThanOrEqual(small.height, 181)
        XCTAssertEqual(tree, original)
        XCTAssertEqual(tree.paneIDs, [a, b, c])
    }

    @MainActor
    func testCreateStoppedWorkspaceDoesNotLaunchProcess() async throws {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis.tests.\(UUID())"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences)
        model.confirmForceSessions = { _ in true } // Explicit cleanup authorization for owned test processes.
        await model.createWindow(name: "Project", startSession: false)
        XCTAssertEqual(model.snapshot.windows.count, 1)
        XCTAssertEqual(model.terminals.count, 1)
        XCTAssertEqual(model.activeTerminal?.sessionState, .stopped)
        XCTAssertTrue(model.runningTerminals.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testFastFixtureExitUpdatesSharedWorkspaceInOrder() async throws {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis.tests.\(UUID())"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences)
        model.confirmForceSessions = { _ in true } // Explicit cleanup authorization for owned test processes.
        await model.createWindow(name: "Fixture", fixture: true)
        let deadline = Date().addingTimeInterval(10)
        while model.snapshot.sessions.values.first?.state != .exited, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await model.waitForUpdates()
        let session = try XCTUnwrap(model.snapshot.sessions.values.first)
        XCTAssertEqual(session.state, .exited)
        XCTAssertEqual(session.exitCode, 7)
        XCTAssertNil(session.processID)
        XCTAssertNil(model.errorMessage)
        try model.snapshot.validate()
    }

    @MainActor
    func testInvalidSettingsAreNotPersisted() async throws {
        let name = "trellis.tests.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences)
        model.confirmForceSessions = { _ in true } // Explicit cleanup authorization for owned test processes.
        let original = model.defaultShell
        let saved = await model.saveLaunchSettings(shell: "/does-not-exist-trellis", directory: "/tmp")
        XCTAssertFalse(saved)
        XCTAssertEqual(model.defaultShell, original)
        XCTAssertNil(preferences.object(forKey: "terminal.shell"))
    }
    @MainActor
    func testSelectingAnotherWorkspaceReplacesTerminalSurface() {
        _ = NSApplication.shared
        let first = NativeTerminal()
        let second = NativeTerminal()
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        container.display(first.view)
        XCTAssertTrue(first.view.superview === container)
        container.display(second.view)
        XCTAssertNil(first.view.superview)
        XCTAssertTrue(second.view.superview === container)
        XCTAssertEqual(container.subviews.count, 1)
        XCTAssertEqual(second.view.frame, container.bounds)
        container.display(first.view)
        XCTAssertTrue(first.view.superview === container)
        XCTAssertNil(second.view.superview)
    }

    @MainActor
    func testStoppingDuringLaunchCompletesSharedState() async throws {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis.tests.\(UUID())"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences)
        model.confirmForceSessions = { _ in true } // Explicit cleanup authorization for owned test processes.
        await model.createWindow(startSession: false)
        let pane = try XCTUnwrap(model.presentation.activePane)
        let terminal = try XCTUnwrap(model.activeTerminal)
        let launch = Task { await model.start(paneID: pane.id) }
        while terminal.sessionState == .stopped { await Task.yield() }
        model.stopAll()
        await launch.value
        let deadline = Date().addingTimeInterval(5)
        while terminal.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        await model.waitForUpdates()
        XCTAssertFalse(terminal.isRunning)
        let state = try XCTUnwrap(model.snapshot.sessions[pane.sessionID]?.state)
        XCTAssertTrue(state == .failed || state == .exited)
        XCTAssertNil(model.errorMessage)
        try model.snapshot.validate()
    }

    @MainActor
    func testCloseAllReturnsToEmptyStateAndAllowsNewWorkspace() async throws {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis.tests.\(UUID())"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences)
        model.confirmForceSessions = { _ in true } // Explicit cleanup authorization for owned test processes.
        await model.createWindow(startSession: false)
        await model.closeAllWorkspaces()
        XCTAssertTrue(model.presentation.isEmpty)
        XCTAssertTrue(model.terminals.isEmpty)
        XCTAssertTrue(model.snapshot.sessions.isEmpty)
        await model.createWindow(name: "Reopened", startSession: false)
        XCTAssertEqual(model.presentation.selectedWindow?.name, "Reopened")
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testShutdownFreezesCreationAndLaunches() async throws {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis.tests.\(UUID())"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences)
        model.confirmForceSessions = { _ in true } // Explicit cleanup authorization for owned test processes.
        await model.createWindow(startSession: false)
        let pane = try XCTUnwrap(model.presentation.activePane)
        model.stopAll()
        await model.createWindow(name: "Must not appear", fixture: true)
        await model.start(paneID: pane.id, fixture: true)
        await model.shutdown()
        XCTAssertEqual(model.snapshot.windows.count, 1)
        XCTAssertEqual(model.activeTerminal?.sessionState, .stopped)
        XCTAssertTrue(model.runningTerminals.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testCloseAllWaitsForPendingCreationAndFixtureLaunch() async throws {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis.tests.\(UUID())"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences)
        model.confirmForceSessions = { _ in true } // Explicit cleanup authorization for owned test processes.
        var creationEntered = false
        let creation = Task {
            creationEntered = true
            await model.createWindow(fixture: true)
        }
        while !creationEntered { await Task.yield() }
        await model.closeAllWorkspaces()
        await creation.value
        XCTAssertTrue(model.presentation.isEmpty)
        XCTAssertTrue(model.terminals.isEmpty)
        XCTAssertTrue(model.snapshot.sessions.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

}
