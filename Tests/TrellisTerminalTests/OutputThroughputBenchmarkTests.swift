import AppKit
import Darwin
import SwiftTerm
import XCTest
@testable import TrellisTerminal

/// Throughput benchmarks; opt-in with TRELLIS_BENCH=1 so the normal suite stays fast.
@MainActor
final class OutputThroughputBenchmarkTests: XCTestCase {
    static let megabytes = Int(ProcessInfo.processInfo.environment["TRELLIS_BENCH_MB"] ?? "") ?? 24

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TRELLIS_BENCH"] == "1", "set TRELLIS_BENCH=1")
    }

    private var directory: URL?

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    enum Workload: String, CaseIterable {
        case plain, sgr, unicode
        static var selected: [Workload] {
            guard let names = ProcessInfo.processInfo.environment["TRELLIS_BENCH_WORKLOADS"] else { return allCases }
            return names.split(separator: ",").compactMap { Workload(rawValue: String($0)) }
        }
    }

    static func payload(_ workload: Workload) -> Data {
        var line: String
        switch workload {
        case .plain: line = "The quick brown fox jumps over the lazy dog 0123456789 abcdefghijklmnopqrstuv\r\n"
        case .sgr: line = "\u{1b}[1;32mok\u{1b}[0m \u{1b}[34msrc/module/file.swift\u{1b}[0m:\u{1b}[33m42\u{1b}[0m: \u{1b}[38;5;208mwarning\u{1b}[0m unused \u{1b}[4mvalue\u{1b}[24m\r\n"
        case .unicode: line = "café naïve 漢字かな交じり文 привет мир 👋🏽 → ✓ αβγ δεζ ηθι κλμ νξο\r\n"
        }
        let unit = Data(line.utf8)
        var data = Data(capacity: megabytes << 20)
        while data.count < megabytes << 20 { data.append(unit) }
        return data
    }

    func file(_ workload: Workload) throws -> URL {
        let directory =
            try self.directory
            ?? FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: FileManager.default.temporaryDirectory, create: true)
        self.directory = directory
        let url = directory.appendingPathComponent("\(workload.rawValue).txt")
        if !FileManager.default.fileExists(atPath: url.path) { try Self.payload(workload).write(to: url) }
        return url
    }

    static func mainThreadCPU(_ port: mach_port_t) -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
    }

    static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    /// Samples how long a block posted to the main queue waits, every 10 ms, from a background thread.
    final class MainLatencyProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Double] = []
        private var running = true

        func start() {
            Thread.detachNewThread { [self] in
                while lock.withLock({ running }) {
                    let semaphore = DispatchSemaphore(value: 0)
                    let posted = DispatchTime.now().uptimeNanoseconds
                    DispatchQueue.main.async { semaphore.signal() }
                    semaphore.wait()
                    let waited = Double(DispatchTime.now().uptimeNanoseconds - posted) / 1e6
                    lock.withLock { samples.append(waited) }
                    usleep(10_000)
                }
            }
        }

        func stop() -> (p50: Double, p99: Double, max: Double) {
            let sorted = lock.withLock {
                running = false; return samples.sorted()
            }
            guard !sorted.isEmpty else { return (0, 0, 0) }
            func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
            return (at(0.5), at(0.99), sorted.last!)
        }
    }

    func report(_ name: String, _ fields: [(String, String)]) {
        print("BENCH \(name) " + fields.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
    }

    /// Engine parse only: no view, no Trellis callbacks.
    func testParserOnlyThroughput() throws {
        for workload in Workload.selected {
            let data = [UInt8](Self.payload(workload))
            let headless = HeadlessTerminal(options: TerminalOptions(cols: 120, rows: 40, scrollback: 10_000)) { _ in }
            let start = DispatchTime.now().uptimeNanoseconds
            var offset = 0
            while offset < data.count {
                let end = min(offset + 16_384, data.count)
                headless.terminal.feed(buffer: data[offset..<end])
                offset = end
            }
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            report("parser-only/\(workload.rawValue)", [("MBps", String(format: "%.1f", Double(data.count) / 1_048_576 / seconds))])
        }
    }

    /// Real PTY → NativeTerminal → visible window, `cat` of a file, until exit and drain.
    func testEndToEndCatThroughput() async throws {
        _ = NSApplication.shared
        let runs = max(1, Int(ProcessInfo.processInfo.environment["TRELLIS_BENCH_RUNS"] ?? "") ?? 3)
        let mainPort = pthread_mach_thread_np(pthread_self())
        for workload in Workload.selected {
            let url = try file(workload)
            var rates: [Double] = []
            for _ in 0..<runs {
                let native = NativeTerminal()
                let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = native.view
                window.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(200))
                let exited = expectation(description: "cat exits")
                native.onExit = { _ in exited.fulfill() }
                let probe = MainLatencyProbe()
                let mainBefore = Self.mainThreadCPU(mainPort), processBefore = Self.processCPU()
                let start = DispatchTime.now().uptimeNanoseconds
                probe.start()
                native.start(arguments: ["-f", "-c", "stty raw -echo; exec /bin/cat \"$0\"", url.path])
                await fulfillment(of: [exited], timeout: 300)
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                let latency = probe.stop()
                let mainCPU = Self.mainThreadCPU(mainPort) - mainBefore, processCPU = Self.processCPU() - processBefore
                let rate = Double(Self.megabytes) / seconds
                rates.append(rate)
                report(
                    "e2e-cat/\(workload.rawValue)",
                    [
                        ("MBps", String(format: "%.1f", rate)), ("seconds", String(format: "%.2f", seconds)),
                        ("mainCPU", String(format: "%.2f", mainCPU)), ("processCPU", String(format: "%.2f", processCPU)),
                        ("mainWait_p50ms", String(format: "%.1f", latency.p50)), ("p99ms", String(format: "%.1f", latency.p99)),
                        ("maxms", String(format: "%.1f", latency.max))
                    ])
                window.contentView = nil
                window.close()
                native.adapter.detach()
            }
            report("e2e-cat-median/\(workload.rawValue)", [("MBps", String(format: "%.1f", rates.sorted()[rates.count / 2]))])
        }
    }
}
