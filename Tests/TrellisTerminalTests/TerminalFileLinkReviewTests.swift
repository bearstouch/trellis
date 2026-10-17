import AppKit
import SwiftTerm
import XCTest
@testable import TrellisCore
@testable import TrellisTerminal

@MainActor
final class TerminalFileLinkReviewTests: XCTestCase {
    func testContextMenuOpenUsesTheDescribedLinkEvenIfOutputChanges() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let surface = native.view as! AccessibleTerminalView
        var opened: [String] = []
        native.openURL = {
            opened.append($0.path); return true
        }
        native.revealURL = { _ in XCTFail("Nothing is revealed") }
        native.fileProbe = FileProbe { path in ["/tmp/a.txt", "/tmp/b.txt"].contains(path) ? FileFacts(resolvedPath: path, kind: .regular) : nil }
        native.fileLinkContext = { FileLinkContext(currentDirectory: "/tmp", homeDirectory: "/Users/me", localHostNames: []) }
        let window = TerminalPointer.window(for: surface)
        defer { window.close() }
        // The engine reads `/tmp/a.txt /tmp/zz` as one missing path, so the menu falls back to the token under the click.
        native.adapter.receive(Data("/tmp/a.txt /tmp/zz".utf8))
        let point = try XCTUnwrap(TerminalPointer.point(in: surface, at: Position(col: 2, row: 0)))
        let menu = try XCTUnwrap(surface.menu(for: try TerminalPointer.event(.rightMouseDown, at: point, in: window)))
        XCTAssertEqual(menu.items.first?.title, "Open")
        native.adapter.receive(Data("\r/tmp/b.txt /tmp/zz".utf8))
        let item = try XCTUnwrap(menu.items.first)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(opened, ["/tmp/a.txt"])
        XCTAssertNil(surface.lastUserGesture)
    }
}
