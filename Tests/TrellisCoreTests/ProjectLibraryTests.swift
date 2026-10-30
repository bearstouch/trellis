import Foundation
import XCTest

@testable import TrellisCore

/// The project library (FR-PL02, FR-PL04, FR-PL05): validation, editing, storage and capture.
final class ProjectLibraryTests: XCTestCase {
    private func sample() -> ProjectDefinition {
        ProjectDefinition(
            name: "Shop", repository: ProjectRepository(url: "git@github.com:acme/shop.git"),
            tabs: [
                ProjectTab(
                    title: "API", color: .green,
                    root: .split(
                        axis: .x, ratio: 0.6,
                        first: .pane(ProjectPane(title: "Server", directory: "api", command: "make dev", repository: ProjectRepository(url: "https://github.com/acme/api.git", branch: "main"))),
                        second: .pane(ProjectPane(title: "Shell")))),
                ProjectTab(title: "Web", directory: "web", repository: ProjectRepository(url: "ssh://git@github.com/acme/web.git"), root: .pane(ProjectPane(command: "npm run dev")))
            ])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-projects-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAValidProjectHasNoIssuesAndListsItsCheckouts() {
        let project = sample()
        XCTAssertEqual(project.issues, [])
        XCTAssertEqual(project.checkouts.map(\.folder), ["", "api", "web"])
        XCTAssertEqual(project.paneCount, 3)
        XCTAssertEqual(project.commandCount, 2)
        XCTAssertEqual(ProjectDefinition.folder(of: ProjectPane(), in: project.tabs[1]), "web", "A pane without a folder starts in its tab's folder")
    }

    func testRepositoryURLsBranchesAndFoldersAreRefusedWhenUnsafe() {
        for url in [
            "", "-oProxyCommand=x", "ext::sh -c x", "file:///tmp/x", "http://github.com/a/b", "https://user:secret@github.com/a/b", "https://ghp_token@github.com/a/b", "git@github.com:a/b c",
            "git@host:'x'", "https://github.com/a/$(id)", "fd::3", "host:path", "git@:path", "https://",
            "ext::sh@x:y", "fd::3@host:path", "foo::bar@host:repo", "a/b@host:repo", "user:pw@host:repo"
        ] {
            XCTAssertNotNil(GitRepository.urlProblem(url), url)
        }
        for url in ["https://github.com/acme/api.git", "ssh://git@github.com:2222/acme/api.git", "git@github.com:acme/api.git", "deploy@10.0.0.4:/srv/repo.git"] {
            XCTAssertNil(GitRepository.urlProblem(url), url)
        }
        for branch in ["", "-x", ".x", "a..b", "a//b", "a/", "a.lock", "HEAD", "a b", "a;b", "a/.b"] { XCTAssertNotNil(GitRepository.branchProblem(branch), branch) }
        for branch in ["main", "release/1.2", "feature_x-2"] { XCTAssertNil(GitRepository.branchProblem(branch), branch) }
        XCTAssertNil(GitRepository.folder("../x"))
        XCTAssertNil(GitRepository.folder("a\"b"))
        XCTAssertNil(GitRepository.folder("~/x"))
        XCTAssertEqual(GitRepository.folder("."), "")
        XCTAssertEqual(GitRepository.folder("./a//b/"), "a/b")
        XCTAssertEqual(GitRepository.shortName("git@github.com:acme/api.git"), "acme/api")
        XCTAssertEqual(GitRepository.shortName("https://github.com/acme/web"), "acme/web")
    }

    func testIssuesNameTheirPlaceAndField() {
        var project = sample()
        project.name = " "
        project.updatePane(tab: 0, path: [0]) { $0.directory = nil }
        project.updatePane(tab: 0, path: [1]) { $0.command = "echo a\u{202E}b" }
        project.tabs[1].directory = nil
        let issues = project.issues
        XCTAssertTrue(issues.contains { $0.place == .project && $0.field == .name })
        XCTAssertTrue(issues.contains { $0.place == .node(tab: 0, path: [0]) && $0.field == .directory }, "A pane repository needs a folder")
        XCTAssertTrue(issues.contains { $0.place == .node(tab: 0, path: [1]) && $0.field == .command })
        XCTAssertTrue(issues.contains { $0.place == .tab(1) && $0.field == .directory }, "A tab repository needs a folder")

        var clash = sample()
        clash.tabs[1].directory = "api"
        XCTAssertTrue(clash.issues.contains { $0.field == .repositoryURL && $0.message.contains("already has another repository") }, "\(clash.issues)")
        var same = sample()
        same.tabs[1].directory = "api"; same.tabs[1].repository = ProjectRepository(url: "https://github.com/acme/api.git", branch: "main")
        XCTAssertEqual(same.issues, [], "One folder, one repository, named twice")
        XCTAssertEqual(same.checkouts.filter { $0.folder == "api" }.count, 1)
    }

    func testEditingSplitsRemovesAndMovesTabs() {
        var project = ProjectDefinition(name: "P")
        XCTAssertEqual(project.split(tab: 0, path: [], axis: .x), [1])
        XCTAssertEqual(project.split(tab: 0, path: [1], axis: .y), [1, 1])
        XCTAssertEqual(project.paneCount, 3)
        XCTAssertNil(project.split(tab: 0, path: [], axis: .x), "A split isn't a pane")
        XCTAssertEqual(project.remove(tab: 0, path: [1, 0]), .node(tab: 0, path: [1]))
        XCTAssertEqual(project.paneCount, 2)
        XCTAssertNil(project.remove(tab: 0, path: []), "The last tab stays")
        let added = project.addTab()
        XCTAssertEqual(added, 1)
        XCTAssertEqual(project.moveTab(1, by: -1), 0)
        XCTAssertEqual(project.tabs.map(\.title), ["Tab 2", "Shell"])
        XCTAssertEqual(project.remove(tab: 0, path: []), .tab(0))
        XCTAssertEqual(project.tabs.map(\.title), ["Shell"])
        project.remove(tab: 0, path: [0])
        XCTAssertEqual(project.paneCount, 1, "Removing a split's side leaves the other in its place")
        XCTAssertEqual(project.issues, [])
    }

    func testTheLibraryStoresOwnerOnlyAndRefusesStaleOrInvalidSaves() async throws {
        let directory = try temporaryDirectory()
        let library = ProjectLibrary(storage: ProjectFileStorage(directory: directory))
        await library.load()
        let created = try await library.create(sample())
        XCTAssertEqual(created.revision, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("projects.json").path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

        // Recording a launch keeps the editor's revision valid, and an editor never overwrites launch history.
        try await library.recordLaunch(created.id, target: .local, folder: "/Users/me/code/shop")
        var edited = created
        edited.name = "Shop 2"
        let saved = try await library.update(edited)
        XCTAssertEqual(saved.lastFolders, ["local": "/Users/me/code/shop"])
        do { _ = try await library.update(edited); XCTFail("A stale save must be refused") } catch { XCTAssertEqual(error, .conflict) }
        var invalid = saved
        invalid.tabs = []
        do { _ = try await library.update(invalid); XCTFail("An invalid project must be refused") } catch {
            guard case .invalid = error else { return XCTFail("\(error)") }
        }

        let reloaded = ProjectLibrary(storage: ProjectFileStorage(directory: directory))
        await reloaded.load()
        let projects = await reloaded.projects
        XCTAssertEqual(projects, [saved])
        let second = try await reloaded.create(sample())
        XCTAssertNotEqual(second.id, saved.id, "Creating again gives a new identity")
    }

    func testAnUnreadableLibraryIsReadOnlyUntilResetAndIsKept() async throws {
        let directory = try temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("projects.json")
        try Data(#"{"schemaVersion": 99, "revision": 1, "projects": []}"#.utf8).write(to: url)
        let library = ProjectLibrary(storage: ProjectFileStorage(directory: directory))
        let loaded = await library.load()
        XCTAssertFalse(loaded)
        do { _ = try await library.create(sample()); XCTFail("A read-only library refuses changes") } catch { XCTAssertEqual(error, .readOnly) }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), #"{"schemaVersion": 99, "revision": 1, "projects": []}"#, "Never overwritten")
        try await library.resetUnreadable()
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("projects.unreadable.") }
        XCTAssertEqual(kept.count, 1)
        _ = try await library.create(sample())

        // A hand-edited file with a command the editor refuses isn't loaded.
        var bad = sample()
        bad.updatePane(tab: 1, path: []) { $0.command = "a\nb" }
        try ProjectLibraryCodec.encode([bad], revision: 1).write(to: url)
        let refused = await ProjectLibrary(storage: ProjectFileStorage(directory: directory)).load()
        XCTAssertFalse(refused)
    }

    func testCapturingAWindowUsesTheCommonFolderAndNeverCommands() throws {
        let window = UUID(), tab = UUID(), first = UUID(), second = UUID(), third = UUID(), split = UUID(), inner = UUID()
        let sessions = [UUID(), UUID(), UUID()]
        var snapshot = WorkspaceSnapshot()
        snapshot.windows = [ManagedWindow(id: window, name: "Shop", tabIDs: [tab], activeTabID: tab)]
        snapshot.tabs[tab] = WorkspaceTab(
            id: tab, windowID: window, title: "API", color: .blue,
            root: .split(id: split, axis: .x, ratio: 0.6234, children: [.pane(first), .split(id: inner, axis: .y, ratio: 0.5, children: [.pane(second), .pane(third)])]),
            activePaneID: first)
        let folders = [first: "/Users/me/code/shop/api", second: "/Users/me/code/shop/web", third: "/Users/me/code/shop"]
        for (index, pane) in [first, second, third].enumerated() {
            snapshot.panes[pane] = WorkspacePane(id: pane, tabID: tab, sessionID: sessions[index], title: index == 0 ? "Server" : nil)
            snapshot.sessions[sessions[index]] = WorkspaceSession(id: sessions[index], launch: index == 1 ? .host(UUID()) : .shell(directory: folders[pane]))
        }
        let capture = try XCTUnwrap(ProjectCapture.capture(window: window, snapshot: snapshot, home: "/Users/me") { folders[$0] })
        XCTAssertEqual(capture.project.name, "Shop")
        XCTAssertEqual(capture.project.lastFolders, ["local": "/Users/me/code/shop"])
        XCTAssertEqual(capture.project.tabs.first?.color, .blue)
        XCTAssertEqual(capture.project.tabs.first?.root.panes.map(\.pane.directory), ["api", "web", nil])
        XCTAssertEqual(capture.project.commandCount, 0)
        guard case .split(_, let ratio, _, _)? = capture.project.tabs.first?.root else { return XCTFail("No split") }
        XCTAssertEqual(ratio, 0.623, accuracy: 0.0001)
        XCTAssertEqual(capture.warnings.count, 1, "The SSH pane becomes a shell, with a warning")
        XCTAssertEqual(capture.project.issues, [])

        let relative = try XCTUnwrap(ProjectCapture.capture(window: window, snapshot: snapshot, home: "/Users/me") { $0 == first ? "code/shop/api" : folders[$0] })
        XCTAssertEqual(relative.project.lastFolders, ["local": "/Users/me/code/shop"], "A relative folder is never resolved against the app's own")
        XCTAssertEqual(ProjectCapture.commonFolder(["/a/b", "/c"]), "/")
    }
}
