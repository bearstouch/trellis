import Foundation
import XCTest

/// Temporary, to find where CI stalls: stdout is buffered there, so each test's start and end go to stderr with a time.
/// Named to run first, so its class setUp registers the observer before the other classes run.
final class AAATraceObserver: NSObject, XCTestObservation, @unchecked Sendable {
    private func write(_ text: String) { FileHandle.standardError.write(Data("TRACE \(Date()) \(text)\n".utf8)) }
    func testCaseWillStart(_ testCase: XCTestCase) { write("start \(testCase.name)") }
    func testCaseDidFinish(_ testCase: XCTestCase) { write("end \(testCase.name)") }
    func testBundleDidFinish(_ testBundle: Bundle) { write("bundle finished") }
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
