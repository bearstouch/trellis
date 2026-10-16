import XCTest
@testable import TrellisCore

/// Deterministic generator so failures replay from their seed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class QualificationTests: XCTestCase {
    func testS031_UT01_randomizedTreeOperationsKeepInvariants() async throws {
        for seed in [1, 7, 42, 2026] as [UInt64] {
            var random = SplitMix64(state: seed)
            let store = try WorkspaceStore()
            var everSeen: [UUID: String] = [:]
            for step in 0..<400 {
                let snapshot = await store.snapshot()
                let panes = Array(snapshot.panes.keys).sorted { $0.uuidString < $1.uuidString }
                let tabs = Array(snapshot.tabs.values).sorted { $0.id.uuidString < $1.id.uuidString }
                let command: WorkspaceCommand
                switch (Int.random(in: 0..<7, using: &random), panes.isEmpty) {
                case (0, _), (_, true): command = .createWindow(name: "W\(step)")
                case (1, _): command = .createTab(windowID: snapshot.windows.randomElement(using: &random)!.id)
                case (2, _), (3, _):
                    command = .splitPane(id: panes.randomElement(using: &random)!, axis: Bool.random(using: &random) ? .x : .y, availableSize: try TerminalSize(columns: 400, rows: 200))
                case (4, _): command = .deletePane(id: panes.randomElement(using: &random)!)
                case (5, _):
                    let window = snapshot.windows.randomElement(using: &random)!
                    command = .reorderTabs(windowID: window.id, ids: window.tabIDs.shuffled(using: &random))
                default:
                    let tab = tabs.randomElement(using: &random)!
                    guard case .split(let branch, _, _, _) = tab.root else { continue }
                    command = .resizeSplit(tabID: tab.id, splitID: branch, ratio: Double.random(in: 0.05...0.95, using: &random), canvas: CanvasDimensions(width: 4000, height: 3000))
                }
                // Rejected commands are fine; the state must stay valid either way.
                _ = try? await store.execute(command)
                let next = await store.snapshot()
                XCTAssertNoThrow(try next.validate(), "seed \(seed) step \(step)")
                // IDs are stable: a resource never changes kind, and IDs are unique across kinds.
                var kinds: [UUID: String] = [:]
                for window in next.windows { kinds[window.id] = "window" }
                for id in next.tabs.keys { XCTAssertNil(kinds.updateValue("tab", forKey: id)) }
                for id in next.panes.keys { XCTAssertNil(kinds.updateValue("pane", forKey: id)) }
                for id in next.sessions.keys { XCTAssertNil(kinds.updateValue("session", forKey: id)) }
                for (id, kind) in kinds {
                    if let previous = everSeen[id] { XCTAssertEqual(previous, kind, "seed \(seed): \(id) changed kind") }
                    everSeen[id] = kind
                }
                XCTAssertLessThanOrEqual(next.panes.count, 100)
            }
        }
    }

    func testS031_UT02_queuesRespectAllBudgets() async throws {
        // Output journal: a 64 MiB flood across sessions stays within budget, oldest first.
        var journal = OutputJournal()
        let sessions = (0..<4).map { _ in UUID() }
        let chunk = Data(repeating: 0x79, count: 16_384)
        for index in 0..<4_096 { journal.append(chunk, session: sessions[index % 4]) }
        XCTAssertLessThanOrEqual(journal.retainedBytes, OutputJournal.defaultBudget)
        for session in sessions {
            let read = try journal.read(session: session, from: 0, maxBytes: 1)
            XCTAssertTrue(read.gap, "Evicted output is reported, not silently skipped")
        }
        // Scrollback: lines and bytes are both bounded.
        let budget = ScrollbackBudget.standard
        XCTAssertEqual(budget.lineLimit, 10_000)
        XCTAssertLessThanOrEqual(budget.byteLimit, 16 * 1_048_576)
        // Persisted state over 4 MiB is refused before decoding (event ring and outbox budgets are covered in S025's hub tests).
        XCTAssertNil(try? WorkspaceSnapshotCodec.decode(Data(repeating: 0x20, count: 4_194_305)))
    }

    func testS031_UT04_measurementSummaryCalculatesP95() {
        let samples = (1...100).map(Double.init)
        XCTAssertEqual(MeasurementSummary.summarize(samples), .measured(p50: 50, p95: 95, max: 100, count: 100))
        XCTAssertEqual(MeasurementSummary.summarize(samples.reversed()), .measured(p50: 50, p95: 95, max: 100, count: 100), "Order does not matter")
        XCTAssertEqual(MeasurementSummary.summarize(Array(samples.prefix(19))), .insufficientSamples(count: 19, required: 20))
        XCTAssertEqual(MeasurementSummary.summarize([Double.nan] + Array(repeating: 1, count: 19)), .insufficientSamples(count: 19, required: 20), "Invalid samples do not count")
        let twenty = (1...20).map(Double.init)
        XCTAssertEqual(MeasurementSummary.summarize(twenty), .measured(p50: 10, p95: 19, max: 20, count: 20))
        XCTAssertNil(MeasurementSummary.meets(.insufficientSamples(count: 3, required: 20), p95AtMost: 50), "Insufficient data is never a pass")
        XCTAssertEqual(MeasurementSummary.meets(MeasurementSummary.summarize(samples), p95AtMost: 95), true)
        XCTAssertEqual(MeasurementSummary.meets(MeasurementSummary.summarize(samples), p95AtMost: 94), false)
    }
}
