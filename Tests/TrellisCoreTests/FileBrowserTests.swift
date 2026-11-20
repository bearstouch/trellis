import XCTest

@testable import TrellisCore

/// The Files view's listing, ignore rules and search (FR-FB03, FR-FB04), over an in-memory file system.
final class FileBrowserTests: XCTestCase {
    private struct FakeListing: FileListing {
        var tree: [String: [FileEntry]]
        var texts: [String: String] = [:]
        struct Unreadable: Error {}
        func contents(of directory: String) throws -> [FileEntry] {
            guard let entries = tree[directory] else { throw Unreadable() }
            return entries
        }
        func text(at path: String) -> String? { texts[path] }
    }

    private func file(_ path: String) -> FileEntry { FileEntry(path: path, isDirectory: false) }
    private func folder(_ path: String) -> FileEntry { FileEntry(path: path, isDirectory: true) }

    private var project: FakeListing {
        FakeListing(tree: [
            "/p": [
                file("/p/README.md"), folder("/p/Sources"), file("/p/.env"), folder("/p/.git"), folder("/p/node_modules"),
                file("/p/b.txt"), folder("/p/docs"), FileEntry(path: "/p/link", isDirectory: true, isSymbolicLink: true), file("/p/app.log")
            ],
            "/p/Sources": [file("/p/Sources/RightSidebar.swift"), file("/p/Sources/AppWorkspaceModel+Sidebar.swift"), file("/p/Sources/Other.swift")],
            "/p/docs": [file("/p/docs/sidebar.md"), folder("/p/docs/build")],
            "/p/docs/build": [file("/p/docs/build/sidebar.html")],
            "/p/.git": [file("/p/.git/HEAD")],
            "/p/node_modules": [file("/p/node_modules/sidebar.js")]
        ])
    }

    func testChildrenListFoldersFirstAndSkipHiddenAndBuildFolders() throws {
        let names = try FileBrowser.children(of: "/p", root: "/p", listing: project, showHidden: false, ignore: .none).map(\.name)
        XCTAssertEqual(names, ["docs", "Sources", "app.log", "b.txt", "link", "README.md"])
        let shown = try FileBrowser.children(of: "/p", root: "/p", listing: project, showHidden: true, ignore: .none).map(\.name)
        XCTAssertTrue(shown.contains(".env"), "The hidden-files toggle shows dotfiles")
        XCTAssertFalse(shown.contains(".git"), ".git stays out even with hidden files shown")
        XCTAssertFalse(shown.contains("node_modules"))
    }

    func testASymbolicLinkIsNeverAFolder() {
        let link = FileEntry(path: "/p/link", isDirectory: true, isSymbolicLink: true)
        XCTAssertFalse(link.isDirectory, "The tree never follows a link into another folder")
        XCTAssertTrue(link.isSymbolicLink)
    }

    func testAnUnreadableFolderThrowsWithoutAffectingOthers() {
        XCTAssertThrowsError(try FileBrowser.children(of: "/p/missing", root: "/p", listing: project, showHidden: false, ignore: .none))
        let result = FileBrowser.search(
            "other", root: "/p", listing: FakeListing(tree: ["/p": [folder("/p/locked"), folder("/p/Sources")], "/p/Sources": [file("/p/Sources/Other.swift")]]), showHidden: false, ignore: .none)
        XCTAssertEqual(result.matches.map(\.entry.path), ["/p/Sources/Other.swift"], "Search skips a folder it can't read")
    }

    func testGitignorePatterns() {
        let ignore = IgnorePatterns(gitignore: "# comment\n*.log\n/build/\ndocs/build/\n!keep.log\n**/cache\n")
        XCTAssertTrue(ignore.ignores(relativePath: "app.log", isDirectory: false))
        XCTAssertTrue(ignore.ignores(relativePath: "deep/x/app.log", isDirectory: false), "An unanchored pattern matches at any depth")
        XCTAssertTrue(ignore.ignores(relativePath: "build", isDirectory: true))
        XCTAssertFalse(ignore.ignores(relativePath: "build", isDirectory: false), "A trailing slash matches folders only")
        XCTAssertFalse(ignore.ignores(relativePath: "src/build", isDirectory: true), "A leading slash anchors to the root")
        XCTAssertTrue(ignore.ignores(relativePath: "docs/build", isDirectory: true), "An inner slash anchors to the root")
        XCTAssertTrue(ignore.ignores(relativePath: "a/b/cache", isDirectory: true))
        XCTAssertTrue(ignore.ignores(relativePath: "keep.log", isDirectory: false), "Negations aren't supported, so nothing is un-ignored")
        XCTAssertFalse(ignore.ignores(relativePath: "README.md", isDirectory: false))
    }

    func testIgnorePatternsComeFromTheRootGitignore() throws {
        var listing = project
        listing.texts["/p/.gitignore"] = "*.log\n"
        let ignore = FileBrowser.ignorePatterns(root: "/p", listing: listing)
        let names = try FileBrowser.children(of: "/p", root: "/p", listing: listing, showHidden: false, ignore: ignore).map(\.name)
        XCTAssertFalse(names.contains("app.log"))
        XCTAssertEqual(FileBrowser.ignorePatterns(root: "/p", listing: project), .none, "No .gitignore ignores nothing")
    }

    func testSearchRanksNameMatchesAndSkipsIgnoredFolders() {
        let result = FileBrowser.search("sidebar", root: "/p", listing: project, showHidden: false, ignore: IgnorePatterns(gitignore: "docs/build/"))
        let paths = result.matches.map(\.entry.path)
        XCTAssertEqual(paths.first, "/p/docs/sidebar.md", "The whole name at a word start ranks first")
        XCTAssertTrue(paths.contains("/p/Sources/RightSidebar.swift"))
        XCTAssertTrue(paths.contains("/p/Sources/AppWorkspaceModel+Sidebar.swift"))
        XCTAssertFalse(paths.contains("/p/node_modules/sidebar.js"), "Skipped folders aren't searched")
        XCTAssertFalse(paths.contains("/p/docs/build/sidebar.html"), "Ignored folders aren't searched")
        XCTAssertFalse(paths.contains("/p/.git/HEAD"))
        XCTAssertFalse(result.truncated)
        let first = result.matches.first { $0.entry.path == "/p/Sources/RightSidebar.swift" }
        XCTAssertEqual(first?.relativeFolder, "Sources")
        XCTAssertEqual(first?.namePositions, Array(5..<12), "Positions point into the name for highlighting")
    }

    func testAQueryWithASlashMatchesTheRelativePath() {
        let result = FileBrowser.search("src/other", root: "/p", listing: project, showHidden: false, ignore: .none)
        XCTAssertEqual(result.matches.map(\.entry.path), ["/p/Sources/Other.swift"])
        XCTAssertEqual(result.matches.first?.namePositions, [], "A path match has no name highlights")
    }

    func testSearchStopsAtTheFileAndResultLimits() {
        let many = FakeListing(tree: ["/p": (0..<50).map { file("/p/file\($0).txt") }])
        let limited = FileBrowser.search("file", root: "/p", listing: many, showHidden: false, ignore: .none, fileLimit: 10, resultLimit: 100)
        XCTAssertTrue(limited.truncated, "The walk says it stopped early")
        XCTAssertEqual(limited.matches.count, 10)
        let capped = FileBrowser.search("file", root: "/p", listing: many, showHidden: false, ignore: .none, fileLimit: 100, resultLimit: 5)
        XCTAssertEqual(capped.matches.count, 5)
        XCTAssertFalse(capped.truncated)
    }

    /// FR-FB09: the walk a remote tree uses asks a level at a time and finds what the local walk finds.
    func testTheSourceWalkFindsWhatTheListingWalkFinds() async {
        let ignore = IgnorePatterns(gitignore: "build/\n*.log\n")
        let source = ListingTreeSource(project)
        for (query, showHidden, patterns) in [("sidebar", false, ignore), ("sidebar", false, .none), ("docs/side", false, ignore), ("e", true, .none), ("zzz", false, ignore)] {
            let local = FileBrowser.search(query, root: "/p", listing: project, showHidden: showHidden, ignore: patterns)
            let remote = await FileBrowser.search(query, root: "/p", source: source, showHidden: showHidden, ignore: patterns)
            XCTAssertEqual(remote, local, query)
        }
        let cut = await FileBrowser.search("s", root: "/p", source: source, showHidden: false, ignore: .none, fileLimit: 3, resultLimit: 1)
        XCTAssertEqual(cut, FileBrowser.search("s", root: "/p", listing: project, showHidden: false, ignore: .none, fileLimit: 3, resultLimit: 1))
        XCTAssertTrue(cut.truncated)
        let patterns = await FileBrowser.ignorePatterns(root: "/p", source: ListingTreeSource(FakeListing(tree: [:], texts: ["/p/.gitignore": "build/\n*.log\n"])))
        XCTAssertEqual(patterns, ignore)
    }

    func testTheSourceWalkAsksForEachLevelAtOnceAndSkipsUnreadableFolders() async {
        actor Asked { var rounds: [[String]] = []; func add(_ round: [String]) { rounds.append(round) } }
        struct Recording: FileTreeSource {
            let inner: ListingTreeSource, asked: Asked
            func contents(of directories: [String]) async -> [String: FolderListing] { await asked.add(directories); var listed = await inner.contents(of: directories); listed["/p/Sources"] = .unreadable; return listed }
            func text(at path: String) async -> String? { nil }
        }
        let asked = Asked()
        let result = await FileBrowser.search("sidebar", root: "/p", source: Recording(inner: ListingTreeSource(project), asked: asked), showHidden: false, ignore: .none)
        let rounds = await asked.rounds
        XCTAssertEqual(rounds, [["/p"], ["/p/docs", "/p/Sources"], ["/p/docs/build"]], "One request per level; a link and the skipped folders are never asked for")
        XCTAssertEqual(result.matches.map(\.entry.name), ["sidebar.md", "sidebar.html"], "The unreadable folder is skipped, the rest searched")
    }

    func testRelativePath() {
        XCTAssertEqual(FileBrowser.relativePath("/p/a/b.txt", root: "/p"), "a/b.txt")
        XCTAssertEqual(FileBrowser.relativePath("/p/a/b.txt", root: "/p/"), "a/b.txt")
        XCTAssertEqual(FileBrowser.relativePath("/other/b.txt", root: "/p"), "/other/b.txt")
        XCTAssertEqual(FileBrowser.relativePath("/pp/b.txt", root: "/p"), "/pp/b.txt", "A sibling with a longer name isn't inside")
    }

    func testTheEditorCatalog() {
        XCTAssertEqual(EditorApp.catalog.prefix(2), [.trellisEditor, .finder])
        XCTAssertEqual(Set(EditorApp.catalog.map(\.id)).count, EditorApp.catalog.count, "Ids are unique")
        XCTAssertEqual(EditorApp.with(id: "cursor")?.name, "Cursor")
        XCTAssertNil(EditorApp.with(id: "nope"))
    }

    func testLocalListingReportsLinksWithoutFollowingThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-fb-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("loop").path, withDestinationPath: root.path)
        let entries = try LocalFileListing().contents(of: root.path).sorted { $0.name < $1.name }
        XCTAssertEqual(entries.map(\.name), ["a.txt", "dir", "loop"])
        XCTAssertEqual(entries.map(\.isDirectory), [false, true, false], "A link to a folder isn't a folder, so it can't loop")
        XCTAssertEqual(entries.last?.isSymbolicLink, true)
        XCTAssertEqual(entries.first?.path, root.path + "/a.txt")
    }

    func testLocalListingReadsOnlyARegularGitignore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-fb-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("fifo"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("linked"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("zero"), withIntermediateDirectories: true)
        try "*.log\n".write(to: root.appendingPathComponent("real"), atomically: true, encoding: .utf8)
        XCTAssertEqual(mkfifo(root.appendingPathComponent("fifo/.gitignore").path, 0o600), 0)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("linked/.gitignore").path, withDestinationPath: root.appendingPathComponent("real").path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("zero/.gitignore").path, withDestinationPath: "/dev/zero")
        let listing = LocalFileListing()
        XCTAssertNil(listing.text(at: root.appendingPathComponent("fifo/.gitignore").path), "A FIFO is never opened, so reading can't block")
        XCTAssertNil(listing.text(at: root.appendingPathComponent("zero/.gitignore").path), "A link to a device is never read")
        XCTAssertEqual(listing.text(at: root.appendingPathComponent("linked/.gitignore").path), "*.log\n", "A link to a regular file is read")
    }
}
