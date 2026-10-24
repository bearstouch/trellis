import XCTest
@testable import TrellisCore

final class ProjectFileTests: XCTestCase {
    private func files(_ roots: String...) -> (String) -> Bool {
        let paths = Set(roots.map { ProjectFile.url(projectRoot: $0).path })
        return { paths.contains($0) }
    }

    func testLocatorFindsNearestProjectWithinHome() {
        let exists = files("/Users/me/code/app", "/Users/me/code/app/packages/web", "/Users/me", "/Volumes/Disk/repo")
        XCTAssertEqual(ProjectFileLocator.projectRoot(containing: "/Users/me/code/app/Sources/x", home: "/Users/me", fileExists: exists), "/Users/me/code/app")
        XCTAssertEqual(ProjectFileLocator.projectRoot(containing: "/Users/me/code/app/packages/web/src", home: "/Users/me", fileExists: exists), "/Users/me/code/app/packages/web")
        XCTAssertEqual(ProjectFileLocator.projectRoot(containing: "/Users/me/code/app/", home: "/Users/me/", fileExists: exists), "/Users/me/code/app")
        XCTAssertNil(ProjectFileLocator.projectRoot(containing: "/Users/me/other", home: "/Users/me", fileExists: exists), "Home itself is never a project")
        XCTAssertNil(ProjectFileLocator.projectRoot(containing: "/Users/me", home: "/Users/me", fileExists: exists))
        XCTAssertEqual(ProjectFileLocator.projectRoot(containing: "/Volumes/Disk/repo/a/b", home: "/Users/me", fileExists: exists), "/Volumes/Disk/repo")
        XCTAssertNil(ProjectFileLocator.projectRoot(containing: "/", home: "/Users/me", fileExists: { _ in true }), "/ is never a project")
        XCTAssertNil(ProjectFileLocator.projectRoot(containing: "relative/path", home: "/Users/me", fileExists: { _ in true }))
    }

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
        list.setIgnored("/p", true)
        XCTAssertTrue(list.isIgnored("/p"))
        list.setIgnored("/p", false)
        XCTAssertFalse(list.isIgnored("/p"))
        for index in 0...ProjectTrustList.maximumEntries { list.trust(root: "/r\(index)", digest: digest) }
        XCTAssertEqual(list.trusted.count, ProjectTrustList.maximumEntries)
    }

    func testResolveConfinesDirectoriesToTheProject() {
        let file = ProjectFile(
            name: "P",
            tabs: [.init(title: "T", color: .blue, root: .split(key: nil, axis: .x, ratio: 0.3, children: [.pane(.init(directory: "./src//app/", command: "make")), .pane(.init(directory: "."))]))])
        let resolved = file.resolve(projectRoot: "/work/p")
        XCTAssertEqual(resolved.commands, ["t1-1": "make"])
        let tab = resolved.layout.windows[0].tabs[0]
        XCTAssertEqual(resolved.layout.windows[0].key, ProjectFile.windowKey)
        XCTAssertEqual(tab.color, .blue)
        guard case .split(_, _, _, let children) = tab.root, case .pane(_, _, let first) = children[0], case .pane(_, _, let second) = children[1] else {
            return XCTFail("shape")
        }
        XCTAssertEqual(first, .shell(directory: "/work/p/src/app"))
        XCTAssertEqual(second, .shell(directory: "/work/p"))
        XCTAssertNil(ProjectFile.relativeDirectory("a/../b"))
        XCTAssertNil(ProjectFile.relativeDirectory("~"))
        XCTAssertNil(ProjectFile.relativeDirectory("a`b`"))
        XCTAssertEqual(ProjectFile.relativeDirectory("a/b..c"), "a/b..c")
    }

    private func snapshot() -> (WorkspaceSnapshot, ManagedWindow, [UUID]) {
        var snapshot = WorkspaceSnapshot()
        let windowID = UUID(), tabA = UUID(), tabB = UUID(), split = UUID()
        let panes = [UUID(), UUID(), UUID()]
        let window = ManagedWindow(id: windowID, name: "Project", tabIDs: [tabA, tabB], activeTabID: tabA)
        snapshot.windows = [window]
        snapshot.activeWindowID = windowID
        snapshot.tabs[tabA] = WorkspaceTab(
            id: tabA, windowID: windowID, title: "Dev", color: .green, root: .split(id: split, axis: .x, ratio: 0.61234, children: [.pane(panes[0]), .pane(panes[1])]),
            activePaneID: panes[0])
        snapshot.tabs[tabB] = WorkspaceTab(id: tabB, windowID: windowID, title: "Other", root: .pane(panes[2]), activePaneID: panes[2])
        for (index, id) in panes.enumerated() {
            let session = UUID()
            snapshot.panes[id] = WorkspacePane(id: id, tabID: index < 2 ? tabA : tabB, sessionID: session, title: index == 0 ? "Editor" : nil)
            snapshot.sessions[session] = WorkspaceSession(id: session)
        }
        return (snapshot, window, panes)
    }

    func testExportMakesFoldersRelativeAndWarnsOutsideTheProject() throws {
        let (snapshot, window, panes) = snapshot()
        let directories = [panes[0]: "/work/p", panes[1]: "/work/p/src/", panes[2]: "/elsewhere"]
        let exported = ProjectFile.export(
            window: window, snapshot: snapshot, projectRoot: "/work/p", directory: { directories[$0] }, command: { $0 == panes[1] ? "npm test" : nil })
        XCTAssertEqual(exported.paneIDs, [panes[0], panes[1]], "The pane outside the project is left out")
        XCTAssertEqual(exported.tabIDs, [window.tabIDs[0]])
        XCTAssertEqual(exported.warnings, ["Tab “Other” is outside the project folder, so it won't be saved."])
        let file = exported.file
        XCTAssertEqual(file.name, "Project")
        XCTAssertEqual(file.tabs.map(\.title), ["Dev"])
        XCTAssertEqual(file.tabs.map(\.color), [.green])
        XCTAssertEqual(file.entries.map(\.pane.directory), [nil, "src"])
        XCTAssertEqual(file.entries.map(\.pane.title), ["Editor", nil])
        XCTAssertEqual(file.entries.map(\.pane.command), [nil, "npm test"])
        guard case .split(_, _, let ratio, _) = file.tabs[0].root else { return XCTFail("split") }
        XCTAssertEqual(ratio, 0.612)
        XCTAssertTrue(file.issues.isEmpty)
        // A sibling folder sharing the prefix is outside the project.
        let sibling = ProjectFile.export(window: window, snapshot: snapshot, projectRoot: "/work/p", directory: { _ in "/work/p2" }, command: { _ in nil })
        XCTAssertEqual(sibling.file.tabs, [])
        XCTAssertEqual(sibling.paneIDs, [])
        XCTAssertEqual(sibling.warnings.count, 2)
    }

    func testExportLeavesOutsidePanesOutOfAMixedTab() throws {
        var (snapshot, window, panes) = snapshot()
        let sessions = panes.compactMap { snapshot.panes[$0]?.sessionID }
        snapshot.sessions[sessions[1]] = WorkspaceSession(id: sessions[1], launch: .host(UUID()))
        let directories = [panes[0]: "/p/src", panes[1]: "/elsewhere", panes[2]: "/p"]
        let exported = ProjectFile.export(window: window, snapshot: snapshot, projectRoot: "/p", directory: { directories[$0] }, command: { _ in nil })
        XCTAssertEqual(exported.paneIDs, [panes[0], panes[2]])
        XCTAssertEqual(exported.tabIDs, window.tabIDs)
        XCTAssertEqual(exported.file.tabs.map(\.title), ["Dev", "Other"])
        XCTAssertEqual(exported.file.tabs[0].root, .pane(ProjectFile.Pane(title: "Editor", directory: "src")), "The split collapses to the pane inside")
        XCTAssertEqual(exported.warnings.count, 1, "The SSH pane left out adds no SSH warning")
        XCTAssertTrue(exported.warnings[0].contains("“Untitled pane” in “Dev” is in /elsewhere"))
        XCTAssertTrue(exported.warnings[0].hasSuffix("so it won't be saved."))

        // The trimmed tab stays bound, and reopening leaves the omitted pane where it is.
        let bindings = try XCTUnwrap(exported.file.bindings(window: window, tabIDs: exported.tabIDs, paneIDs: exported.paneIDs, snapshot: snapshot))
        XCTAssertEqual(bindings["t1"], LayoutBinding(kind: .tab, id: window.tabIDs[0]))
        XCTAssertEqual(bindings["t1-0"], LayoutBinding(kind: .pane, id: panes[0]))
        XCTAssertEqual(bindings["t2-0"], LayoutBinding(kind: .pane, id: panes[2]))
        let layout = exported.file.resolve(projectRoot: "/p").layout
        let plan = LayoutPlanner.plan(
            layout, bindings: bindings, snapshot: snapshot, home: "/h", hostExists: { _ in false }, directoryExists: { _ in true }, keepLiveLaunches: true,
            keepOmittedPanes: true)
        XCTAssertTrue(plan.canApply, "\(plan.errors) \(plan.conflicts)")
        XCTAssertTrue(plan.creates.isEmpty)
        XCTAssertEqual(plan.target?.tabs[window.tabIDs[0]]?.root, snapshot.tabs[window.tabIDs[0]]?.root)
        // Other layouts still have to declare every pane of a tab they manage.
        let strict = LayoutPlanner.plan(layout, bindings: bindings, snapshot: snapshot, home: "/h", hostExists: { _ in false }, directoryExists: { _ in true })
        XCTAssertTrue(strict.conflicts.contains { $0.text.contains("panes the document omits") })
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

    func testExportWarnsForPanesThatReopenAsLocalShells() throws {
        var (snapshot, window, panes) = snapshot()
        let sessions = panes.compactMap { snapshot.panes[$0]?.sessionID }
        snapshot.sessions[sessions[0]] = WorkspaceSession(id: sessions[0], launch: .host(UUID()))
        snapshot.sessions[sessions[1]] = WorkspaceSession(id: sessions[1], launch: .process(executable: "/usr/bin/htop", arguments: [], directory: "/p"))
        snapshot.sessions[sessions[2]] = WorkspaceSession(id: sessions[2], launch: .process(executable: "/bin/zsh", arguments: ["-l"], directory: "/p"))
        let exported = ProjectFile.export(window: window, snapshot: snapshot, projectRoot: "/p", directory: { _ in "/p" }, command: { _ in nil })
        XCTAssertEqual(exported.warnings.count, 2, "The login shell is what the file holds")
        XCTAssertTrue(exported.warnings[0].contains("“Editor” is an SSH pane"))
        XCTAssertTrue(exported.warnings[1].contains("runs htop"))
        XCTAssertEqual(exported.file.entries.count, 3, "The layout is still saved")
    }

    func testTheTabOfferIsSpokenAsAProject() {
        XCTAssertEqual(WorkspaceAccessibility.projectOfferText("Trellis"), "project Trellis available to load")
    }

    func testBindingsMatchTheWindowShapeOnly() throws {
        let (snapshot, window, panes) = snapshot()
        let exported = ProjectFile.export(window: window, snapshot: snapshot, projectRoot: "/p", directory: { _ in nil }, command: { _ in nil })
        let file = exported.file
        XCTAssertEqual(exported.tabIDs, window.tabIDs)
        let bindings = try XCTUnwrap(file.bindings(window: window, tabIDs: exported.tabIDs, paneIDs: exported.paneIDs, snapshot: snapshot))
        XCTAssertEqual(bindings[ProjectFile.windowKey], LayoutBinding(kind: .window, id: window.id))
        XCTAssertEqual(bindings["t1"], LayoutBinding(kind: .tab, id: window.tabIDs[0]))
        XCTAssertEqual(bindings["t1-1"], LayoutBinding(kind: .pane, id: panes[0]))
        XCTAssertEqual(bindings["t2-0"], LayoutBinding(kind: .pane, id: panes[2]))
        // Re-planning the saved file against its bindings changes nothing.
        let plan = LayoutPlanner.plan(
            file.resolve(projectRoot: "/p").layout, bindings: bindings, snapshot: snapshot, home: "/h", hostExists: { _ in false }, directoryExists: { _ in true },
            keepLiveLaunches: true)
        XCTAssertTrue(plan.canApply, "\(plan.errors) \(plan.conflicts)")
        XCTAssertTrue(plan.creates.isEmpty)
        var reshaped = file
        reshaped.tabs.removeLast()
        XCTAssertNil(reshaped.bindings(window: window, tabIDs: exported.tabIDs, paneIDs: exported.paneIDs, snapshot: snapshot))
    }

    func testSettingCommandsFollowsEntryOrder() {
        let file = ProjectFile(name: "P", tabs: [.init(title: "A", root: .split(key: nil, axis: .x, ratio: 0.5, children: [.pane(.init(command: "old")), .pane(.init())]))])
        XCTAssertEqual(file.settingCommands(["  ", " make "]).entries.map(\.pane.command), [nil, "make"])
        XCTAssertFalse(file.settingCommands(["", ""]).hasCommands)
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
