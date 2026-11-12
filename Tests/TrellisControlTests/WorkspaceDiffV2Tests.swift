import XCTest
import TrellisCore
@testable import TrellisControl

/// `WorkspaceDiffV2` over real store transitions (events.md): ordered, redacted, and stable for many resources at once.
final class WorkspaceDiffV2Tests: XCTestCase {
    /// Many resources changing in one transition still arrive in UUID-string order within each event type.
    func testWorkspaceDiffOrdersManyChangedResourcesByUUIDString() async throws {
        let store = try WorkspaceStore()
        let empty = await store.snapshot()
        var built = try await store.execute(.createSpace(name: "A")).snapshot
        let space = try XCTUnwrap(built.spaces.first?.id)
        for _ in 0..<12 { built = try await store.execute(.createTab(spaceID: space)).snapshot }
        func isOrdered(_ events: [EventDraftV2], _ type: String, count: Int, line: UInt = #line) {
            let ids = events.filter { $0.type == type }.map(\.resourceID)
            XCTAssertEqual(ids.count, count, type, line: line)
            XCTAssertEqual(ids, ids.sorted(), type, line: line)
        }
        let created = WorkspaceDiffV2.diff(empty, built)
        isOrdered(created, "tab.created", count: 13)
        isOrdered(created, "pane.created", count: 13)
        XCTAssertEqual(created.first?.type, "space.created")
        let removed = WorkspaceDiffV2.diff(built, empty)
        XCTAssertEqual(removed.first?.type, "space.deleted", "Containers go first, so no child outlives its container")
        isOrdered(removed, "tab.deleted", count: 13)
        isOrdered(removed, "pane.deleted", count: 13)
        // Changed tabs and their selections keep that order too.
        var split = built
        for tab in built.tabs.values {
            split = try await store.execute(.splitPane(id: tab.activePaneID, axis: .x, availableSize: try TerminalSize(columns: 120, rows: 40))).snapshot
        }
        let changed = WorkspaceDiffV2.diff(built, split)
        isOrdered(changed, "tab.layoutChanged", count: 13)
        isOrdered(changed, "pane.created", count: 13)
        let selections = changed.filter { $0.type == "selection.pane" }.compactMap { event -> String? in
            if case .string(let tab)? = event.data["tabId"] { tab } else { nil }
        }
        XCTAssertEqual(selections.count, 13)
        XCTAssertEqual(selections, selections.sorted())
        built = split
        // An unrelated change reports only itself, however many resources stay as they were.
        let first = try XCTUnwrap(built.tabs.keys.first { $0 != built.spaces.first?.activeTabID })
        let selected = try await store.execute(.selectTab(id: first)).snapshot
        XCTAssertEqual(WorkspaceDiffV2.diff(built, selected).map(\.type).filter { $0 != "space.updated" }, ["selection.tab"])
    }

    func testWorkspaceDiffEventsAreOrderedAndRedacted() async throws {
        let store = try WorkspaceStore()
        var events: [EventDraftV2] = []
        let empty = await store.snapshot()
        let created = try await store.execute(.createSpace(name: "A")).snapshot
        events += WorkspaceDiffV2.diff(empty, created)
        XCTAssertEqual(events.map(\.type), ["space.created", "tab.created", "pane.created", "selection.space"])
        let pane = try XCTUnwrap(created.panes.keys.first)
        let split = try await store.execute(.splitPane(id: pane, axis: .x, availableSize: try TerminalSize(columns: 120, rows: 40))).snapshot
        let splitEvents = WorkspaceDiffV2.diff(created, split)
        events += splitEvents
        let types = splitEvents.map(\.type)
        for (earlier, later) in [("tab.layoutChanged", "pane.created"), ("pane.created", "selection.pane")] {
            let a = try XCTUnwrap(types.firstIndex(of: earlier), types.description), b = try XCTUnwrap(types.firstIndex(of: later), types.description)
            XCTAssertLessThan(a, b, types.description)
        }
        XCTAssertTrue(events.allSatisfy { $0.spaceID != nil })
        XCTAssertTrue(events.allSatisfy { !$0.data.keys.contains("executable") && !$0.data.keys.contains("directory") })
        XCTAssertEqual(WorkspaceDiffV2.diff(WorkspaceSnapshot(), WorkspaceSnapshot()), [])
        XCTAssertEqual(WorkspaceDiffV2.diff(split, split), [])
    }
}
