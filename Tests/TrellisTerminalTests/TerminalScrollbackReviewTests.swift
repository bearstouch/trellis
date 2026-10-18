import AppKit
import SwiftTerm
import TrellisCore
import XCTest
@testable import TrellisTerminal

@MainActor
final class TerminalScrollbackReviewTests: XCTestCase {
    /// The byte cost before `Terminal.utf8Count(for:)`: build each cell's `Character` and count its UTF-8.
    private func characterByteCost(_ line: BufferLine, terminal: Terminal) -> Int {
        var bytes = 1, col = 0
        let end = line.getTrimmedLength()
        while col < end {
            let character = terminal.getCharacter(for: line[col])
            if character == "\0" && col > 0 && line[col - 1].width == 2 { col += 1; continue }
            bytes += character == "\0" ? 1 : String(character).utf8.count
            col += 1
        }
        return bytes
    }

    func testHistoryBytesMatchCharacterCountsForMixedText() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let terminal = view.getTerminal()
        terminal.resize(cols: 20, rows: 3)
        let rows = [
            "plain ascii", "漢字かな wide cells", "e\u{301} combining a\u{308}\u{332}", "👨‍👩‍👧 zwj 🇵🇹 flag 👋🏽",
            "gap\u{1b}[5Cafter", "abcdefghijklmnopqrs漢 wraps", "\u{1b}[31mred\u{1b}[0m sgr", "", "tab\tstop", "\u{7f}del ✓→"
        ]
        native.adapter.receive(Data((rows + (0..<5).map { "pad \($0)" }).map { $0 + "\r\n" }.joined().utf8))
        let retained = view.scrollback.retainedHistoryRows
        XCTAssertGreaterThan(retained, rows.count)
        var expected = 0
        for row in 0..<retained { expected += characterByteCost(try XCTUnwrap(terminal.bufferLine(atRow: row)), terminal: terminal) }
        XCTAssertEqual(view.scrollback.retainedHistoryBytes, expected)
    }

    /// Once full, the engine recycles evicted rows in place; it frees them only when its capacity shrinks.
    func testRowsDroppedUnderBytePressureAreReleased() throws {
        _ = NSApplication.shared
        let native = NativeTerminal(scrollbackBudget: ScrollbackBudget(lineLimit: 100, byteLimit: 200))
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        view.getTerminal().resize(cols: 40, rows: 5)
        native.adapter.receive(Data("oldest row\r\n".utf8))
        native.adapter.receive(Data((0..<5).map { "warm \($0)\r\n" }.joined().utf8))
        weak var oldest = view.getTerminal().bufferLine(atRow: 0)
        XCTAssertNotNil(oldest)
        native.adapter.receive(Data((0..<40).map { "row \($0) " + String(repeating: "x", count: 20) + "\r\n" }.joined().utf8))
        XCTAssertTrue(view.scrollback.historyEvicted)
        XCTAssertNil(oldest, "The scrollback cache must not keep rows the engine dropped")
    }
}
