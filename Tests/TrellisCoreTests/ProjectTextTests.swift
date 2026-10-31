import XCTest

@testable import TrellisCore

/// Rules shared by tasks, the scratchpad and project launches: trust, folders and the layout planner's options for
/// launching into live windows.
final class ProjectTextTests: XCTestCase {
    func testTrustMatchesOnlyTheSameFolderAndBytes() {
        let data = Data("{\"version\":1}".utf8)
        var changed = data
        changed[changed.startIndex] = UInt8(ascii: "[")
        var list = ProjectTrustList()
        let digest = ProjectTrustList.digest(data)
        XCTAssertEqual(digest.count, 64)
        XCTAssertFalse(list.isTrusted(root: "/p", digest: digest))
        list.trust(root: "/p", digest: digest)
        XCTAssertTrue(list.isTrusted(root: "/p", digest: digest))
        XCTAssertFalse(list.isTrusted(root: "/p", digest: ProjectTrustList.digest(changed)), "One changed byte needs a new review")
        XCTAssertTrue(list.trustedOtherVersion(root: "/p", digest: ProjectTrustList.digest(changed)))
        XCTAssertFalse(list.isTrusted(root: "/q", digest: digest), "A moved or copied project needs a new review")
        list.trust(root: "/p", digest: ProjectTrustList.digest(changed))
        XCTAssertFalse(list.isTrusted(root: "/p", digest: digest), "One trusted version per folder")
        XCTAssertEqual(list.trusted.count, 1)
        for index in 0...ProjectTrustList.maximumEntries { list.trust(root: "/r\(index)", digest: digest) }
        XCTAssertEqual(list.trusted.count, ProjectTrustList.maximumEntries)
    }

    func testRelativeDirectoriesStayInsideTheProject() {
        XCTAssertEqual(ProjectText.relativeDirectory("./src//app/"), "src/app")
        XCTAssertEqual(ProjectText.relativeDirectory("."), "")
        XCTAssertNil(ProjectText.relativeDirectory("a/../b"))
        XCTAssertNil(ProjectText.relativeDirectory("/abs"))
        XCTAssertNil(ProjectText.relativeDirectory("~"))
        XCTAssertNil(ProjectText.relativeDirectory("a`b`"))
        XCTAssertNil(ProjectText.relativeDirectory("$HOME"))
        XCTAssertEqual(ProjectText.relativeDirectory("a/b..c"), "a/b..c")
    }

    func testOmittedPanesKeepTheirPlaceAroundDeclaredChanges() throws {
        let (a, b, c, d, n) = (UUID(), UUID(), UUID(), UUID(), UUID())
        let (outer, inner, declared) = (UUID(), UUID(), UUID())
        // Live: [a | [b / c]]; the file omits b and splits c into c and a new pane n.
        let live = PaneLayout.split(id: outer, axis: .x, ratio: 0.5, children: [.pane(a), .split(id: inner, axis: .y, ratio: 0.4, children: [.pane(b), .pane(c)])])
        let file = PaneLayout.split(id: outer, axis: .x, ratio: 0.3, children: [.pane(a), .split(id: declared, axis: .x, ratio: 0.5, children: [.pane(c), .pane(n)])])
        XCTAssertEqual(
            LayoutPlanner.merging(file, into: live),
            .split(
                id: outer, axis: .x, ratio: 0.3,
                children: [.pane(a), .split(id: inner, axis: .y, ratio: 0.4, children: [.pane(b), .split(id: declared, axis: .x, ratio: 0.5, children: [.pane(c), .pane(n)])])]))
        // Panes the live splits keep apart can't be regrouped around an omitted one.
        let deeper = PaneLayout.split(id: outer, axis: .x, ratio: 0.5, children: [.split(id: inner, axis: .y, ratio: 0.5, children: [.pane(a), .pane(b)]), .pane(c)])
        let regrouped = PaneLayout.split(
            id: declared, axis: .x, ratio: 0.5, children: [.split(id: UUID(), axis: .y, ratio: 0.5, children: [.pane(a), .pane(c)]), .pane(d)])
        XCTAssertNil(LayoutPlanner.merging(regrouped, into: deeper))
        // A reused split ID can't double up with the split kept around the omitted pane.
        XCTAssertNil(LayoutPlanner.merging(.split(id: inner, axis: .x, ratio: 0.5, children: [.pane(c), .pane(n)]), into: live))
        // A declared split that wraps a whole live split in a new one keeps the omitted pane beside it.
        let kept = PaneLayout.split(id: inner, axis: .y, ratio: 0.4, children: [.pane(a), .pane(c)])
        let wrapped = PaneLayout.split(id: declared, axis: .x, ratio: 0.5, children: [kept, .pane(n)])
        XCTAssertEqual(
            LayoutPlanner.merging(wrapped, into: .split(id: outer, axis: .x, ratio: 0.5, children: [.pane(b), kept])),
            .split(id: outer, axis: .x, ratio: 0.5, children: [.pane(b), wrapped]))
    }

    func testPlannerAppliesDeclaredTabColorsOnly() throws {
        let document = LayoutDocument(windows: [LayoutWindow(key: "w", name: "W", tabs: [LayoutTab(key: "t", title: "T", color: .red, root: .pane(key: "p", title: nil, launch: .shell(directory: nil)))])])
        let created = LayoutPlanner.plan(document, bindings: [:], snapshot: WorkspaceSnapshot(), home: "/h", hostExists: { _ in false }, directoryExists: { _ in true })
        let target = try XCTUnwrap(created.target)
        XCTAssertEqual(target.tabs.values.first?.color, .red)
        var recolored = document
        recolored.windows[0].tabs[0].color = .blue
        let updated = LayoutPlanner.plan(recolored, bindings: created.bindings, snapshot: target, home: "/h", hostExists: { _ in false }, directoryExists: { _ in true })
        XCTAssertEqual(updated.target?.tabs.values.first?.color, .blue)
        XCTAssertTrue(updated.updates.contains { $0.kind == .tab })
        recolored.windows[0].tabs[0].color = nil
        let kept = LayoutPlanner.plan(recolored, bindings: created.bindings, snapshot: target, home: "/h", hostExists: { _ in false }, directoryExists: { _ in true })
        XCTAssertEqual(kept.target?.tabs.values.first?.color, .red, "An undeclared color leaves the label alone")
        XCTAssertTrue(kept.updates.isEmpty)
    }

    func testLiveLaunchChangesConflictUnlessKept() throws {
        var snapshot = WorkspaceSnapshot()
        let document = LayoutDocument(windows: [LayoutWindow(key: "w", name: "W", tabs: [LayoutTab(key: "t", title: "T", root: .pane(key: "p", title: nil, launch: .shell(directory: "/a")))])])
        let created = LayoutPlanner.plan(document, bindings: [:], snapshot: snapshot, home: "/h", hostExists: { _ in false }, directoryExists: { _ in true })
        snapshot = try XCTUnwrap(created.target)
        let sessionID = try XCTUnwrap(snapshot.sessions.keys.first)
        snapshot.sessions[sessionID]?.state = .running
        snapshot.sessions[sessionID]?.processID = 42
        var moved = document
        moved.windows[0].tabs[0].root = .pane(key: "p", title: nil, launch: .shell(directory: "/b"))
        let strict = LayoutPlanner.plan(moved, bindings: created.bindings, snapshot: snapshot, home: "/h", hostExists: { _ in false }, directoryExists: { _ in true })
        XCTAssertFalse(strict.conflicts.isEmpty)
        let kept = LayoutPlanner.plan(
            moved, bindings: created.bindings, snapshot: snapshot, home: "/h", hostExists: { _ in false }, directoryExists: { _ in true }, keepLiveLaunches: true)
        XCTAssertTrue(kept.canApply)
        XCTAssertEqual(kept.target?.sessions[sessionID]?.launch, .shell(directory: "/a"), "A running pane keeps its folder")
    }
}
