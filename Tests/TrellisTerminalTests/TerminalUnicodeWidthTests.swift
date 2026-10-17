import AppKit
import XCTest
import SwiftTerm
import TrellisCore
@testable import TrellisTerminal

/// FR-TX04: emoji and other Unicode text take a fixed number of cells and stay one cluster.
final class TerminalUnicodeWidthTests: XCTestCase {
    @MainActor
    func testClustersHaveStableWidths() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let terminal = view.getTerminal()
        let cases: [(text: String, widths: [Int])] = [
            ("👨‍👩‍👧", [2]),  // ZWJ sequence
            ("❤️", [2]),  // VS16 emoji presentation
            ("❤", [1]),  // text-presentation default
            ("☺︎", [1]),  // VS15 text presentation
            ("🇵🇹", [2]),  // flag
            ("👍🏽", [2]),  // skin tone
            ("e\u{301}", [1]),  // combining mark
            ("漢字", [2, 2]),
            ("한", [2])
        ]
        for (row, item) in cases.enumerated() {
            native.adapter.receive(Data("\u{1b}[\(row + 1);1H\(item.text)".utf8))
            XCTAssertEqual(terminal.getCursorLocation().x, item.widths.reduce(0, +), "cursor advance for \(item.text)")
            var column = 0
            var clusters: [String] = []
            for width in item.widths {
                let cell = terminal.buffer.getChar(at: Position(col: column, row: row))
                XCTAssertEqual(Int(cell.width), width, "width of \(item.text) at \(column)")
                clusters.append(String(terminal.getCharacter(for: cell)))
                column += width
            }
            XCTAssertEqual(clusters.joined(), item.text, "\(item.text) is kept as whole clusters")
            if item.widths.allSatisfy({ $0 == 2 }) {
                // Wide cells get their own runs, so the first run spans exactly the cluster's cells.
                let first = view.renderedRowForTesting(row).first { $0.columns.contains(0) }
                XCTAssertEqual(first?.columns, 0..<column, "\(item.text) is drawn within its cells")
            }
        }
    }
}
