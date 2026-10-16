import XCTest
@testable import TrellisCore

final class OutputJournalTests: XCTestCase {
    func testS025_UT01_cursorEvictionReportsGap() throws {
        var journal = OutputJournal(budget: 100)
        let a = UUID(), b = UUID()
        journal.append(Data(repeating: 0x41, count: 60), session: a)
        journal.append(Data(repeating: 0x42, count: 60), session: b)
        // The oldest chunk (session A) was evicted to respect the global budget.
        XCTAssertEqual(journal.retainedBytes, 60)
        let evicted = try journal.read(session: a, from: 10, maxBytes: 1_000)
        XCTAssertTrue(evicted.gap)
        XCTAssertEqual(evicted.start, 60)
        XCTAssertEqual(evicted.next, 60)
        XCTAssertEqual(evicted.data, Data())
        journal.append(Data("abc".utf8), session: a)
        let resumed = try journal.read(session: a, from: evicted.next, maxBytes: 1_000)
        XCTAssertFalse(resumed.gap)
        XCTAssertEqual(resumed.data, Data("abc".utf8))
        XCTAssertEqual(resumed.next, 63)
        XCTAssertThrowsError(try journal.read(session: a, from: 64, maxBytes: 10)) { XCTAssertEqual($0 as? OutputJournal.ReadError, .offsetBeyondEnd) }
        XCTAssertThrowsError(try journal.read(session: UUID(), from: nil, maxBytes: 10)) { XCTAssertEqual($0 as? OutputJournal.ReadError, .unknownSession) }
        journal.remove(session: b)
        XCTAssertEqual(journal.retainedBytes, 3)
        XCTAssertFalse(journal.contains(session: b))
        journal.append(Data(repeating: 0x43, count: 99), session: a)
        XCTAssertLessThanOrEqual(journal.retainedBytes, 100, "Eviction stays aligned after removing a session")
    }

    func testS025_UT02_readLimitsAndBinaryBoundaries() throws {
        var journal = OutputJournal()
        let session = UUID()
        let bytes: [UInt8] = [0xC3] + [0xA9, 0x00, 0xFF, 0x1B, 0x5B] + Array(repeating: 0x7A, count: 70_000)
        journal.append(Data(bytes.prefix(1)), session: session)  // first half of "é"
        journal.append(Data(bytes.dropFirst()), session: session)
        let first = try journal.read(session: session, from: nil, maxBytes: 65_536)
        XCTAssertEqual(first.data.count, 65_536)
        XCTAssertTrue(first.truncated)
        XCTAssertEqual(Array(first.data.prefix(6)), [0xC3, 0xA9, 0x00, 0xFF, 0x1B, 0x5B], "Raw bytes, including split UTF-8, are exact")
        let rest = try journal.read(session: session, from: first.next, maxBytes: 262_144)
        XCTAssertFalse(rest.truncated)
        XCTAssertEqual(first.data + rest.data, Data(bytes))
        let tiny = try journal.read(session: session, from: 1, maxBytes: 1)
        XCTAssertEqual(Array(tiny.data), [0xA9])
        XCTAssertFalse(tiny.gap)
    }

    func testSmallReadsCoalesceAndEvictOldestFirstWithinBudget() throws {
        var journal = OutputJournal(budget: 40_000)
        let a = UUID(), b = UUID()
        var expected = Data()
        // Byte-at-a-time output must not create per-byte chunks or copy on every eviction.
        for index in 0..<200_000 {
            let byte = Data([UInt8(truncatingIfNeeded: index)])
            journal.append(byte, session: index % 2 == 0 ? a : b)
            if index % 2 == 0 { expected.append(byte) }
            XCTAssertLessThanOrEqual(journal.retainedBytes, 40_000)
        }
        XCTAssertEqual(journal.end(session: a), 100_000)
        let read = try journal.read(session: a, from: 0, maxBytes: 262_144)
        XCTAssertTrue(read.gap)
        XCTAssertFalse(read.truncated)
        XCTAssertGreaterThan(read.data.count, 0)
        XCTAssertEqual(read.next, 100_000)
        XCTAssertEqual(read.data, expected.suffix(read.data.count), "Retained bytes are exactly the newest tail")
        journal.remove(session: a)
        XCTAssertEqual(journal.retainedBytes, Int(journal.end(session: b) - (try journal.read(session: b, from: nil, maxBytes: 1).start)))
    }

    func testWorkspaceDiffEventsAreOrderedAndRedacted() async throws {
        let store = try WorkspaceStore()
        var events: [WorkspaceEvent] = []
        let empty = await store.snapshot()
        let created = try await store.execute(.createWindow(name: "A")).snapshot
        events += WorkspaceEvents.diff(empty, created)
        let pane = try XCTUnwrap(created.panes.keys.first)
        let split = try await store.execute(.splitPane(id: pane, axis: .x, availableSize: try TerminalSize(columns: 120, rows: 40))).snapshot
        events += WorkspaceEvents.diff(created, split)
        XCTAssertEqual(events.map(\.type), ["window.created", "tab.created", "pane.created", "selection.window", "tab.layoutChanged", "pane.created", "selection.pane"])
        XCTAssertTrue(events.allSatisfy { $0.windowID != nil })
        XCTAssertTrue(events.allSatisfy { !$0.data.keys.contains("executable") && !$0.data.keys.contains("directory") })
        XCTAssertEqual(WorkspaceEvents.diff(WorkspaceSnapshot(), WorkspaceSnapshot()), [])
    }
}
