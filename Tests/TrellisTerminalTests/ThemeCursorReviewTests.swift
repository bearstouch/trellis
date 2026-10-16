import AppKit
import SwiftTerm
import TrellisCore
import XCTest
@testable import TrellisTerminal

final class ThemeCursorReviewTests: XCTestCase {
    @MainActor
    func testThemeReapplyResetsCursorQueryAfterSessionOverride() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let observer = CursorReplyObserver()
        view.terminalDelegate = observer
        native.adapter.receive(Data("\u{1b}]12;#123456\u{7}".utf8))
        native.applyPalette(.builtIn)
        XCTAssertTrue(observer.sent.isEmpty, "Changing a palette must not send any terminal input.")
        native.adapter.receive(Data("\u{1b}]12;?\u{7}".utf8))
        XCTAssertTrue(String(decoding: observer.sent, as: UTF8.self).contains("12;rgb:b9b9/dcdc/ffff"))
        let color = try XCTUnwrap(view.caretColor.usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 185.0 / 255, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 220.0 / 255, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1, accuracy: 0.001)
    }
}

@MainActor
private final class CursorReplyObserver: NSObject, @preconcurrency TerminalViewDelegate {
    var sent = Data()
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
