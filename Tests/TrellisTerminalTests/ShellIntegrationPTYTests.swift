import AppKit
import Foundation
import XCTest
import TrellisCore
@testable import TrellisTerminal

/// Real shells in a PTY with a temporary HOME, so no user dotfiles are read.
final class ShellIntegrationPTYTests: XCTestCase {
    private struct Shell {
        let terminal: NativeTerminal
        let home: URL
        let nonce: String
        var events: () -> [ShellIntegrationEvent]
    }

    @MainActor
    private func launch(_ executable: String, extraEnvironment: [String: String] = [:], files: [String: String] = [:]) async throws -> Shell {
        _ = NSApplication.shared
        guard FileManager.default.isExecutableFile(atPath: executable), let kind = ShellIntegrationKind(executable: executable) else {
            throw XCTSkip("\(executable) is not installed")
        }
        let created = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-si-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: created.appendingPathComponent("x y"), withIntermediateDirectories: true)
        // Shells report the physical path (/private/var/…).
        // Foundation's symlink resolution drops /private again, so ask realpath(3).
        let resolved = try XCTUnwrap(realpath(created.path, nil))
        defer { free(resolved) }
        let home = URL(fileURLWithPath: String(cString: resolved))
        // Each user file marks itself; integration must not stop the normal startup files.
        try "export USER_ZSHENV=1\n".write(to: home.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        // An exported prompt must not carry the nonce to children.
        try "export USER_ZSHRC=1\nexport PS1='%% '\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try "export USER_BASH_PROFILE=1\nexport PS1='$ '\n".write(to: home.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/fish"), withIntermediateDirectories: true)
        try "set -gx USER_FISH_CONFIG 1\n".write(to: home.appendingPathComponent(".config/fish/config.fish"), atomically: true, encoding: .utf8)
        for (name, text) in files { try text.write(to: home.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "LANG": "en_US.UTF-8"].merging(extraEnvironment) { $1 }
        let nonce = ShellIntegrationInjection.makeNonce()
        let injection = try XCTUnwrap(
            ShellIntegrationInjection.plan(
                kind: kind, arguments: ["-l"], inheritedEnvironment: environment, resourceDirectory: try XCTUnwrap(BundledShellIntegration.directory()),
                nonce: nonce))
        let terminal = NativeTerminal()
        var events: [ShellIntegrationEvent] = []
        terminal.onShellIntegrationEvent = { events.append($0) }
        await terminal.start(
            configuration: LocalLaunchConfiguration(
                executable: executable, arguments: ["-l"], directory: home.path, inheritedEnvironment: environment, shellIntegration: injection))
        let shell = Shell(terminal: terminal, home: home, nonce: nonce, events: { events })
        try await waitUntil { events.contains { if case .promptStart = $0 { true } else { false } } }
        return shell
    }

    @MainActor
    private func run(_ shell: Shell, _ command: String) async throws {
        let finished = shell.events().filter { if case .commandFinished = $0 { true } else { false } }.count
        try shell.terminal.adapter.send(Data((command + "\r").utf8))
        try await waitUntil { shell.events().filter { if case .commandFinished = $0 { true } else { false } }.count > finished }
        // The next prompt follows the finish mark.
        try await Task.sleep(for: .milliseconds(150))
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "timed out waiting for shell integration")
    }

    @MainActor
    private func exerciseShell(_ executable: String, userMarker: String) async throws {
        let shell = try await launch(executable)
        defer {
            shell.terminal.requestTermination(force: true); shell.terminal.adapter.detach()
            try? FileManager.default.removeItem(at: shell.home)
        }
        try await run(shell, "echo marker=$\(userMarker)")
        try await run(shell, "cd 'x y'")
        try await run(shell, "false")
        try await run(shell, "env | grep -c -e TRELLIS_ -e \(shell.nonce) || true")
        let output = try shell.terminal.adapter.read(.retainedText)
        XCTAssertTrue(output.contains("marker=1"), "user startup files still load:\n\(output)")
        XCTAssertTrue(output.contains("\n0"), "no TRELLIS_ variable (nonce) reaches child processes:\n\(output)")
        let events = shell.events()
        XCTAssertTrue(events.contains(.promptStart(directory: shell.home.appendingPathComponent("x y").path)), "\(events)")
        XCTAssertTrue(events.contains(.commandStart(commandLine: "false")), "\(events)")
        XCTAssertTrue(events.contains(.commandFinished(exitCode: 1)), "\(events)")
        XCTAssertTrue(events.contains(.commandFinished(exitCode: 0)), "\(events)")
    }

    @MainActor
    func testZshReportsDirectoryCommandsAndExitStatus() async throws {
        try await exerciseShell("/bin/zsh", userMarker: "USER_ZSHRC")
    }

    @MainActor
    func testZshKeepsAnExistingZDOTDIR() async throws {
        let dotdir = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-zdotdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dotdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dotdir) }
        try "export CUSTOM_DOTDIR=1\n".write(to: dotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let shell = try await launch("/bin/zsh", extraEnvironment: ["ZDOTDIR": dotdir.path])
        defer {
            shell.terminal.requestTermination(force: true); shell.terminal.adapter.detach()
            try? FileManager.default.removeItem(at: shell.home)
        }
        try await run(shell, "echo dotdir=$CUSTOM_DOTDIR:$ZDOTDIR")
        XCTAssertTrue(try shell.terminal.adapter.read(.retainedText).contains("dotdir=1:\(dotdir.path)"))
    }

    @MainActor
    func testSystemBashReportsDirectoryCommandsAndExitStatus() async throws {
        try await exerciseShell("/bin/bash", userMarker: "USER_BASH_PROFILE")
    }

    @MainActor
    func testFishReportsDirectoryCommandsAndExitStatus() async throws {
        let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first { FileManager.default.isExecutableFile(atPath: $0) }
        try await exerciseShell(fish ?? "/opt/homebrew/bin/fish", userMarker: "USER_FISH_CONFIG")
    }

    @MainActor
    func testForgedMarksInOutputProduceNoEvents() async throws {
        let shell = try await launch("/bin/zsh")
        defer {
            shell.terminal.requestTermination(force: true); shell.terminal.adapter.detach()
            try? FileManager.default.removeItem(at: shell.home)
        }
        try await run(shell, #"printf '\033]133;D;42;trellis=00000000000000000000000000000000\007\033]133;D;43\007'"#)
        let events = shell.events()
        XCTAssertFalse(events.contains(.commandFinished(exitCode: 42)), "\(events)")
        XCTAssertFalse(events.contains(.commandFinished(exitCode: 43)), "\(events)")
    }

    @MainActor
    func testPromptNavigationMovesBetweenMarkedPrompts() async throws {
        let shell = try await launch("/bin/zsh")
        defer {
            shell.terminal.requestTermination(force: true); shell.terminal.adapter.detach()
            try? FileManager.default.removeItem(at: shell.home)
        }
        try await run(shell, "seq 1 200")
        try await run(shell, "seq 1 200")
        let terminal = try XCTUnwrap(shell.terminal.view as? AccessibleTerminalView).getTerminal()
        let bottom = terminal.getTopVisibleRow()
        XCTAssertTrue(shell.terminal.scrollToPrompt(forward: false))
        let previous = terminal.getTopVisibleRow()
        XCTAssertLessThan(previous, bottom)
        XCTAssertEqual(terminal.semanticRowKind(at: previous), .initial)
        XCTAssertTrue(shell.terminal.scrollToPrompt(forward: false))
        XCTAssertLessThan(terminal.getTopVisibleRow(), previous)
        XCTAssertTrue(shell.terminal.scrollToPrompt(forward: true))
        XCTAssertEqual(terminal.getTopVisibleRow(), previous)
    }

    @MainActor
    private func assertSurvivesStrictUserSettings(_ shell: Shell) async throws {
        defer {
            shell.terminal.requestTermination(force: true); shell.terminal.adapter.detach()
            try? FileManager.default.removeItem(at: shell.home)
        }
        try await run(shell, "true")
        try await run(shell, "/bin/sh -c 'exit 3'")
        let events = shell.events()
        XCTAssertTrue(events.contains(.commandFinished(exitCode: 3)), "the user's hooks must not change the reported status: \(events)")
        let output = try shell.terminal.adapter.read(.retainedText)
        XCTAssertFalse(output.contains("not set") || output.contains("unbound variable"), output)
    }

    @MainActor
    func testZshSurvivesNounsetKshArraysAndStatusChangingHooks() async throws {
        let rc = "setopt nounset ksh_arrays\nPS1='%% '\nuser_hook() { false; }\nprecmd_functions+=(user_hook)\n"
        try await assertSurvivesStrictUserSettings(try await launch("/bin/zsh", files: [".zshrc": rc]))
    }

    @MainActor
    func testSystemBashSurvivesNounsetAndChainsAnExistingDebugTrap() async throws {
        let profile = "set -u\nPS1='$ '\nPROMPT_COMMAND='false'\ntrap 'user_trap=\"$_\"' DEBUG\n"
        try await assertSurvivesStrictUserSettings(try await launch("/bin/bash", files: [".bash_profile": profile]))
    }
}
