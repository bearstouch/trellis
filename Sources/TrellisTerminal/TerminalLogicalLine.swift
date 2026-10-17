import SwiftTerm
import TrellisCore

/// The soft-wrapped line around a buffer row as text, with one cell per
/// grapheme so a smart-selection match maps back to columns (FR-C06). Cells
/// follow `PaneTextSearch`: wide-character continuations are skipped and
/// empty cells read as spaces.
@MainActor
struct TerminalLogicalLine {
    private struct Cell { let row: Int; let col: Int; let width: Int }
    let text: String
    private let cells: [Cell]
    private let cols: Int

    /// Bounded so a huge wrapped line can't stall a double-click.
    init?(terminal: Terminal, row: Int, maxRows: Int = 32) {
        guard terminal.bufferLine(atRow: row) != nil else { return nil }
        var first = row, last = row
        while first > row - maxRows, first > 0, terminal.bufferLine(atRow: first)?.isWrapped == true { first -= 1 }
        while last < row + maxRows, terminal.bufferLine(atRow: last + 1)?.isWrapped == true { last += 1 }
        var text = "", cells: [Cell] = []
        for index in first...last {
            guard let line = terminal.bufferLine(atRow: index) else { break }
            let next = terminal.bufferLine(atRow: index + 1)
            let wraps = index < last
            var length = wraps ? terminal.cols : line.getTrimmedLength()
            if wraps, length > 0, terminal.getCharacter(for: line[length - 1]) == "\0", line[length - 1].width <= 1, next?[0].width == 2 { length -= 1 }
            for col in 0..<min(length, terminal.cols) {
                let character = terminal.getCharacter(for: line[col])
                if character == "\0", col > 0, line[col - 1].width == 2 { continue }
                text.append(character == "\0" ? " " : character)
                cells.append(Cell(row: index, col: col, width: max(1, Int(line[col].width))))
            }
        }
        // Appending can merge a combining mark into the previous cell's character.
        guard text.count == cells.count else { return nil }
        self.text = text; self.cells = cells; cols = terminal.cols
    }

    /// The grapheme offset of a cell; a wide character's continuation maps to its base.
    func offset(for position: Position) -> Int? {
        cells.lastIndex { $0.row == position.row && $0.col <= position.col && position.col < $0.col + $0.width }
    }

    /// A half-open cell range for graphemes `range`; the end may be `cols`.
    func positions(for range: Range<Int>) -> (start: Position, end: Position)? {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= cells.count else { return nil }
        let first = cells[range.lowerBound], last = cells[range.upperBound - 1]
        return (Position(col: first.col, row: first.row), Position(col: min(cols, last.col + last.width), row: last.row))
    }

    /// The smart-selection range for a clicked cell, or nil for plain word selection.
    static func smartSelection(in terminal: Terminal, at position: Position) -> (start: Position, end: Position)? {
        guard let line = TerminalLogicalLine(terminal: terminal, row: position.row), let offset = line.offset(for: position),
            let match = SmartSelection.match(in: line.text, at: offset)
        else { return nil }
        return line.positions(for: match.range)
    }
}
