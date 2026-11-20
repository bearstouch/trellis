import Foundation
import XCTest

/// Temporary, to find where CI stalls: stdout is buffered there, so each test's start and end go to stderr with a time,
/// and if nothing starts or ends for 90 s, every thread's stack is sampled to stderr. Named to run first, so its class
/// setUp registers the observer before the other classes run.
final class AAATraceObserver: NSObject, XCTestObservation, @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var sampled = false

    override init() {
        super.init()
        Thread.detachNewThread { [self] in watch() }
    }

    private func write(_ text: String) { FileHandle.standardError.write(Data("TRACE \(Date()) \(text)\n".utf8)) }
    private func touch(_ text: String) {
        lock.withLock { last = Date() }
        write(text)
    }
    func testCaseWillStart(_ testCase: XCTestCase) { touch("start \(testCase.name)") }
    func testCaseDidFinish(_ testCase: XCTestCase) { touch("end \(testCase.name)") }

    private func watch() {
        while true {
            Thread.sleep(forTimeInterval: 5)
            let stalled = lock.withLock { !sampled && Date().timeIntervalSince(last) > 90 }
            guard stalled else { continue }
            lock.withLock { sampled = true }
            write("STALL: nothing for 90 s, sampling pid \(getpid())")
            let report = NSTemporaryDirectory() + "trellis-stall-\(getpid()).txt"
            let sample = Process()
            sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            sample.arguments = [String(getpid()), "3", "-mayDie", "-file", report]
            try? sample.run()
            sample.waitUntilExit()
            let text = (try? String(contentsOfFile: report, encoding: .utf8)) ?? "sample failed (status \(sample.terminationStatus))"
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) { FileHandle.standardError.write(Data("STACK \(line)\n".utf8)) }
            write("STALL: sample done")
        }
    }
}

final class AAATraceTests: XCTestCase {
    nonisolated(unsafe) private static var registered = false

    override class func setUp() {
        super.setUp()
        guard !registered else { return }
        registered = true
        XCTestObservationCenter.shared.addTestObserver(AAATraceObserver())
    }

    func testTracingIsOn() {}
}
