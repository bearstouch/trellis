import AppKit
import SwiftTerm
import UTermCore
import XCTest
@testable import UTermTerminal

final class ThemePaletteTests: XCTestCase {
    @MainActor
    func testS015_UT03_paletteIndexesKeepOrder() throws {
        _ = NSApplication.shared
        let values = (0..<16).map { UInt32(0x102030 + $0 * 0x010203) }
        let json: [String: Any] = ["version": 1, "id": "ordered", "name": "Ordered", "appearance": "dark",
                                  "terminal": ["ansi": values.map { String(format: "#%06X", $0) }]]
        let palette = try ThemeValidator.validate(JSONSerialization.data(withJSONObject: json)).resolved().terminal
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let observer = PaletteReplyObserver()
        view.terminalDelegate = observer
        native.applyPalette(palette)
        XCTAssertTrue(observer.sent.isEmpty)
        for (index, value) in values.enumerated() {
            native.adapter.receive(Data("\u{1b}]4;\(index);?\u{7}".utf8))
            let expected = String(format: "4;%d;rgb:%04x/%04x/%04x", index, ((value >> 16) & 255) * 257,
                                  ((value >> 8) & 255) * 257, (value & 255) * 257)
            XCTAssertTrue(String(decoding: observer.sent, as: UTF8.self).contains(expected), expected)
        }
        XCTAssertNil(native.processID)
    }
    @MainActor
    func testReapplyResetsBaseColorsWithoutRecoloringTrueColorOr256Cube() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let observer = PaletteReplyObserver(); view.terminalDelegate = observer
        native.adapter.receive(Data("\u{1b}[38;2;17;34;51mX\u{1b}[38;5;21mY\u{1b}[0m".utf8))
        let x = try XCTUnwrap(view.getTerminal().getCharData(col: 0, row: 0)).attribute.fg
        let y = try XCTUnwrap(view.getTerminal().getCharData(col: 1, row: 0)).attribute.fg
        native.adapter.receive(Data("\u{1b}]4;1;#ABCDEF\u{7}".utf8))
        native.searchQuery = "XY"; XCTAssertTrue(native.findInPane(reset: true))
        let palette = try ThemeValidator.validate(ThemeExamples.data(.light)).resolved().terminal
        native.applyPalette(palette)
        XCTAssertEqual(view.accessibilitySelectedText(), "XY")
        XCTAssertEqual(view.getTerminal().getCharData(col: 0, row: 0)?.attribute.fg, x)
        XCTAssertEqual(x, .trueColor(red: 17, green: 34, blue: 51))
        XCTAssertEqual(view.getTerminal().getCharData(col: 1, row: 0)?.attribute.fg, y)
        XCTAssertEqual(y, .ansi256(code: 21))
        native.adapter.receive(Data("\u{1b}]4;21;?\u{7}".utf8))
        XCTAssertTrue(String(decoding: observer.sent, as: UTF8.self).contains("4;21;rgb:0000/0000/ffff"))
        native.adapter.receive(Data("\u{1b}]4;1;?\u{7}".utf8))
        XCTAssertTrue(String(decoding: observer.sent, as: UTF8.self).contains("4;1;rgb:efef/8585/8585"))
        XCTAssertEqual(view.caretTextColor?.usingColorSpace(.sRGB), NSColor(srgbRed: 20.0 / 255, green: 24.0 / 255, blue: 32.0 / 255, alpha: 1))
    }
}

@MainActor
private final class PaletteReplyObserver: NSObject, @preconcurrency TerminalViewDelegate {
    var sent = Data()
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
