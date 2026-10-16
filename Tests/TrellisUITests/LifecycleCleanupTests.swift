import AppKit
import Darwin
import XCTest
import TrellisControl
import TrellisCore
@testable import TrellisUI

final class LifecycleCleanupTests: XCTestCase {
    private func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    private func childProcesses() -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 4096)
        let bytes = proc_listchildpids(getpid(), &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        return Array(buffer.prefix(max(0, Int(bytes))))
    }

    @MainActor
    func testS031_UT03_repeatedCleanupReturnsToBaseline() async throws {
        let h = try Harness()
        try await h.grant("full")
        defer { h.discardPreferences() }
        // Warm up once so lazily created runtime resources are not counted as leaks.
        _ = try await cycle(h, index: -1)
        let baselineDescriptors = openDescriptors()
        let baselineChildren = Set(childProcesses())
        var spawned: Set<pid_t> = []
        for index in 0..<100 { spawned.formUnion(try await cycle(h, index: index)) }
        XCTAssertEqual(spawned.count, 90, "Every live cycle started its own child")
        // A reparented (orphaned) child no longer shows up as ours, so check each spawned PID directly.
        func alive() -> [pid_t] { spawned.filter { kill($0, 0) == 0 || errno != ESRCH } }
        // Reaping is asynchronous; allow the last exits to be collected.
        let deadline = Date().addingTimeInterval(5)
        while !Set(childProcesses()).subtracting(baselineChildren).isEmpty || openDescriptors() > baselineDescriptors || !alive().isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(Set(childProcesses()).subtracting(baselineChildren), [], "No unreaped children remain")
        XCTAssertEqual(alive(), [], "No spawned process survives as an orphan")
        XCTAssertLessThanOrEqual(openDescriptors(), baselineDescriptors, "Descriptor count returned to baseline")
        XCTAssertTrue(h.model.terminals.isEmpty, "No terminal or PTY objects are retained")
        XCTAssertTrue(h.model.snapshot.windows.isEmpty)
        XCTAssertFalse(h.model.outputJournal.retainedBytes > 0, "Closed sessions keep no output")
    }

    /// One live session (or a failed launch every tenth cycle), then a full close.
    @MainActor
    private func cycle(_ h: Harness, index: Int) async throws -> Set<pid_t> {
        let window: String = try await h.value("windowId", "window.create", ["name": "Cycle \(index)"])
        let pane = try XCTUnwrap(h.model.presentation.activePane?.id)
        let launch: [String: Any] =
            index % 10 == 9
            ? ["kind": "process", "executable": "/nonexistent/tool", "directory": "/tmp"]
            : ["kind": "process", "executable": "/bin/sh", "arguments": ["-c", "printf ready; exec /bin/sleep 30"], "directory": "/tmp"]
        let before = Set(childProcesses())
        let started = try await h.call("session.start", ["paneId": pane.uuidString, "launch": launch])
        var live: Set<pid_t> = []
        if index % 10 != 9 {
            // The close below must tear down a live child, or the cycle proves nothing.
            XCTAssertNotNil(started["result"], "cycle \(index): \(started)")
            let deadline = Date().addingTimeInterval(2)
            while Set(childProcesses()).subtracting(before).isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            live = Set(childProcesses()).subtracting(before)
            XCTAssertFalse(live.isEmpty, "cycle \(index): a live child exists before closing")
        }
        let closed = try await h.call("window.close", ["id": window, "allowRunning": true])
        XCTAssertNotNil(closed["result"], "cycle \(index): \(closed)")
        return live
    }
}
