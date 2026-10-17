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
        XCTAssertEqual(file.items.prefix(2).map(\.title), ["Open", "Copy Path"])
        try perform(file.item(at: 1))
        XCTAssertEqual(writes.last, "/tmp/report.pdf")

        let app = try menu(at: 42)
        XCTAssertEqual(app.items.first?.title, "Reveal in Finder")
        try perform(app.item(at: 0))
        XCTAssertEqual(recorder().revealed, ["/tmp/x.app"])

        XCTAssertEqual(try menu(at: 50).items.first?.title, "Copy", "Elsewhere the menu is unchanged")
        native.fileLinkContext = { nil }
        XCTAssertEqual(try menu(at: 25).items.first?.title, "Copy", "Panes without a file context offer no file actions")
    }
}
