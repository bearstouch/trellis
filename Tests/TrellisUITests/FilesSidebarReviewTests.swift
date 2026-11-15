import AppKit
import Combine
import XCTest
import TrellisCore
@testable import TrellisUI

/// The Files view's cached tree rows and one-time editor lookup (performance review).
final class FilesSidebarReviewTests: XCTestCase {
    private struct Listing: FileListing {
        let entries: [FileEntry]
        func contents(of directory: String) throws -> [FileEntry] { directory == "/p" ? entries : [] }
        func text(at path: String) -> String? { nil }
    }

    private let root = "/p"
    private func file(_ path: String) -> FileEntry { FileEntry(path: "/p/" + path, isDirectory: false) }
    private func folder(_ path: String) -> FileEntry { FileEntry(path: "/p/" + path, isDirectory: true) }

    private func state() -> FilesBrowserState {
        var state = FilesBrowserState()
        state.root = root
        state.folders = [root: .loaded([folder("A"), folder("B"), file("z.txt")]), "/p/A": .loaded([file("A/a1"), file("A/a2")]), "/p/B": .unreadable]
        return state
    }

    func testRowsFollowEveryChangeToTheTree() {
        var state = state()
        XCTAssertEqual(state.rows.map(\.entry.path), ["/p/A", "/p/B", "/p/z.txt"], "Closed folders show no children")

        state.expanded.insert("/p/A")
        XCTAssertEqual(state.rows.map(\.entry.path), ["/p/A", "/p/A/a1", "/p/A/a2", "/p/B", "/p/z.txt"])
        XCTAssertEqual(state.rows.map(\.depth), [0, 1, 1, 0, 0])

        state.expanded.insert("/p/B")
        XCTAssertEqual(state.rows.filter(\.unreadable).map(\.entry.path), ["/p/B"], "An unreadable open folder shows its note")
        XCTAssertEqual(state.navigableEntries.map(\.path), ["/p/A", "/p/A/a1", "/p/A/a2", "/p/B", "/p/z.txt"], "The note isn't a stop for the keys")

        state.folders["/p/A"] = .loaded([file("A/new")])
        XCTAssertEqual(state.rows.map(\.entry.path), ["/p/A", "/p/A/new", "/p/B", "/p/B", "/p/z.txt"], "A folder read again shows its new listing")

        state.expanded = []
        XCTAssertEqual(state.rows.map(\.entry.path), ["/p/A", "/p/B", "/p/z.txt"])
        state.root = nil
        XCTAssertTrue(state.rows.isEmpty && state.navigableEntries.isEmpty, "No root, no tree")
    }

    func testSelectionResolvesThroughTheTreeOrTheSearch() {
        var state = state()
        state.expanded = ["/p/A"]
        state.selection = "/p/A/a2"
        XCTAssertEqual(state.selectedEntry?.path, "/p/A/a2")
        XCTAssertEqual(state.navigableIndex(of: "/p/A/a2"), 2)
        state.expanded = []
        XCTAssertNil(state.selectedEntry, "A file in a closed folder isn't selectable")

        state.query = "z"
        state.search = FileBrowser.search("z", root: root, listing: Listing(entries: [file("z.txt")]), showHidden: false, ignore: .none)
        state.selection = "/p/z.txt"
        XCTAssertEqual(state.selectedEntry?.path, "/p/z.txt")
        XCTAssertEqual(state.navigableIndex(of: "/p/z.txt"), 0, "While searching the keys move through the results")
        state.query = "  "
        XCTAssertEqual(state.navigableIndex(of: "/p/z.txt"), 2, "A blank query is the tree again")
    }

    @MainActor
    func testEditorsAreLookedUpOnceAndAgainOnReload() async throws {
        _ = NSApplication.shared
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-fbr-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-fbr-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        var lookups = 0
        model.applicationURL = { _ in
            lookups += 1; return nil
        }
        let pane = UUID()

        await model.refreshFiles(paneID: pane)
        let first = lookups
        XCTAssertGreaterThan(first, 0, "The first load looks the editors up")
        await model.refreshFiles(paneID: pane)
        XCTAssertEqual(lookups, first, "A pane switch or cd doesn't look them up again")
        await model.refreshFiles(paneID: pane, reloadEditors: true)
        XCTAssertEqual(lookups, first * 2, "Reload does")
    }

    @MainActor
    func testFilesChangesRedrawFilesAloneButTheEditorChoiceTellsTheApp() throws {
        _ = NSApplication.shared
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-fbo-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-fbo-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        model.applicationURL = { _ in nil }
        var app = 0, files = 0
        let watchers = [model.objectWillChange.sink { app += 1 }, model.filesBrowser.objectWillChange.sink { files += 1 }]
        defer { watchers.forEach { $0.cancel() } }

        model.selectFile("/p/a")
        model.setFilesQuery("abc")
        model.collapseAllFilesFolders()
        XCTAssertEqual(app, 0, "Selecting, searching and folding redraw the Files view, not the window")
        XCTAssertGreaterThan(files, 0)
        XCTAssertEqual(model.files.selection, "/p/a", "and read back through the app model")

        model.loadEditorChoices()
        XCTAssertGreaterThan(app, 0, "The editor choice is shown by Changes, review and editor tabs too")
    }
}
