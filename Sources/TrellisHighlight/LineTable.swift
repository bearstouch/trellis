import Foundation

/// UTF-16 offsets where each line starts, kept up to date edit by edit so tree-sitter's row/column points never need
/// a rescan of the whole buffer (a 2 MiB file has ~40,000 lines).
struct LineTable: Equatable {
    private(set) var starts: [Int] = [0]

    init(_ text: NSString = "") { rebuild(text) }

    mutating func rebuild(_ text: NSString) {
        starts = [0]
        let length = text.length
        guard length > 0 else { return }
        var buffer = [unichar](repeating: 0, count: min(length, 65_536))
        var offset = 0
        while offset < length {
            let count = min(buffer.count, length - offset)
            text.getCharacters(&buffer, range: NSRange(location: offset, length: count))
            for i in 0..<count where buffer[i] == 10 { starts.append(offset + i + 1) }
            offset += count
        }
    }

    /// Applies an edit: `range` is the edited range in the new text, `delta` the change in length.
    mutating func apply(editedRange range: NSRange, delta: Int, in text: NSString) {
        let oldEnd = NSMaxRange(range) - delta
        let first = index(after: range.location)
        var last = first
        while last < starts.count, starts[last] <= oldEnd { last += 1 }
        var inserted: [Int] = []
        if range.length > 0 {
            var buffer = [unichar](repeating: 0, count: range.length)
            text.getCharacters(&buffer, range: range)
            for (i, unit) in buffer.enumerated() where unit == 10 { inserted.append(range.location + i + 1) }
        }
        let shifted = starts[last...].map { $0 + delta }
        starts = Array(starts[..<first]) + inserted + shifted
    }

    /// The index of the first line start greater than `offset`.
    private func index(after offset: Int) -> Int {
        var lo = 0, hi = starts.count
        while lo < hi { let mid = (lo + hi) / 2; if starts[mid] <= offset { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    /// Row and UTF-16 column of `offset`.
    func location(of offset: Int) -> (row: Int, column: Int) {
        let row = max(0, index(after: offset) - 1)
        return (row, offset - starts[row])
    }
}
