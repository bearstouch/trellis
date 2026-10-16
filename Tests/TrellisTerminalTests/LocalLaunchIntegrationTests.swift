import Darwin
import Foundation
import XCTest
import TrellisCore
@testable import TrellisTerminal

private struct PermissiveLaunchFiles: LaunchFileAccess {
    func isExecutableFile(_ path: String) -> Bool { true }
    func isAccessibleDirectory(_ path: String) -> Bool { true }
}

final class LocalLaunchIntegrationTests: XCTestCase {
    @MainActor
    func testActualArgumentsEnvironmentWorkingDirectoryAndTerminalSize() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Trellis launch \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = PTYProcess()
        var bytes = Data()
        let exited = expectation(description: "configured child exits")
        process.onOutput = { bytes.append($0) }
        var status: Int32?
        process.onExit = {
            status = $0; exited.fulfill()
        }
        let script = #"use Cwd; print getcwd()."\n"; print join('|', @ARGV)."\n"; print "GOOD=$ENV{GOOD}\n"; print exists($ENV{TRELLIS_TOKEN}) ? 'LEAK' : 'CLEAN'; print "\n"; system('/bin/stty', 'size'); exit 7;"#
        let config = LocalLaunchConfiguration(
            executable: "/usr/bin/perl", arguments: ["-e", script, "--", "file with spaces", "$(literal)", "it's literal"],
            directory: directory.path, inheritedEnvironment: ["PATH": "/bin:/usr/bin", "TRELLIS_TOKEN": "control-secret"], environmentOverrides: ["GOOD": "override"])
        let validated = try LocalLaunchValidator().validate(config)
        let pid = try await process.launch(validated, size: TerminalSize(columns: 111, rows: 33))
        XCTAssertGreaterThan(pid, 0)
        await fulfillment(of: [exited], timeout: 10)
        let output = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(output.contains(directory.resolvingSymlinksInPath().path), output)
        XCTAssertTrue(output.contains("file with spaces|$(literal)|it's literal"), output)
        XCTAssertTrue(output.contains("GOOD=override"), output)
        XCTAssertTrue(output.contains("CLEAN"), output)
        XCTAssertTrue(output.contains("33 111"), output)
        XCTAssertFalse(output.contains("control-secret"))
        XCTAssertEqual(status, 7)
        XCTAssertEqual(process.descriptor, -1)
    }

    @MainActor
    func testHandshakeReportsExecAndDirectoryFailuresAfterPreflight() async throws {
        let validator = LocalLaunchValidator(files: PermissiveLaunchFiles())
        for configuration in [
            LocalLaunchConfiguration(executable: "/no-such-trellis-executable-\(UUID())", directory: "/tmp", inheritedEnvironment: [:]),
            LocalLaunchConfiguration(executable: "/bin/zsh", directory: "/no-such-trellis-directory-\(UUID())", inheritedEnvironment: [:])
        ] {
            let process = PTYProcess()
            var callbacks = 0
            process.onExit = { _ in callbacks += 1 }
            let validated = try validator.validate(configuration)
            do {
                _ = try await process.launch(validated, size: TerminalSize(columns: 80, rows: 24))
                XCTFail("failed exec/chdir reported as a successful launch")
            } catch { XCTAssertEqual(error as? LocalLaunchError, .spawnFailed(ENOENT)) }
            XCTAssertFalse(process.isRunning)
            XCTAssertEqual(process.descriptor, -1)
            XCTAssertEqual(callbacks, 0)
        }
    }

    @MainActor
    func testActualExecExit127IsNotLaunchFailure() async throws {
        let process = PTYProcess()
        let session = LocalSessionController(transport: process)
        let exited = expectation(description: "exec succeeded and process exited")
        session.onExit = { _ in exited.fulfill() }
        await session.start(
            LocalLaunchConfiguration(executable: "/bin/zsh", arguments: ["-f", "-c", "exit 127"], directory: "/tmp", inheritedEnvironment: [:]),
            size: try TerminalSize(columns: 80, rows: 24))
        await fulfillment(of: [exited], timeout: 10)
        XCTAssertEqual(session.state, .exited)
        XCTAssertEqual(session.exitCode, 127)
        XCTAssertNil(session.failure)
    }

    @MainActor
    func testControllingTerminalResizeAndInterrupt() async throws {
        let process = PTYProcess()
        let exited = expectation(description: "interrupt fixture exits")
        var bytes = Data()
        var code: Int32?
        process.onOutput = { bytes.append($0) }
        process.onExit = {
            code = $0; exited.fulfill()
        }
        // No shell startup files: this owned fixture reads terminal-generated input.
        let script = #"$SIG{INT}=sub { print "INTERRUPTED\n"; exit 23 }; print "READY\n"; while (defined($line=<STDIN>)) { system('/bin/stty','size'); }"#
        let validated = try LocalLaunchValidator().validate(
            LocalLaunchConfiguration(executable: "/usr/bin/perl", arguments: ["-e", script], directory: "/tmp", inheritedEnvironment: [:], environmentOverrides: ["PERL_UNICODE": "S"]))
        let pid = try await process.launch(validated, size: TerminalSize(columns: 80, rows: 24))
        defer { process.signalGroup(SIGKILL) }
        XCTAssertEqual(getpgid(pid), pid)
        XCTAssertEqual(tcgetpgrp(process.descriptor), pid)
        let deadline = Date().addingTimeInterval(5)
        while !String(decoding: bytes, as: UTF8.self).contains("READY"), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("READY"))
        process.resize(try TerminalSize(columns: 100, rows: 40))
        try process.send(Data("\n".utf8))
        let resized = Date().addingTimeInterval(5)
        while !String(decoding: bytes, as: UTF8.self).contains("40 100"), Date() < resized { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("40 100"))
        try process.send(Data([3]))
        await fulfillment(of: [exited], timeout: 10)
        XCTAssertEqual(code, 23, String(decoding: bytes, as: UTF8.self))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("INTERRUPTED"))
    }
    @MainActor
    func testZshAndBashJobControlInterruptAndEOF() async throws {
        for (executable, arguments) in [("/bin/zsh", ["-f"]), ("/bin/bash", ["--noprofile", "--norc", "-i"])] {
            let process = PTYProcess()
            var output = Data()
            let exited = expectation(description: "\(executable) exits on Ctrl-D")
            process.onOutput = { output.append($0) }
            process.onExit = { _ in exited.fulfill() }
            let configuration = LocalLaunchConfiguration(
                executable: executable, arguments: arguments, directory: "/tmp",
                inheritedEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp", "PS1": "TRELLIS-READY> ", "LC_ALL": "C"])
            let pid = try await process.launch(LocalLaunchValidator().validate(configuration), size: TerminalSize(columns: 100, rows: 30))
            var jobGroup: pid_t?
            defer {
                // A stopped job is not foreground and can outlive its shell.
                if let jobGroup, jobGroup > 0, jobGroup != pid, getsid(jobGroup) == pid {
                    _ = kill(-jobGroup, SIGKILL)
                }
                process.signalGroup(SIGKILL)
            }
            let promptDeadline = Date().addingTimeInterval(5)
            while !String(decoding: output, as: UTF8.self).contains("TRELLIS-READY>"), Date() < promptDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("TRELLIS-READY>"))
            try process.send(Data("/bin/sleep 30\r".utf8))
            var deadline = Date().addingTimeInterval(5)
            while tcgetpgrp(process.descriptor) == pid, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            let foreground = tcgetpgrp(process.descriptor)
            XCTAssertGreaterThan(foreground, 0)
            XCTAssertNotEqual(foreground, pid, "shell did not transfer foreground job control")
            if foreground > 0, foreground != pid { jobGroup = foreground }
            try process.send(Data([26]))  // Ctrl-Z stops the foreground job.
            deadline = Date().addingTimeInterval(5)
            while tcgetpgrp(process.descriptor) != pid, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(tcgetpgrp(process.descriptor), pid)
            try process.send(Data("fg\r".utf8))
            deadline = Date().addingTimeInterval(5)
            while tcgetpgrp(process.descriptor) == pid, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNotEqual(tcgetpgrp(process.descriptor), pid)
            try process.send(Data([3]))  // Ctrl-C interrupts the resumed sleep.
            deadline = Date().addingTimeInterval(5)
            while tcgetpgrp(process.descriptor) != pid, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(tcgetpgrp(process.descriptor), pid)
            try process.send(Data([4]))  // Ctrl-D at the shell prompt exits.
            await fulfillment(of: [exited], timeout: 10)
            XCTAssertFalse(process.isRunning)
            XCTAssertEqual(process.descriptor, -1)
        }
    }

}
