import AppKit
import SwiftTerm
import XCTest
@testable import TrellisCore
@testable import TrellisTerminal

@MainActor
final class TerminalFileLinkTests: XCTestCase {
    private struct Recorder { var opened: [String] = []; var revealed: [String] = [] }

    private func makeTerminal(
        files: [String: FileFacts], context: FileLinkContext? = FileLinkContext(currentDirectory: "/work", homeDirectory: "/Users/me", localHostNames: ["mymac"])
    ) -> (NativeTerminal, AccessibleTerminalView, () -> Recorder) {
        _ = NSApplication.shared
        let native = NativeTerminal()
        let surface = native.view as! AccessibleTerminalView
        var recorder = Recorder()
        native.openURL = {
            recorder.opened.append($0.isFileURL ? $0.path : $0.absoluteString); return true
        }
        native.revealURL = { recorder.revealed.append($0.path) }
        native.fileProbe = FileProbe { files[$0] }
        native.fileLinkContext = { context }
        return (native, surface, { recorder })
    }

    func testCmdClickFileLinkOpensOrRevealsOnlyWithContextAndGesture() throws {
        let files = [
            "/work/src/a.swift": FileFacts(resolvedPath: "/work/src/a.swift", kind: .regular),
            "/work/run.sh": FileFacts(resolvedPath: "/work/run.sh", kind: .regular, isExecutable: true)
        ]
        let (native, surface, recorder) = makeTerminal(files: files)
        defer { native.adapter.detach() }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        native.now = { clock }

        native.requestOpenLink(source: surface, link: "src/a.swift:3:1", params: [:])
        XCTAssertEqual(recorder().opened, [], "Output alone never opens a file")

        surface.lastUserGesture = clock
        native.requestOpenLink(source: surface, link: "src/a.swift:3:1", params: [:])
        native.requestOpenLink(source: surface, link: "src/a.swift", params: [:])
        XCTAssertEqual(recorder().opened, ["/work/src/a.swift"], "One click opens at most one link")

        surface.lastUserGesture = clock
        native.requestOpenLink(source: surface, link: "./run.sh", params: [:])
        XCTAssertEqual(recorder().revealed, ["/work/run.sh"])
        XCTAssertEqual(recorder().opened.count, 1, "Executables are never opened")

        surface.lastUserGesture = clock
        native.requestOpenLink(source: surface, link: "/work/missing.txt", params: [:])
        clock = clock.addingTimeInterval(5)
        native.requestOpenLink(source: surface, link: "src/a.swift", params: [:])
        XCTAssertEqual(recorder().opened.count, 1, "A stale gesture authorizes nothing")

        native.fileLinkContext = { nil }
        surface.lastUserGesture = clock
        native.requestOpenLink(source: surface, link: "/work/src/a.swift", params: [:])
        XCTAssertEqual(recorder().opened.count, 1, "Panes without a file context never open files")
        native.requestOpenLink(source: surface, link: "https://example.com", params: [:])
        XCTAssertEqual(recorder().opened.last, "https://example.com", "Web links still open")
    }

    private func cmdClick(_ surface: AccessibleTerminalView, window: NSWindow, at position: Position) throws {
        let point = try XCTUnwrap(TerminalPointer.point(in: surface, at: position))
        surface.mouseUp(with: try TerminalPointer.event(.leftMouseUp, at: point, in: window, modifiers: [.command]))
    }

    func testOSC8FileLinksOpenOnlyForLocalHosts() throws {
        let files = ["/tmp/a b.txt": FileFacts(resolvedPath: "/tmp/a b.txt", kind: .regular), "/etc/hosts": FileFacts(resolvedPath: "/etc/hosts", kind: .regular)]
        let (native, surface, recorder) = makeTerminal(files: files)
        defer { native.adapter.detach() }
        let window = TerminalPointer.window(for: surface)
        defer { window.close() }
        native.adapter.receive(Data("\u{1b}]8;;file://mymac/tmp/a%20b.txt\u{1b}\\local\u{1b}]8;;\u{1b}\\ \u{1b}]8;;file://evil/etc/hosts\u{1b}\\remote\u{1b}]8;;\u{1b}\\".utf8))
        try cmdClick(surface, window: window, at: Position(col: 8, row: 0))
        XCTAssertEqual(recorder().opened, [], "A file:// link naming another host is refused")
        try cmdClick(surface, window: window, at: Position(col: 2, row: 0))
        XCTAssertEqual(recorder().opened, ["/tmp/a b.txt"])
        XCTAssertNil(surface.lastUserGesture, "The click's gesture ends with mouseUp")
    }

    func testOSC8SchemelessTargetRefused() throws {
        let files = ["/etc/hosts": FileFacts(resolvedPath: "/etc/hosts", kind: .regular)]
        let (native, surface, recorder) = makeTerminal(files: files)
        defer { native.adapter.detach() }
        let window = TerminalPointer.window(for: surface)
        defer { window.close() }
        native.adapter.receive(Data("\u{1b}]8;;/etc/hosts\u{1b}\\readme\u{1b}]8;;\u{1b}\\ /etc/hosts".utf8))
        try cmdClick(surface, window: window, at: Position(col: 2, row: 0))
        XCTAssertEqual(recorder().opened, [], "Visible text 'readme' must not open a hidden path")
        try cmdClick(surface, window: window, at: Position(col: 10, row: 0))
        XCTAssertEqual(recorder().opened, ["/etc/hosts"], "The same path printed as text opens")
    }

    func testCmdClickPrefersEnginePathAndFallsBackToClickedToken() throws {
        let files = [
            "/tmp/report.pdf": FileFacts(resolvedPath: "/tmp/report.pdf", kind: .regular),
            "/tmp/My Notes/a.txt": FileFacts(resolvedPath: "/tmp/My Notes/a.txt", kind: .regular)
        ]
        let (native, surface, recorder) = makeTerminal(files: files)
        defer { native.adapter.detach() }
        let window = TerminalPointer.window(for: surface)
        defer { window.close() }
        native.adapter.receive(Data("/tmp/report.pdf /tmp/x.app\r\n/tmp/My Notes/a.txt".utf8))
        try cmdClick(surface, window: window, at: Position(col: 3, row: 0))
        XCTAssertEqual(recorder().opened, ["/tmp/report.pdf"], "Two paths on a line open separately")
        try cmdClick(surface, window: window, at: Position(col: 3, row: 1))
        XCTAssertEqual(recorder().opened.last, "/tmp/My Notes/a.txt", "A detected path with spaces still opens whole")
    }

    func testOSC8URLWithSemicolonIsNotTruncated() throws {
        let (native, surface, recorder) = makeTerminal(files: [:])
        defer { native.adapter.detach() }
        let window = TerminalPointer.window(for: surface)
        defer { window.close() }
        native.adapter.receive(Data("\u{1b}]8;id=1;https://example.com/a;b=c\u{1b}\\link\u{1b}]8;;\u{1b}\\".utf8))
        try cmdClick(surface, window: window, at: Position(col: 1, row: 0))
        XCTAssertEqual(recorder().opened, ["https://example.com/a;b=c"])
    }

    func testContextMenuOffersLinkActionsOnlyOverLinks() throws {
        let files = ["/tmp/report.pdf": FileFacts(resolvedPath: "/tmp/report.pdf", kind: .regular), "/tmp/x.app": FileFacts(resolvedPath: "/tmp/x.app", kind: .directory, isPackage: true)]
        let (native, surface, recorder) = makeTerminal(files: files)
        defer { native.adapter.detach() }
        let window = TerminalPointer.window(for: surface)
        defer { window.close() }
        var writes: [String] = []
        surface.writeClipboard = { writes.append($0) }
        native.adapter.receive(Data("https://example.com/a /tmp/report.pdf /tmp/x.app plain".utf8))
        func menu(at col: Int) throws -> NSMenu {
            let point = try XCTUnwrap(TerminalPointer.point(in: surface, at: Position(col: col, row: 0)))
            return try XCTUnwrap(surface.menu(for: try TerminalPointer.event(.rightMouseDown, at: point, in: window)))
        }
        func perform(_ item: NSMenuItem?) throws { XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item?.action), to: item?.target, from: item)) }

        let web = try menu(at: 3)
        XCTAssertEqual(web.items.prefix(2).map(\.title), ["Open Link", "Copy Link"])
        try perform(web.item(at: 1))
        try perform(web.item(at: 0))
        XCTAssertEqual(writes, ["https://example.com/a"])
        XCTAssertEqual(recorder().opened, ["https://example.com/a"], "Choosing Open Link is the gesture")

        let file = try menu(at: 25)
        XCTAssertEqual(file.items.prefix(3).map(\.title), ["Open", "Show in Finder", "Copy Path"])
        try perform(file.item(at: 2))
        XCTAssertEqual(writes.last, "/tmp/report.pdf")
        try perform(file.item(at: 1))
        XCTAssertEqual(recorder().revealed, ["/tmp/report.pdf"])
        XCTAssertEqual(recorder().opened.count, 1, "Show in Finder opens nothing")

        let app = try menu(at: 42)
        XCTAssertEqual(app.items.prefix(2).map(\.title), ["Show in Finder", "Copy Path"], "Launchable files show it once")
        try perform(app.item(at: 0))
        XCTAssertEqual(recorder().revealed.last, "/tmp/x.app")

        XCTAssertEqual(try menu(at: 50).items.first?.title, "Copy", "Elsewhere the menu is unchanged")
        native.fileLinkContext = { nil }
        XCTAssertEqual(try menu(at: 25).items.first?.title, "Copy", "Panes without a file context offer no file actions")
    }

    func testContextMenuInsideSelectionUsesTheSelectedText() throws {
        // The last entry exists so the multi-line check below fails on the line break, not on a missing file.
        let multiLine = "/work/README.md My Notes.txt https://example.com/a\nsecon"
        let files = [
            "/work/README.md": FileFacts(resolvedPath: "/work/README.md", kind: .regular), "/work/My Notes.txt": FileFacts(resolvedPath: "/work/My Notes.txt", kind: .regular),
            multiLine: FileFacts(resolvedPath: multiLine, kind: .regular)
        ]
        let (native, surface, recorder) = makeTerminal(files: files)
        defer { native.adapter.detach() }
        let window = TerminalPointer.window(for: surface)
        defer { window.close() }
        var writes: [String] = []
        surface.writeClipboard = { writes.append($0) }
        native.adapter.receive(Data("README.md My Notes.txt https://example.com/a\r\nsecond line".utf8))
        func select(_ start: Position, _ end: Position) {
            surface.selection.setSoftStart(bufferPosition: start)
            surface.selection.startSelection()
            surface.selection.dragExtend(bufferPosition: end)
        }
        func menu(at col: Int, row: Int = 0) throws -> NSMenu {
            let point = try XCTUnwrap(TerminalPointer.point(in: surface, at: Position(col: col, row: row)))
            return try XCTUnwrap(surface.menu(for: try TerminalPointer.event(.rightMouseDown, at: point, in: window)))
        }
        func perform(_ item: NSMenuItem?) throws { XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item?.action), to: item?.target, from: item)) }

        XCTAssertEqual(try menu(at: 3).items.first?.title, "Copy", "A bare name is only a file once it is selected")

        select(Position(col: 0, row: 0), Position(col: 9, row: 0))
        let bare = try menu(at: 3)
        XCTAssertEqual(bare.items.prefix(3).map(\.title), ["Open", "Show in Finder", "Copy Path"])
        try perform(bare.item(at: 1))
        XCTAssertEqual(recorder().revealed, ["/work/README.md"])
        XCTAssertEqual(recorder().opened, [], "Show in Finder opens nothing")
        XCTAssertEqual(try menu(at: 30).items.first?.title, "Open Link", "A click outside the selection ignores it")

        select(Position(col: 10, row: 0), Position(col: 22, row: 0))
        let spaced = try menu(at: 12)
        try perform(spaced.item(at: 2))
        XCTAssertEqual(writes, ["/work/My Notes.txt"], "A selected name keeps its spaces")

        // The end is half-open: col 23, the link's first cell, is not selected.
        select(Position(col: 10, row: 0), Position(col: 23, row: 0))
        XCTAssertEqual(try menu(at: 22).items.first?.title, "Open", "The last selected cell is inside")
        XCTAssertEqual(try menu(at: 23).items.first?.title, "Open Link", "The cell after the selection is outside it")

        select(Position(col: 31, row: 0), Position(col: 38, row: 0))
        XCTAssertEqual(try menu(at: 33).items.first?.title, "Open Link", "A selection naming nothing falls back to the clicked link")

        select(Position(col: 0, row: 0), Position(col: 5, row: 1))
        XCTAssertEqual(try menu(at: 3).items.first?.title, "Copy", "A multi-line selection names nothing")

        select(Position(col: 0, row: 0), Position(col: 9, row: 0))
        native.fileLinkContext = { nil }
        XCTAssertEqual(try menu(at: 3).items.first?.title, "Copy", "Panes without a file context offer no file actions")
    }

    func testContextMenuSelectionMatchesTheClickAfterScrollback() throws {
        let (native, surface, recorder) = makeTerminal(files: ["/work/README.md": FileFacts(resolvedPath: "/work/README.md", kind: .regular)])
        defer { native.adapter.detach() }
        let window = TerminalPointer.window(for: surface)
        defer { window.close() }
        native.adapter.receive(Data((String(repeating: "filler\r\n", count: 200) + "README.md").utf8))
        let terminal = surface.getTerminal()
        let row = terminal.buffer.yDisp + terminal.buffer.y
        XCTAssertGreaterThan(row, 100)
        surface.selection.setSoftStart(bufferPosition: Position(col: 0, row: row))
        surface.selection.startSelection()
        surface.selection.dragExtend(bufferPosition: Position(col: 9, row: row))
        let point = try XCTUnwrap(TerminalPointer.point(in: surface, at: Position(col: 3, row: row)))
        let menu = try XCTUnwrap(surface.menu(for: try TerminalPointer.event(.rightMouseDown, at: point, in: window)))
        let item = try XCTUnwrap(menu.items.dropFirst().first)
        XCTAssertEqual(item.title, "Show in Finder")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(recorder().revealed, ["/work/README.md"])
    }

    func testRevealLinkNeedsAFreshGestureAndIgnoresWebLinks() {
        let (native, surface, recorder) = makeTerminal(files: ["/work/a.txt": FileFacts(resolvedPath: "/work/a.txt", kind: .regular)])
        defer { native.adapter.detach() }
        native.revealLink(TerminalLinkClick(link: "a.txt", explicit: false, position: nil))
        XCTAssertEqual(recorder().revealed, [], "Without a gesture nothing is revealed")
        surface.lastUserGesture = Date()
        native.revealLink(TerminalLinkClick(link: "https://example.com", explicit: false, position: nil))
        XCTAssertEqual(recorder().revealed, [])
        XCTAssertEqual(recorder().opened, [], "A web link is never opened by Show in Finder")
    }
}
