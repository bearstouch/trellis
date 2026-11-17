import XCTest
import TrellisControl
import TrellisCore
@testable import TrellisUI

/// Review-driven checks for API2-09: knowing a pane's ID (`TRELLIS_PANE_ID`) gives a grant nothing its scope and capabilities don't.
final class PaneSelfDirectionReviewTests: XCTestCase {
    @MainActor
    func testAPaneIDIsNoCredentialForResizeAndFocus() async throws {
        let v = try HarnessV2()
        defer { v.cleanUp() }
        try await v.grant("full")
        let own = try await v.ok("space.create", ["name": "Mine"])
        let mine = try XCTUnwrap(object(own, "space")["id"] as? String)
        let other = try await v.ok("space.create", ["name": "Other"])
        let tabID = try XCTUnwrap(object(other, "tab")["id"] as? String)
        let a = try XCTUnwrap((other["panes"] as? [[String: Any]])?.first?["id"] as? String)
        let split = try await v.ok("pane.split", ["id": a, "axis": "x"])
        let b = try XCTUnwrap(object(split, "pane")["id"] as? String)
        _ = try await v.ok("pane.focus", ["id": a])
        try await v.grant("scoped", Set(CapabilityV2.allCases), scope: .spaces([try XCTUnwrap(UUID(uuidString: mine))]))
        try await v.grant("reader", [.workspaceRead])
        let calls: [(String, [String: Any])] = [
            ("pane.resize", ["id": a, "axis": "x", "share": 0.8]), ("pane.resize", ["id": b, "direction": "left", "by": 0.2]), ("pane.focus", ["id": a, "direction": "right"])
        ]
        for (method, params) in calls {
            let hidden = try await v.code(method, params, as: "scoped")
            XCTAssertEqual(hidden, "NOT_FOUND", "\(method) \(params): a pane outside the grant's spaces looks missing")
            let denied = try await v.code(method, params, as: "reader")
            XCTAssertEqual(denied, "PERMISSION_DENIED", "\(method) \(params): moving a divider or focus needs workspace.write")
        }
        let after = try await v.ok("tab.get", ["id": tabID])
        XCTAssertEqual(try XCTUnwrap(object(object(after, "tab"), "layout")["ratio"] as? Double), 0.5, accuracy: 0.0001, "Refused calls leave the divider where it was")
        XCTAssertEqual(v.model.snapshot.tabs[try XCTUnwrap(UUID(uuidString: tabID))]?.activePaneID.uuidString.lowercased(), a, "and the focus")
    }
}
