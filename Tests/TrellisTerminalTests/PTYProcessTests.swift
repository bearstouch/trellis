import AppKit
import Darwin
import XCTest
import TrellisCore
@testable import TrellisTerminal

final class PTYProcessTests: XCTestCase {
    @MainActor
    func testFallbackReapsWhenProcessExitNotificationIsUnavailable() async throws {
        let process = PTYProcess(processExitNotifications: false)
        let exited = expectation(description: "fallback reaps child and closes PTY")
        var exitCode: Int32?
        var output = Data()
        process.onOutput = { output.append($0) }
        process.onExit = {
            exitCode = $0; exited.fulfill()
        }
        try await process.start(
            executable: "/bin/zsh", arguments: ["-f", "-c", "sleep 0.1; printf done; exit 7"],
            environment: ["PATH=/usr/bin:/bin"], directory: "/tmp",
            size: winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0))
        let pid = process.pid
        let descriptor = process.descriptor
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertEqual(exitCode, 7)
        XCTAssertEqual(output, Data("done".utf8))
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.descriptor, -1)
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    @MainActor
    func testChildDoesNotInheritApplicationDescriptors() async throws {
        let descriptor = open("/dev/null", O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 3)
        guard descriptor >= 3 else { return }
        defer { _ = close(descriptor) }
        XCTAssertEqual(fcntl(descriptor, F_SETFD, 0), 0)
        let process = PTYProcess()
        let exited = expectation(description: "descriptor probe exits")
        var output = Data()
        process.onOutput = { output.append($0) }
        process.onExit = { _ in exited.fulfill() }
        // Perl can probe a numeric descriptor without opening/reusing it.
        let probe = "if (open(my $copy, '<&=\(descriptor)')) { print 'LEAKED' } else { print 'CLOSED' }"
        try await process.start(
            executable: "/usr/bin/perl", arguments: ["-e", probe],
            environment: ["PATH=/usr/bin:/bin"], directory: "/tmp",
            size: winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0))
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "CLOSED")
        XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0, "the parent retains ownership")
    }

    @MainActor
    func testCanTerminateChildAfterPTYEOF() async throws {
        let process = PTYProcess()
        let exited = expectation(description: "closed-stdio child is reaped")
        var code: Int32?
        process.onExit = {
            code = $0; exited.fulfill()
        }
        try await process.start(
            executable: "/bin/zsh", arguments: ["-f", "-c", "exec /usr/bin/perl -e 'close STDIN; close STDOUT; close STDERR; sleep 30'"],
            environment: ["PATH=/usr/bin:/bin"], directory: "/tmp",
            size: winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0))
        let deadline = Date().addingTimeInterval(2)
        while process.descriptor >= 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(process.descriptor, -1, "fixture must actually reach PTY EOF before testing termination")
        XCTAssertTrue(process.isRunning)
        process.signalGroup(SIGKILL)
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertEqual(code, 128 + SIGKILL)
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.descriptor, -1)
    }

    @MainActor
    func testNaturalExitDrainsOutputAndReleasesDescriptor() async throws {
        let process = PTYProcess()
        let exited = expectation(description: "all final output drained")
        var received = Data()
        process.onOutput = { received.append($0) }
        process.onExit = { _ in exited.fulfill() }
        try await process.start(
            executable: "/bin/zsh", arguments: ["-f", "-c", "printf 'final bytes'; exit 7"],
            environment: ["PATH=/usr/bin:/bin"], directory: "/tmp",
            size: winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0))
        let fd = process.descriptor
        let pid = process.pid
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertEqual(received, Data("final bytes".utf8))
        let deadline = Date().addingTimeInterval(2)
        while fcntl(fd, F_GETFD) >= 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(fcntl(fd, F_GETFD), -1)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    @MainActor
    func testNativeOwnerCanStopAfterEOF() async throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        let exited = expectation(description: "native terminal stop completes")
        native.onExit = { _ in exited.fulfill() }
        native.start(arguments: ["-f", "-c", "exec /usr/bin/perl -e 'close STDIN; close STDOUT; close STDERR; sleep 30'"])
        try await Task.sleep(for: .milliseconds(100))
        native.adapter.detach()
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertFalse(native.isRunning)
    }

    @MainActor
    func testLargeNativePasteReachesChildIntact() async throws {
        let process = PTYProcess()
        let exited = expectation(description: "large input consumed")
        var output = Data()
        process.onOutput = { output.append($0) }
        process.onExit = { _ in exited.fulfill() }
        let script =
            #"stty raw -echo; printf READY; exec /usr/bin/perl -e '$n=0; $bad=0; while ($n<131072) { $r=sysread(STDIN,$b,131072-$n); last unless $r; $n+=$r; $bad=1 if $b =~ /[^x]/; } print "RECEIVED:$n:BAD:$bad"'"#
        try await process.start(
            executable: "/bin/zsh", arguments: ["-f", "-c", script],
            environment: ["PATH=/usr/bin:/bin"], directory: "/tmp",
            size: winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0))
        let deadline = Date().addingTimeInterval(3)
        while !String(decoding: output, as: UTF8.self).contains("READY"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("READY"))
        try process.send(Data(repeating: 120, count: 131_072))
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("RECEIVED:131072:BAD:0"))
    }

    @MainActor
    func testBackpressuredShutdownClosesChannelDescriptorAndReportsOverload() async throws {
        let process = PTYProcess()
        XCTAssertThrowsError(try process.send(Data([1]))) {
            XCTAssertEqual($0 as? TerminalAdapterError, .inputClosed)
        }
        let exited = expectation(description: "blocked input session exits")
        var output = Data()
        process.onOutput = { output.append($0) }
        process.onExit = { _ in exited.fulfill() }
        try await process.start(
            executable: "/bin/zsh", arguments: ["-f", "-c", "stty raw -echo; printf READY; exec /bin/sleep 30"],
            environment: ["PATH=/usr/bin:/bin"], directory: "/tmp",
            size: winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0))
        let readyDeadline = Date().addingTimeInterval(3)
        while !String(decoding: output, as: UTF8.self).contains("READY"), Date() < readyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("READY"))
        try process.send(Data(repeating: 120, count: PTYProcess.inputQueueLimit))
        XCTAssertGreaterThan(process.pendingInputCount, 0)
        let readFD = process.descriptor
        let pendingBefore = process.pendingInputCount
        XCTAssertThrowsError(try process.send(Data(repeating: 120, count: PTYProcess.inputQueueLimit))) {
            XCTAssertEqual($0 as? TerminalAdapterError, .inputQueueFull)
        }
        XCTAssertEqual(process.pendingInputCount, pendingBefore)
        process.signalGroup(SIGKILL)
        await fulfillment(of: [exited], timeout: 5)
        let closeDeadline = Date().addingTimeInterval(2)
        while fcntl(readFD, F_GETFD) >= 0, Date() < closeDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fcntl(readFD, F_GETFD), -1)
        XCTAssertEqual(process.pendingInputCount, 0)
        XCTAssertThrowsError(try process.send(Data([1]))) {
            XCTAssertEqual($0 as? TerminalAdapterError, .inputClosed)
        }
    }

}
