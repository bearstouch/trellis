import AppKit
import XCTest
import SwiftTerm
import UTermCore
@testable import UTermTerminal

final class TerminalSearchTests: XCTestCase {
    @MainActor
    func testS013_UT01_engineHistoryHonorsLineAndUTF8ByteBudgets() throws {
        _ = NSApplication.shared
        let native = NativeTerminal(scrollbackBudget: ScrollbackBudget(lineLimit: 3, byteLimit: 24))
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        view.getTerminal().resize(cols: 40, rows: 2)
        native.adapter.receive(Data((0..<30).map { "row \($0)\r\n" }.joined().utf8))
        XCTAssertLessThanOrEqual(view.scrollback.retainedHistoryRows, 3)
        XCTAssertLessThanOrEqual(view.scrollback.retainedHistoryBytes, 24)
        XCTAssertTrue(view.scrollback.historyEvicted)
        XCTAssertTrue(native.historyNotice.contains("evicted"))
        XCTAssertFalse(try native.adapter.read(.retainedText).contains("row 0\n"))
        native.adapter.receive(Data((String(repeating: "漢", count: 10) + "\r\nlast\r\n").utf8))
        XCTAssertLessThanOrEqual(view.scrollback.retainedHistoryBytes, 24)
        XCTAssertFalse(try native.adapter.read(.retainedText).contains(String(repeating: "漢", count: 10)))
        XCTAssertTrue(try native.adapter.read(.retainedText).contains("last"))
    }

    @MainActor
    func testS013_UT02_unicodeSearchNavigatesMatches() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        native.adapter.receive(Data("first e\u{301}漢字 👩‍💻\r\nsecond e\u{301}漢字 👩‍💻".utf8))
        native.searchQuery = "e\u{301}漢字"
        XCTAssertTrue(native.findInPane(reset: true))
        XCTAssertEqual(view.accessibilitySelectedText(), native.searchQuery)
        let first = view.accessibilitySelectedTextRange()
        XCTAssertNotEqual(first.location, NSNotFound)
        XCTAssertTrue(native.findInPane())
        let second = view.accessibilitySelectedTextRange()
        XCTAssertGreaterThan(second.location, first.location)
        XCTAssertEqual(view.accessibilitySelectedText(), native.searchQuery)
        XCTAssertTrue(native.findInPane(forward: false))
        XCTAssertEqual(view.accessibilitySelectedTextRange(), first)
        native.searchQuery = "👩‍💻"
        XCTAssertTrue(native.findInPane(reset: true))
        XCTAssertEqual(view.accessibilitySelectedText(), "👩‍💻")
    }

    @MainActor
    func testS013_UT03_searchIsPaneLocalAndAlternateScreenDoesNotMix() throws {
        _ = NSApplication.shared
        let a = NativeTerminal(), b = NativeTerminal()
        defer { a.adapter.detach(); b.adapter.detach() }
        let first = try XCTUnwrap(a.view as? AccessibleTerminalView)
        let second = try XCTUnwrap(b.view as? AccessibleTerminalView)
        a.adapter.receive(Data("ONLY_A common".utf8)); b.adapter.receive(Data("ONLY_B common".utf8))
        a.searchQuery = "common"
        XCTAssertTrue(a.findInPane(reset: true))
        XCTAssertTrue(first.selection.active)
        XCTAssertFalse(second.selection.active)
        b.searchQuery = "ONLY_A"
        XCTAssertFalse(b.findInPane(reset: true))
        a.adapter.receive(Data("\u{1b}[?1049h\u{1b}[H\u{1b}[2JALTERNATE".utf8))
        a.searchQuery = "ONLY_A"
        XCTAssertFalse(a.findInPane(reset: true))
        a.searchQuery = "ALTERNATE"
        XCTAssertTrue(a.findInPane(reset: true))
        XCTAssertTrue(a.historyNotice.contains("Current screen"))
        a.adapter.receive(Data("\u{1b}[?1049l".utf8))
        a.searchQuery = "ONLY_A"
        XCTAssertTrue(a.findInPane(reset: true))
        a.searchQuery = "ALTERNATE"
        XCTAssertFalse(a.findInPane(reset: true))
    }

    @MainActor
    func testS013_UT04_evictionInvalidatesOldMatch() throws {
        _ = NSApplication.shared
        let native = NativeTerminal(scrollbackBudget: ScrollbackBudget(lineLimit: 2, byteLimit: 64))
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        view.getTerminal().resize(cols: 40, rows: 2)
        native.adapter.receive(Data("OLD_MATCH\r\n".utf8))
        native.showSearch()
        native.searchQuery = "OLD_MATCH"
        XCTAssertTrue(native.findInPane(reset: true))
        native.adapter.receive(Data((0..<15).map { "fresh \($0)\r\n" }.joined().utf8))
        XCTAssertFalse(view.selection.active)
        XCTAssertTrue(native.searchStatus.contains("search again"))
        XCTAssertFalse(native.findInPane())
        XCTAssertEqual(view.accessibilitySelectedText(), "")
        XCTAssertTrue(native.searchStatus.contains("evicted"))
    }

    @MainActor
    func testSearchIncludesLastColumnAndSoftWrappedUnicode() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        view.getTerminal().resize(cols: 10, rows: 2)
        native.adapter.receive(Data("123456789Xabcdefghij".utf8))
        native.searchQuery = "X"
        XCTAssertTrue(native.findInPane(reset: true))
        XCTAssertEqual(view.accessibilitySelectedText(), "X")
        native.searchQuery = "j"
        XCTAssertTrue(native.findInPane(reset: true))
        XCTAssertEqual(view.accessibilitySelectedText(), "j")
        native.searchQuery = "9Xabc"
        XCTAssertTrue(native.findInPane(reset: true))
        XCTAssertEqual(view.accessibilitySelectedText(), "9Xabc")
        native.adapter.receive(Data("\r\n1234567e\u{301}漢字👩‍💻".utf8))
        native.searchQuery = "e\u{301}漢字👩‍💻"
        XCTAssertTrue(native.findInPane(reset: true))
        XCTAssertEqual(view.accessibilitySelectedText(), native.searchQuery)
    }

    @MainActor
    func testManySmallReadsRetainNewestHistoryAcrossEngineAndByteEviction() throws {
        _ = NSApplication.shared
        let native = NativeTerminal(scrollbackBudget: ScrollbackBudget(lineLimit: 10_000, byteLimit: 70_000))
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        view.getTerminal().resize(cols: 40, rows: 3)
        let start = ContinuousClock.now
        for index in 0..<12_000 {
            native.adapter.receive(Data("line \(index)\r\n".utf8))
        }
        print("S013 12000 individually delivered rows: \(start.duration(to: .now))")
        XCTAssertLessThanOrEqual(view.scrollback.retainedHistoryRows, 10_000)
        XCTAssertLessThanOrEqual(view.scrollback.retainedHistoryBytes, 70_000)
        var count = 0, bytes = 0
        while let line = view.getTerminal().bufferLine(atRow: count + 3) {
            _ = line
            let row = try XCTUnwrap(view.getTerminal().bufferLine(atRow: count))
            let text = view.getTerminal().getText(start: Position(col: 0, row: count),
                                               end: Position(col: row.getTrimmedLength(), row: count))
            bytes += text.utf8.count + 1
            count += 1
        }
        XCTAssertEqual(count, view.scrollback.retainedHistoryRows)
        XCTAssertEqual(bytes, view.scrollback.retainedHistoryBytes)
        native.searchQuery = "line 11999"
        XCTAssertTrue(native.findInPane(reset: true))
        XCTAssertEqual(view.accessibilitySelectedText(), "line 11999")
        native.closeSearch()
        native.showSearch()
        XCTAssertFalse(native.searchStatus.contains("Match found"))
        XCTAssertFalse(view.selection.active)
    }

    @MainActor
    func testHistoryCapacityRecoversAfterBytePressureEases() throws {
        _ = NSApplication.shared
        let native = NativeTerminal(scrollbackBudget: ScrollbackBudget(lineLimit: 100, byteLimit: 200))
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        view.getTerminal().resize(cols: 40, rows: 2)
        for _ in 0..<40 { native.adapter.receive(Data("abcdefghijklmnopqrs\r\n".utf8)) }
        let constrained = view.scrollback.retainedHistoryRows
        XCTAssertLessThanOrEqual(constrained, 10)
        for _ in 0..<60 { native.adapter.receive(Data("x\r\n".utf8)) }
        XCTAssertGreaterThan(view.scrollback.retainedHistoryRows, constrained)
        XCTAssertLessThanOrEqual(view.scrollback.retainedHistoryBytes, 200)
        // A reflow invalidates the incremental row cache and recomputes costs.
        view.getTerminal().resize(cols: 20, rows: 3)
        view.scrollback.enforce(on: view)
        XCTAssertLessThanOrEqual(view.scrollback.retainedHistoryBytes, 200)
        XCTAssertLessThanOrEqual(view.scrollback.retainedHistoryRows, 100)
    }

    @MainActor
    func testChunkedParsingPreservesUTF8AndControlSequenceOrder() throws {
        _ = NSApplication.shared
        let whole = NativeTerminal(), fragmented = NativeTerminal()
        defer { whole.adapter.detach(); fragmented.adapter.detach() }
        let bytes = Data("\u{1b}[32mcafé 漢字 👩‍💻\u{1b}[0m\r\nsecond\rEDIT\u{1b}[K\r\n\u{1b}[?1049hALT\u{1b}[?1049lTAIL".utf8)
        whole.adapter.receive(bytes)
        for byte in bytes { fragmented.adapter.receive(Data([byte])) }
        XCTAssertEqual(try fragmented.adapter.read(.retainedText), try whole.adapter.read(.retainedText))
        XCTAssertTrue(try whole.adapter.read(.retainedText).contains("café 漢字 👩‍💻"))
        XCTAssertTrue(try whole.adapter.read(.retainedText).contains("EDIT"))
        XCTAssertFalse(try whole.adapter.read(.retainedText).contains("ALT"))
    }
}
