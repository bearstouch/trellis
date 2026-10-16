import Darwin
import XCTest
import TrellisCore
@testable import TrellisTerminal

final class ProcessOwnershipTests: XCTestCase {
    @MainActor
    func testChangedLaunchIdentityRefusesSignalAtTransportBoundary() async throws {
        var changed = false
        var signals: [Int32] = []
        let process = PTYProcess(
            readIdentity: { pid in
                guard let actual = PTYProcess.identity(pid) else { return nil }
                guard changed else { return actual }
                return OwnedProcessIdentity(
                    pid: pid, parentPID: actual.parentPID, groupID: actual.groupID,
                    startedSeconds: actual.startedSeconds + 1, startedMicroseconds: actual.startedMicroseconds)
            },
            signalProcessGroup: { pid, signal in
                signals.append(signal)
                _ = kill(-pid, signal)
            })
        let launch = try LocalLaunchValidator().validate(LocalLaunchConfiguration(executable: "/bin/zsh", arguments: ["-f", "-c", "sleep 30"], directory: "/tmp", inheritedEnvironment: [:]))
        let exited = expectation(description: "owned child exit reported once")
        var count = 0
        process.onExit = { _ in
            count += 1; exited.fulfill()
        }
        let pid = try await process.launch(launch, size: TerminalSize(columns: 80, rows: 24))
        let expected = try XCTUnwrap(PTYProcess.identity(pid))
        defer {
            if process.isRunning, expected.permitsSignal(current: PTYProcess.identity(pid), ownerPID: getpid()) { _ = kill(-pid, SIGKILL) }
        }
        changed = true
        process.signalGroup(SIGKILL)
        XCTAssertTrue(signals.isEmpty)
        XCTAssertTrue(process.isRunning)
        changed = false
        process.signalGroup(SIGKILL)
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertEqual(signals, [SIGKILL])
        XCTAssertEqual(count, 1)
        XCTAssertEqual(process.descriptor, -1)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }
}
