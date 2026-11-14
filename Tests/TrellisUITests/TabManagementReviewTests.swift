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
}
