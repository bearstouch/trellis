import AppKit
import SwiftUI
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// The Files view in a folder with thousands of files (FR-FB08): the scroll height is right before any row is drawn, and a
/// selection move tells only the lines it touches.
final class FilesSidebarLongFolderTests: XCTestCase {
    private var scratch: URL!
    private var project: String!
    private var shell: String!
    private static let count = 2000

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-fbl-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let manager = FileManager.default
        project = scratch.appendingPathComponent("project").path
        for folder in ["bin", "state", "project/.git", "project/inner"] { try manager.createDirectory(at: scratch.appendingPathComponent(folder), withIntermediateDirectories: true) }
        for index in 0..<Self.count { manager.createFile(atPath: project + "/file-\(index).txt", contents: nil) }
        shell = scratch.appendingPathComponent("bin/sh").path
        try "#!/bin/sh\nprintf 'SHELL-UP\\n'\nexec /bin/cat\n".write(toFile: shell, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    @MainActor private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        for child in view.subviews { if let found = find(type, in: child) { return found } }
        return nil
    }

    @MainActor private func settle(_ view: NSView, _ seconds: TimeInterval = 0.02) { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(seconds)); view.layoutSubtreeIfNeeded() }

    @MainActor
    func testALongFolderKeepsItsScrollHeightWhileScrolling() async throws {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-fbl-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        _ = await model.loadWorkspace()
        model.confirmCloseSessions = { _ in true }
        model.workspaceIsFrontmost = { true }
        model.applicationURL = { _ in nil }
        let saved = await model.saveLaunchSettings(shell: shell, directory: project)
        XCTAssertTrue(saved)
        _ = await model.createSpace(name: "W")
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        defer {
            model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }

        let host = NSHostingView(rootView: FilesSidebarView(model: model, browser: model.filesBrowser, paneID: pane).frame(width: 320, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        let deadline = Date().addingTimeInterval(10)
        while model.files.rows.count < Self.count, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.files.rows.count, Self.count + 1, "The folder and its files are listed")
        settle(host, 0.3)

        let scroll = try XCTUnwrap(find(NSScrollView.self, in: host))
        let document = try XCTUnwrap(scroll.documentView)
        let height = document.frame.height
        XCTAssertEqual(height, CGFloat(Self.count + 1) * 24, accuracy: 1, "Every row counts at its real height before it is drawn")
        var offset: CGFloat = 0
        while offset < height - 600 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset)); scroll.reflectScrolledClipView(scroll.contentView)
            settle(host, 0.001)
            XCTAssertEqual(document.frame.height, height, accuracy: 1, "Drawing rows at \(offset) changed the content's height, which moves the scroller")
            XCTAssertEqual(scroll.contentView.bounds.origin.y, offset, accuracy: 1, "The list moved under the scroll position at \(offset)")
            offset += 2400
        }

        // A selection far away scrolls to it; the height still holds.
        model.selectFile(project + "/file-1000.txt")
        settle(host, 0.1)
        XCTAssertNotEqual(scroll.contentView.bounds.origin.y, offset - 2400, accuracy: 1, "Selecting a row out of view scrolls to it")
        XCTAssertEqual(document.frame.height, height, accuracy: 1)
    }

    @MainActor
    func testASelectionMoveTellsOnlyTheLinesItTouches() {
        let browser = FilesBrowserModel()
        var state = FilesBrowserState()
        state.root = "/p"
        state.folders = ["/p": .loaded([FileEntry(path: "/p/A", isDirectory: true)] + (0..<50).map { FileEntry(path: "/p/f\($0)", isDirectory: false) })]
        state.selection = "/p/f1"
        browser.state = state

        let marks = ["/p/A", "/p/f1", "/p/f2", "/p/f3"].map { browser.marks.mark(for: $0, in: browser.state) }
        XCTAssertEqual(marks.map(\.selected), [false, true, false, false], "A new mark starts from the current state")
        XCTAssertTrue(browser.marks.mark(for: "/p/f2", in: browser.state) === marks[2], "A line drawn again gets the mark it had")
        var told = [0, 0, 0, 0]
        let watching = marks.enumerated().map { index, mark in mark.objectWillChange.sink { told[index] += 1 } }
        defer { watching.forEach { $0.cancel() } }

        browser.state.selection = "/p/f2"
        XCTAssertEqual(marks.map(\.selected), [false, false, true, false])
        XCTAssertEqual(told, [0, 1, 1, 0], "Only the line left and the line reached are redrawn")

        browser.state.status = "Copied"
        browser.state.query = "x"
        XCTAssertEqual(told, [0, 1, 1, 0], "Other Files state changes redraw no line")

        browser.state.expanded.insert("/p/A")
        XCTAssertEqual(marks.map(\.expanded), [true, false, false, false])
        XCTAssertEqual(told, [1, 1, 1, 0], "Opening a folder redraws its line")
        browser.state.expanded = []
        XCTAssertFalse(marks[0].expanded, "Collapse All closes it")

        browser.state.selection = nil
        XCTAssertEqual(marks.map(\.selected), [false, false, false, false])
        browser.state.selection = "/p/f40"
        XCTAssertTrue(browser.marks.mark(for: "/p/f40", in: browser.state).selected, "A line first drawn after the move is already selected")
    }
}
