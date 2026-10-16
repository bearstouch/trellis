import SwiftTerm

/// Map rendered graphemes through row offsets, not UTF-16 or one position object
/// per cell. Use dragExtend to avoid SwiftTerm's inclusive-end selection clamp.
@MainActor
final class PaneTextSearch {
    private struct RowOffset { let row: Int; let offset: Int; let count: Int }
    private var previous: (start: Position, end: Position)?
    func reset() { previous = nil }

    func find(_ query: String, forward: Bool, in view: AccessibleTerminalView) -> Bool {
        let terminal = view.getTerminal()
        var row = 0
        var first: (Position, Position)?, last: (Position, Position)?, chosen: (Position, Position)?
        while terminal.bufferLine(atRow: row) != nil {
            var text = "", offsets: [RowOffset] = [], characterCount = 0
            repeat {
                guard let current = terminal.bufferLine(atRow: row) else { break }
                let next = terminal.bufferLine(atRow: row + 1)
                let wraps = next?.isWrapped == true
                var length = wraps ? terminal.cols : current.getTrimmedLength()
                if wraps, length > 0, terminal.getCharacter(for: current[length - 1]) == "\0",
                   current[length - 1].width <= 1, next?[0].width == 2 { length -= 1 }
                let start = characterCount
                for col in 0..<length {
                    let character = terminal.getCharacter(for: current[col])
                    if character == "\0", col > 0, current[col - 1].width == 2 { continue }
                    text.append(character == "\0" ? " " : character)
                    characterCount += 1
                }
                offsets.append(RowOffset(row: row, offset: start, count: characterCount - start))
                row += 1
                if !wraps { break }
            } while terminal.bufferLine(atRow: row) != nil

            func anchorOffset(_ position: Position) -> Int {
                guard let entry = offsets.first(where: { $0.row == position.row }),
                      let line = terminal.bufferLine(atRow: position.row) else {
                    return position.row < (offsets.first?.row ?? row) ? -1 : Int.max
                }
                var count = 0
                for col in 0..<min(position.col, terminal.cols) {
                    let character = terminal.getCharacter(for: line[col])
                    if character == "\0", col > 0, line[col - 1].width == 2 { continue }
                    count += 1
                }
                return entry.offset + count
            }
            func position(_ offset: Int, end: Bool) -> Position {
                // An exclusive end at a wrap boundary belongs to the preceding
                // row at col=cols, including at the bottom-right screen cell.
                let target = end ? offset - 1 : offset
                let entry = offsets.last(where: { target >= $0.offset && target < $0.offset + $0.count })!
                let line = terminal.bufferLine(atRow: entry.row)!
                var count = entry.offset
                for col in 0..<terminal.cols {
                    let cell = line[col], character = terminal.getCharacter(for: cell)
                    if character == "\0", col > 0, line[col - 1].width == 2 { continue }
                    if count == target {
                        return Position(col: end ? min(terminal.cols, col + max(1, Int(cell.width))) : col, row: entry.row)
                    }
                    count += 1
                }
                return Position(col: terminal.cols, row: entry.row)
            }
            func resolve(_ match: (Int, Int)) -> (Position, Position) {
                (position(match.0, end: false), position(match.1, end: true))
            }
            let anchor = previous.map { anchorOffset(forward ? $0.end : $0.start) }
            var localFirst: (Int, Int)?, localLast: (Int, Int)?, localChosen: (Int, Int)?
            var cursor = text.startIndex, offset = 0
            while cursor < text.endIndex,
                  let range = text.range(of: query, options: [.caseInsensitive], range: cursor..<text.endIndex) {
                offset += text.distance(from: cursor, to: range.lowerBound)
                let count = text.distance(from: range.lowerBound, to: range.upperBound)
                guard count > 0, offset + count <= characterCount else { break }
                let match = (offset, offset + count)
                if localFirst == nil { localFirst = match }
                localLast = match
                if forward {
                    if localChosen == nil, anchor == nil || match.0 >= anchor! { localChosen = match }
                } else if anchor == nil || match.1 <= anchor! { localChosen = match }
                offset += count
                cursor = range.upperBound
            }
            if first == nil, let localFirst { first = resolve(localFirst) }
            if let localLast { last = resolve(localLast) }
            if let localChosen, !forward || chosen == nil { chosen = resolve(localChosen) }
            if forward, chosen != nil { break }
        }
        guard let match = chosen ?? (forward ? first : last) else {
            previous = nil
            view.selection.selectNone()
            return false
        }
        previous = (match.0, match.1)
        view.selection.setSoftStart(bufferPosition: match.0)
        view.selection.startSelection()
        view.selection.dragExtend(bufferPosition: match.1)
        if !terminal.isCurrentBufferAlternate { view.scrollTo(row: max(0, match.0.row - terminal.rows / 2)) }
        return true
    }
}
