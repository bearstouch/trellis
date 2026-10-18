import SwiftTerm
import TrellisCore

@MainActor
final class TerminalScrollback {
    private struct CachedCost {
        // Strong, not weak: a weak reference gives every row a side table, which puts
        // all its retains and releases (the parser's too) on the slow path. Entries
        // behind `head` drop it, so rows the engine evicted are freed at once.
        var line: BufferLine?
        let generation: UInt64
        let bytes: Int
    }
    // A queue of immutable historical rows; parser edits affect the active
    // screen. Track engine trims to update only newly historical rows. Resize
    // and unexpected identities fall back to a full, generation-aware rebuild.
    private var history: [CachedCost] = []
    private var head = 0
    private var previousTrimmed = 0
    private var previousColumns = 0
    private var previousRows = 0
    private var engineCapacity: Int
    let budget: ScrollbackBudget
    private(set) var historyEvicted = false
    private(set) var retainedHistoryBytes = 0
    private(set) var retainedHistoryRows = 0

    init(budget: ScrollbackBudget, historyEvicted: Bool = false) {
        self.budget = budget; engineCapacity = budget.lineLimit; self.historyEvicted = historyEvicted
    }

    func enforce(on view: AccessibleTerminalView) {
        let terminal = view.getTerminal()
        guard !terminal.isCurrentBufferAlternate else { return }
        let trimmed = terminal.buffer.totalLinesTrimmed
        if trimmed > 0 { historyEvicted = true }
        // Public engine access exposes rows by index, not count. Find its end
        // in logarithmic probes instead of scanning 10,000 rows on every read.
        var lower = 0, upper = max(terminal.rows, 1)
        while terminal.bufferLine(atRow: upper) != nil { lower = upper + 1; upper *= 2 }
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if terminal.bufferLine(atRow: middle) != nil { lower = middle + 1 } else { upper = middle }
        }
        let count = max(0, lower - terminal.rows)
        let removed = trimmed - previousTrimmed
        let oldCount = history.count - head
        let survivors = oldCount - removed
        func matches(_ entry: CachedCost, row: Int) -> Bool {
            guard let line = terminal.bufferLine(atRow: row) else { return false }
            return entry.line === line && entry.generation == line.generation
        }
        let incremental =
            previousColumns == terminal.cols && previousRows == terminal.rows
            && removed >= 0 && removed <= oldCount && count >= survivors
            && (survivors == 0
                || (matches(history[head + removed], row: 0)
                    && matches(history[history.count - 1], row: survivors - 1)))
        if incremental {
            for index in head..<(head + removed) { retainedHistoryBytes -= history[index].bytes; history[index].line = nil }
            head += removed
        } else {
            history.removeAll(keepingCapacity: true)
            head = 0
            retainedHistoryBytes = 0
        }
        let begin = incremental ? survivors : 0
        for row in begin..<count {
            guard let line = terminal.bufferLine(atRow: row) else { break }
            let cost = byteCost(line, terminal: terminal)
            history.append(CachedCost(line: line, generation: line.generation, bytes: cost))
            retainedHistoryBytes += cost
        }
        var keep = history.count - head
        while keep > budget.lineLimit || retainedHistoryBytes > budget.byteLimit {
            retainedHistoryBytes -= history[head].bytes
            history[head].line = nil
            head += 1
            keep -= 1
        }
        retainedHistoryRows = keep
        if keep < count {
            historyEvicted = true
            view.clearSearch()
            // Hold the constrained capacity under sustained byte pressure.
            // Shrinking then re-expanding on every read reallocates the engine's
            // backing ring. Recover the full line budget once byte usage eases.
            view.changeScrollback(keep)
            engineCapacity = keep
        }
        if engineCapacity < budget.lineLimit, budget.byteLimit > 0,
            retainedHistoryBytes < budget.byteLimit - budget.byteLimit / 5
        {
            view.changeScrollback(budget.lineLimit)
            engineCapacity = budget.lineLimit
        }
        if head >= 1024 || head == history.count {
            history.removeFirst(head)
            head = 0
        }
        previousTrimmed = terminal.buffer.totalLinesTrimmed
        previousColumns = terminal.cols
        previousRows = terminal.rows
    }

    private func byteCost(_ line: BufferLine, terminal: Terminal) -> Int {
        var bytes = 1, col = 0
        let end = line.getTrimmedLength()
        while col < end {
            let length = terminal.utf8Count(for: line[col])
            if length == 0 && col > 0 && line[col - 1].width == 2 { col += 1; continue }
            let count = max(length, 1)
            if count > budget.byteLimit - min(bytes, budget.byteLimit) { return budget.byteLimit + 1 }
            bytes += count
            col += 1
        }
        return bytes
    }
}
