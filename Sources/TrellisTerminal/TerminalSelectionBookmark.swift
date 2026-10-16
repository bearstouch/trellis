import Foundation
import SwiftTerm

/// Keep logical text offsets across font reflow, including wide and combining
/// characters. Metadata grows per row, rather than per terminal cell.
@MainActor
struct TerminalSelectionBookmark {
    private struct Row { let index: Int; let offset: Int; let length: Int }
    @MainActor private struct TextMap {
        var text = ""
        var rows: [Row] = []
        init(_ view: AccessibleTerminalView) {
            let terminal = view.getTerminal()
            var row = 0, offset = 0
            while let line = terminal.bufferLine(atRow: row) {
                let wraps = terminal.bufferLine(atRow: row + 1)?.isWrapped == true
                var length = wraps ? terminal.cols : line.getTrimmedLength()
                if wraps, length > 0, terminal.getCharacter(for: line[length - 1]) == "\0",
                   line[length - 1].width <= 1, terminal.bufferLine(atRow: row + 1)?[0].width == 2 { length -= 1 }
                var value = ""
                for col in 0..<length {
                    let character = terminal.getCharacter(for: line[col])
                    if character == "\0", col > 0, line[col - 1].width == 2 { continue }
                    value.append(character == "\0" ? " " : character)
                }
                rows.append(Row(index: row, offset: offset, length: value.utf16.count))
                text += value
                offset += value.utf16.count
                if !wraps { text += "\n"; offset += 1 }
                row += 1
            }
        }
        func offset(_ position: Position, view: AccessibleTerminalView) -> Int? {
            guard let row = rows.first(where: { $0.index == position.row }),
                  let line = view.getTerminal().bufferLine(atRow: position.row) else { return nil }
            var length = 0
            for col in 0..<min(position.col, view.getTerminal().cols) {
                let char = view.getTerminal().getCharacter(for: line[col])
                if char == "\0", col > 0, line[col - 1].width == 2 { continue }
                length += String(char == "\0" ? " " : char).utf16.count
            }
            return row.offset + min(length, row.length)
        }
        func position(_ offset: Int, end: Bool, view: AccessibleTerminalView) -> Position? {
            guard let row = rows.last(where: { end ? $0.offset < offset : $0.offset <= offset }),
                  let line = view.getTerminal().bufferLine(atRow: row.index) else { return nil }
            var count = row.offset
            for col in 0..<view.getTerminal().cols {
                let char = view.getTerminal().getCharacter(for: line[col])
                if char == "\0", col > 0, line[col - 1].width == 2 { continue }
                if count == offset { return Position(col: col, row: row.index) }
                count += String(char == "\0" ? " " : char).utf16.count
                if end, count == offset { return Position(col: min(view.getTerminal().cols, col + max(1, Int(line[col].width))), row: row.index) }
            }
            return Position(col: view.getTerminal().cols, row: row.index)
        }
    }
    private let selected: String
    private let originalText: String
    private let offset: Int
    init?(_ view: AccessibleTerminalView) {
        guard view.selection.active else { return nil }
        let map = TextMap(view)
        let a: Position, b: Position
        if view.selection.selectingRows {
            // The engine's row selection ends at cols-1, but Trellis's copy
            // contract includes the entire final cell of every selected row.
            a = Position(col: 0, row: min(view.selection.start.row, view.selection.end.row))
            b = Position(col: view.getTerminal().cols, row: max(view.selection.start.row, view.selection.end.row))
        } else {
            a = view.selection.start; b = view.selection.end
        }
        guard let first = map.offset(a, view: view), let last = map.offset(b, view: view), first != last else { return nil }
        originalText = map.text
        offset = min(first, last)
        selected = (map.text as NSString).substring(with: NSRange(location: offset, length: abs(first - last)))
    }
    func restore(in view: AccessibleTerminalView) {
        let map = TextMap(view), text = map.text as NSString
        // Font reflow preserves logical text; history eviction removes a
        // prefix. Ignore the variable number of blank screen rows when finding
        // that prefix, and never substitute a later duplicate for evicted text.
        let oldContent = String(originalText.reversed().drop(while: { $0 == "\n" }).reversed())
        let newContent = String(map.text.reversed().drop(while: { $0 == "\n" }).reversed())
        let oldLength = (oldContent as NSString).length
        let newLength = (newContent as NSString).length
        let selectedLength = (selected as NSString).length
        let shifted: Int
        if oldContent.hasSuffix(newContent) {
            shifted = offset - (oldLength - newLength)
        } else {
            // SwiftTerm may clip a live cursor row during resize. A selection
            // entirely in the unchanged prefix is still safe to restore.
            let prefixLength = zip(originalText.utf16, map.text.utf16).prefix(while: { $0 == $1 }).count
            guard offset + selectedLength <= prefixLength else {
                view.selection.selectNone(); return
            }
            shifted = offset
        }
        let chosen = NSRange(location: max(0, shifted), length: selectedLength)
        guard shifted >= 0, NSMaxRange(chosen) <= text.length,
              text.substring(with: chosen) == selected,
              let start = map.position(chosen.location, end: false, view: view),
              let end = map.position(NSMaxRange(chosen), end: true, view: view) else {
            view.selection.selectNone(); return
        }
        view.selection.setSoftStart(bufferPosition: start)
        view.selection.startSelection()
        view.selection.dragExtend(bufferPosition: end)
    }
}
