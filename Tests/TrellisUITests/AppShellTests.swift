import AppKit
import XCTest
import TrellisCore
import TrellisTerminal
import SwiftTerm
@testable import TrellisUI

final class AppShellTests: XCTestCase {
    @MainActor
    func testTerminalGridIsCenteredAcrossResizeAndFontChanges() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        let terminal = try XCTUnwrap(native.view as? TerminalView)
        let container = TerminalContainerView()
        container.display(terminal)
        for fontSize in [13.0, 19.0] {
            var settings = AppearanceSettings()
            settings.fontSize = fontSize
            native.applyAppearance(settings)
            for height in [401.0, 417.0, 503.0] {
                container.frame = NSRect(x: 0, y: 0, width: 800, height: height)
                terminal.frame = container.bounds
                let rows = terminal.getTerminal().rows
                container.layout()
                let above = container.bounds.maxY - terminal.frame.maxY, below = terminal.frame.minY - container.bounds.minY
                XCTAssertGreaterThanOrEqual(below, 0)
                XCTAssertEqual(above, below, accuracy: 1.01, "the remainder of a row is split evenly")
                XCTAssertEqual(terminal.frame.height, terminal.getOptimalFrameSize().height, accuracy: 0.002)
                XCTAssertEqual(terminal.getTerminal().rows, rows)
                container.layout()
                XCTAssertEqual(terminal.getTerminal().rows, rows)
            }
        }
    }

    func testEmptyStateProjection() {
        let projection = WorkspacePresentation(snapshot: WorkspaceSnapshot())
        XCTAssertTrue(projection.isEmpty)
        XCTAssertTrue(projection.visibleTabs.isEmpty)
        XCTAssertNil(projection.activePane)
    }

    func testSelectedSpaceOwnsTabBar() async throws {
        let store = try WorkspaceStore()
        let first = try await store.execute(.createSpace(name: "Project"))
        let second = try await store.execute(.createSpace(name: "Operations"))
        let id = try XCTUnwrap(first.createdSpaceID)
        let selected = try await store.execute(.selectSpace(id: id))
        let projection = WorkspacePresentation(snapshot: selected.snapshot)
        XCTAssertEqual(projection.selectedSpace?.name, "Project")
        XCTAssertEqual(projection.visibleTabs.map(\.id), first.snapshot.spaces[0].tabIDs)
        XCTAssertFalse(projection.visibleTabs.contains { $0.spaceID == second.createdSpaceID })
    }

    func testConstrainOffscreenGeometry() {
        let display = WindowRectangle(x: 0, y: 0, width: 1440, height: 900)
        let rect = WindowRectangle(x: -3000, y: 4000, width: 1800, height: 1200).constrained(to: [display])
        XCTAssertGreaterThanOrEqual(rect.x, display.x)
        XCTAssertGreaterThanOrEqual(rect.y, display.y)
        XCTAssertLessThanOrEqual(rect.x + rect.width, display.width)
        XCTAssertLessThanOrEqual(rect.y + rect.height, display.height)
        let invalid = WindowRectangle(x: .nan, y: .infinity, width: -1, height: 0).constrained(to: [display])
        XCTAssertTrue([invalid.x, invalid.y, invalid.width, invalid.height].allSatisfy(\.isFinite))
    }

    func testSmallCanvasRetainsLayout() {
        let a = UUID(), b = UUID(), c = UUID()
        let tree = PaneLayout.split(
            id: UUID(), axis: .x, ratio: 0.25,
            children: [
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
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createSpace(name: "Project", startSession: false)
        XCTAssertEqual(model.snapshot.spaces.count, 1)
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
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createSpace(name: "Fixture", fixture: true)
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
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
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
        XCTAssertEqual(container.subviews.filter { $0 !== container.gapAbove && $0 !== container.gapBelow }.count, 1)
        XCTAssertEqual(second.view.frame, container.bounds)
        container.display(first.view)
        XCTAssertTrue(first.view.superview === container)
        XCTAssertNil(second.view.superview)
    }

    /// FR-TH10: the strips above and below the rows take the terminal's background, opacity included,
    /// and follows palette changes, so a translucent pane shows no band at the top.
    @MainActor
    func testStripsAroundTerminalRowsFollowTheTerminalBackground() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        var settings = AppearanceSettings()
        settings.backgroundOpacity = 0.5
        native.applyAppearance(settings)
        native.applyPalette(.builtIn)
        let grid = try XCTUnwrap(native.view as? TerminalView)
        let rowHeight = grid.getOptimalFrameSize().height / CGFloat(grid.getTerminal().rows)
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 600, height: (rowHeight * 10).rounded(.down) + rowHeight / 2))
        container.display(native.view)
        container.layout()
        let (above, below) = (container.gapAbove, container.gapBelow)
        XCTAssertFalse(above.isHidden)
        XCTAssertFalse(below.isHidden)
        XCTAssertEqual(below.frame.minY, container.bounds.minY, accuracy: 0.01)
        XCTAssertEqual(below.frame.maxY, native.view.frame.minY, accuracy: 0.01)
        XCTAssertEqual(above.frame.minY, native.view.frame.maxY, accuracy: 0.01)
        XCTAssertEqual(above.frame.maxY, container.bounds.maxY, accuracy: 0.01)
        XCTAssertEqual(above.frame.height, below.frame.height, accuracy: 1.01)
        func color(_ gap: NSView) throws -> NSColor { try XCTUnwrap(gap.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }) }
        for gap in [above, below] { XCTAssertEqual(try color(gap).alphaComponent, 0.5, accuracy: 0.01) }
        native.applyPalette(.builtInLight)
        for gap in [above, below] {
            XCTAssertEqual(try color(gap).redComponent, 1, accuracy: 0.01, "follows a theme change without a relayout")
            XCTAssertEqual(try color(gap).alphaComponent, 0.5, accuracy: 0.01)
        }
    }

    @MainActor
    func testStoppingDuringLaunchCompletesSharedState() async throws {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis.tests.\(UUID())"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences)
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createSpace(startSession: false)
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
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createSpace(startSession: false)
        await model.closeAllWorkspaces()
        XCTAssertTrue(model.presentation.isEmpty)
        XCTAssertTrue(model.terminals.isEmpty)
        XCTAssertTrue(model.snapshot.sessions.isEmpty)
        await model.createSpace(name: "Reopened", startSession: false)
        XCTAssertEqual(model.presentation.selectedSpace?.name, "Reopened")
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testClosingTheWindowEndsSessionsButKeepsTheSavedLayout() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-space-close-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis.tests.\(UUID())"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: directory))
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        _ = await model.loadWorkspace()
        await model.createSpace(name: "Kept")
        await model.createSpace(name: "Also kept", startSession: false)
        await model.waitForUpdates()
        model.stopAll()
        let closed = await model.endSessionsForWindowClose()
        XCTAssertTrue(closed)
        XCTAssertTrue(model.runningTerminals.isEmpty)
        XCTAssertEqual(model.snapshot.spaces.map(\.name), ["Kept", "Also kept"])
        XCTAssertNil(model.errorMessage)
        // Reopening the window (Dock) leaves the stopped panes restartable.
        let kept = try XCTUnwrap(model.snapshot.spaces.first)
        let pane = try XCTUnwrap(model.snapshot.tabs[kept.activeTabID].flatMap { model.snapshot.panes[$0.activePaneID] })
        let ended = try XCTUnwrap(model.terminals[pane.id])
        XCTAssertTrue(ended.sessionState == .exited || ended.sessionState == .failed)
        await model.restartPane(pane.id)
        await model.waitForUpdates()
        XCTAssertNotEqual(model.snapshot.panes[pane.id]?.sessionID, pane.sessionID)
        XCTAssertEqual(model.runningTerminals.count, 1)
        // Quit after the window was closed saves the layout, not an empty workspace.
        model.stopAll()
        let quit = await model.shutdown()
        XCTAssertTrue(quit)
        let saved = await model.flushWorkspaceSave()
        XCTAssertTrue(saved)
        let restored = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: directory))
        _ = await restored.loadWorkspace()
        XCTAssertEqual(restored.snapshot.spaces.map(\.name), ["Kept", "Also kept"])
        XCTAssertTrue(restored.runningTerminals.isEmpty)
    }

    @MainActor
    func testShutdownFreezesCreationAndLaunches() async throws {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis.tests.\(UUID())"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences)
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createSpace(startSession: false)
        let pane = try XCTUnwrap(model.presentation.activePane)
        model.stopAll()
        await model.createSpace(name: "Must not appear", fixture: true)
        await model.start(paneID: pane.id, fixture: true)
        await model.shutdown()
        XCTAssertEqual(model.snapshot.spaces.count, 1)
        XCTAssertEqual(model.activeTerminal?.sessionState, .stopped)
        XCTAssertTrue(model.runningTerminals.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testCloseAllWaitsForPendingCreationAndFixtureLaunch() async throws {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis.tests.\(UUID())"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences)
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        var creationEntered = false
        let creation = Task {
            creationEntered = true
            await model.createSpace(fixture: true)
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
