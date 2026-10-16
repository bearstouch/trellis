import Darwin
import XCTest
import TrellisCore
@testable import TrellisTerminal

final class PTYOutputOrderingTests: XCTestCase {
    @MainActor
    func testFloodOutputRemainsOrderedAcrossBoundedReads() async throws {
        let process = PTYProcess()
        defer { process.signalGroup(SIGKILL) }
        let exited = expectation(description: "binary sequence writer exits and drains")
        var received = Data(), chunkSizes: [Int] = []
        process.onOutput = {
            received.append($0); chunkSizes.append($0.count)
        }
        process.onExit = { code in
            XCTAssertEqual(code, 0); exited.fulfill()
        }
        // Raw mode prevents the PTY line discipline from rewriting LF bytes.
        let script = "stty raw -echo; exec /usr/bin/perl -e 'for ($i=0;$i<20000;$i++){print pack(\"N\",$i)}'"
        try await process.start(
            executable: "/bin/zsh", arguments: ["-f", "-c", script],
            environment: ["PATH=/usr/bin:/bin"], directory: "/tmp",
            size: winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0))
        await fulfillment(of: [exited], timeout: 8)
        var expected = Data()
        for value in 0..<20_000 {
            expected.append(contentsOf: [
                UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)
            ])
        }
        XCTAssertEqual(received, expected)
        XCTAssertGreaterThan(chunkSizes.count, 1)
        XCTAssertTrue(chunkSizes.allSatisfy { (1...16_384).contains($0) }, "Each delivered read must stay bounded")
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.descriptor, -1)
    }
}
