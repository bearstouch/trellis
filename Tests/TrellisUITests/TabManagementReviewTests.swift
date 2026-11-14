import AppKit
import Combine
import XCTest
import TrellisCore
@testable import TrellisUI

/// Tab switching publishes only what changes (performance review).
final class TabManagementReviewTests: XCTestCase {
    @MainActor
    func testSwitchingTabsDoesNotClearAHiddenEditorOrReview() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        let created = await model.createSpace(startSession: false)
        let spaceID = try XCTUnwrap(created)
        let first = try XCTUnwrap(model.presentation.selectedTab?.id)
        let added = await model.createTab(spaceID: spaceID, startSessions: false)
        let second = try XCTUnwrap(added)
        var visibility = 0
        let watchers = [model.$reviewShownSpaces.dropFirst().sink { _ in visibility += 1 }, model.$shownEditors.dropFirst().sink { _ in visibility += 1 }]
        defer { watchers.forEach { $0.cancel() } }

        for id in [first, second, first, second] {
            await model.selectTab(id)
            await Task.yield()
        }
        XCTAssertEqual(model.presentation.selectedTab?.id, second)
        XCTAssertEqual(visibility, 0, "With no editor or review shown, switching tabs doesn't clear what is already clear")
    }

    @MainActor
    func testSwitchingTabsAndPanesIsOneWindowUpdateEach() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        let created = await model.createSpace(startSession: false)
        let spaceID = try XCTUnwrap(created)
        let first = try XCTUnwrap(model.presentation.selectedTab?.id)
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        let split = await model.splitPane(pane, axis: .x, startSession: false)
        let other = try XCTUnwrap(split)
        let added = await model.createTab(spaceID: spaceID, startSessions: false)
        let second = try XCTUnwrap(added)
        var paste = 0, turns = 0, inTurn = false
        let watchers = [
            model.$pendingPaste.dropFirst().sink { _ in paste += 1 },
            // Changes published in the same turn reach SwiftUI as one update; count the turns.
            model.objectWillChange.sink { _ in
                guard !inTurn else { return }
                inTurn = true; turns += 1
                DispatchQueue.main.async { inTurn = false }
            }
        ]
        defer { watchers.forEach { $0.cancel() } }

        for id in [second, first, second, first] {
            await model.selectTab(id)
            await Task.yield()
        }
        for id in [other, pane, other, pane] {
            _ = await model.selectPane(id)
            await Task.yield()
        }
        XCTAssertEqual(model.presentation.activePane?.id, pane)
        XCTAssertEqual(paste, 0, "Cancelling a paste that isn't waiting doesn't publish")
        XCTAssertEqual(turns, 8, "One window update per tab switch and per pane focus change")
    }
}
