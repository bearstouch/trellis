import Foundation
import XCTest
@testable import TrellisCore

private struct ScriptFiles: LaunchFileAccess {
    var scriptExists = true
    func isExecutableFile(_ path: String) -> Bool { true }
    func isAccessibleDirectory(_ path: String) -> Bool { true }
    func isReadableFile(_ path: String) -> Bool { scriptExists }
}

final class ShellIntegrationTests: XCTestCase {
    private let nonce = "0123456789abcdef0123456789abcdef"
    private func mark(_ text: String) -> [UInt8] { Array(text.utf8) }

    func testKindIsDetectedFromTheExecutableName() {
        XCTAssertEqual(ShellIntegrationKind(executable: "/bin/zsh"), .zsh)
        XCTAssertEqual(ShellIntegrationKind(executable: "/opt/homebrew/bin/bash"), .bash)
        XCTAssertEqual(ShellIntegrationKind(executable: "/opt/homebrew/bin/fish"), .fish)
        XCTAssertNil(ShellIntegrationKind(executable: "/opt/homebrew/bin/nu"))
        XCTAssertNil(ShellIntegrationKind(executable: "/usr/bin/ssh"))
    }

    func testZshPlanRestoresAnOriginalZDOTDIR() throws {
        let plain = try XCTUnwrap(ShellIntegrationInjection.plan(kind: .zsh, arguments: ["-l"], inheritedEnvironment: [:], resourceDirectory: "/R", nonce: nonce))
        XCTAssertEqual(plain.arguments, ["-l"])
        XCTAssertEqual(plain.environment["ZDOTDIR"], "/R/zsh")
        XCTAssertNil(plain.environment["TRELLIS_ZSH_ZDOTDIR"])
        XCTAssertEqual(plain.environment["TRELLIS_SHELL_INTEGRATION"], "1")
        XCTAssertEqual(plain.environment["TRELLIS_SHELL_INTEGRATION_NONCE"], nonce)
        XCTAssertEqual(plain.scriptPath, "/R/zsh/.zshenv")
        let custom = try XCTUnwrap(
            ShellIntegrationInjection.plan(kind: .zsh, arguments: ["-l"], inheritedEnvironment: ["ZDOTDIR": "/home/z"], resourceDirectory: "/R", nonce: nonce))
        XCTAssertEqual(custom.environment["TRELLIS_ZSH_ZDOTDIR"], "/home/z")
    }

    func testBashPlanReplacesLoginWithAnEmulatingRcfile() throws {
        let plan = try XCTUnwrap(ShellIntegrationInjection.plan(kind: .bash, arguments: ["-l"], inheritedEnvironment: [:], resourceDirectory: "/R", nonce: nonce))
        XCTAssertEqual(plan.arguments, ["--rcfile", "/R/bash/trellis.bash", "-i"])
        XCTAssertEqual(plan.environment["TRELLIS_BASH_LOGIN"], "1")
    }

    func testFishPlanPrependsTheDataDirectoryAndKeepsTheOriginal() throws {
        let plain = try XCTUnwrap(ShellIntegrationInjection.plan(kind: .fish, arguments: ["-l"], inheritedEnvironment: [:], resourceDirectory: "/R", nonce: nonce))
        XCTAssertEqual(plain.environment["XDG_DATA_DIRS"], "/R:/usr/local/share:/usr/share")
        XCTAssertNil(plain.environment["TRELLIS_FISH_XDG_DATA_DIRS"])
        XCTAssertEqual(plain.scriptPath, "/R/fish/vendor_conf.d/trellis-shell-integration.fish")
        let custom = try XCTUnwrap(
            ShellIntegrationInjection.plan(kind: .fish, arguments: ["-l"], inheritedEnvironment: ["XDG_DATA_DIRS": "/a:/b"], resourceDirectory: "/R", nonce: nonce))
        XCTAssertEqual(custom.environment["XDG_DATA_DIRS"], "/R:/a:/b")
        XCTAssertEqual(custom.environment["TRELLIS_FISH_XDG_DATA_DIRS"], "/a:/b")
    }

    func testOnlyLoginShellsWithAValidNonceArePlanned() {
        XCTAssertNil(ShellIntegrationInjection.plan(kind: .zsh, arguments: ["-f", "-c", "exit"], inheritedEnvironment: [:], resourceDirectory: "/R", nonce: nonce))
        XCTAssertNil(ShellIntegrationInjection.plan(kind: .zsh, arguments: ["-l"], inheritedEnvironment: [:], resourceDirectory: "relative", nonce: nonce))
        XCTAssertNil(ShellIntegrationInjection.plan(kind: .zsh, arguments: ["-l"], inheritedEnvironment: [:], resourceDirectory: "/R", nonce: "short"))
        let generated = ShellIntegrationInjection.makeNonce()
        XCTAssertTrue(ShellIntegrationInjection.isValidNonce(generated))
        XCTAssertNotEqual(generated, ShellIntegrationInjection.makeNonce())
    }

    func testValidatorAppliesTrustedInjectionButStillRejectsReservedOverrides() throws {
        let injection = try XCTUnwrap(ShellIntegrationInjection.plan(kind: .bash, arguments: ["-l"], inheritedEnvironment: [:], resourceDirectory: "/R", nonce: nonce))
        var configuration = LocalLaunchConfiguration(
            executable: "/bin/bash", arguments: ["-l"], directory: "/tmp", inheritedEnvironment: ["TRELLIS_SHELL_INTEGRATION_NONCE": "inherited"],
            shellIntegration: injection)
        let validated = try LocalLaunchValidator(files: ScriptFiles()).validate(configuration)
        XCTAssertEqual(validated.arguments, ["--rcfile", "/R/bash/trellis.bash", "-i"])
        XCTAssertEqual(validated.environment["TRELLIS_SHELL_INTEGRATION_NONCE"], nonce)
        configuration.environmentOverrides = ["TRELLIS_SHELL_INTEGRATION_NONCE": "forged"]
        XCTAssertThrowsError(try LocalLaunchValidator(files: ScriptFiles()).validate(configuration)) {
            XCTAssertEqual($0 as? LocalLaunchError, .reservedEnvironmentKey)
        }
    }

    func testMissingScriptOrMismatchedShellLaunchesThePlainShell() throws {
        let injection = try XCTUnwrap(ShellIntegrationInjection.plan(kind: .zsh, arguments: ["-l"], inheritedEnvironment: [:], resourceDirectory: "/R", nonce: nonce))
        let missing = try LocalLaunchValidator(files: ScriptFiles(scriptExists: false)).validate(
            LocalLaunchConfiguration(executable: "/bin/zsh", arguments: ["-l"], directory: "/tmp", inheritedEnvironment: [:], shellIntegration: injection))
        XCTAssertEqual(missing.arguments, ["-l"])
        XCTAssertNil(missing.environment["ZDOTDIR"])
        XCTAssertNil(missing.environment["TRELLIS_SHELL_INTEGRATION_NONCE"])
        let mismatched = try LocalLaunchValidator(files: ScriptFiles()).validate(
            LocalLaunchConfiguration(executable: "/bin/bash", arguments: ["-l"], directory: "/tmp", inheritedEnvironment: [:], shellIntegration: injection))
        XCTAssertEqual(mismatched.arguments, ["-l"])
        XCTAssertNil(mismatched.environment["ZDOTDIR"])
    }

    func testAuthenticatedMarksBecomeEvents() {
        XCTAssertEqual(ShellIntegrationEvent.parse(mark("A;trellis=\(nonce);cwd=/tmp/x%20y%3B"), nonce: nonce), .promptStart(directory: "/tmp/x y;"))
        XCTAssertEqual(ShellIntegrationEvent.parse(mark("B;trellis=\(nonce)"), nonce: nonce), .commandInputStart)
        XCTAssertEqual(
            ShellIntegrationEvent.parse(mark("C;trellis=\(nonce);cmdline_url=vim%20%C3%A9.txt"), nonce: nonce), .commandStart(commandLine: "vim é.txt"))
        XCTAssertEqual(ShellIntegrationEvent.parse(mark("D;1;trellis=\(nonce)"), nonce: nonce), .commandFinished(exitCode: 1))
        XCTAssertEqual(ShellIntegrationEvent.parse(mark("D;trellis=\(nonce)"), nonce: nonce), .commandFinished(exitCode: nil))
        XCTAssertEqual(ShellIntegrationEvent.parse(mark("D;abc;trellis=\(nonce)"), nonce: nonce), .commandFinished(exitCode: nil))
    }

    func testForgedOrMalformedMarksAreIgnored() {
        let other = "fedcba9876543210fedcba9876543210"
        for payload in [
            "D;1", "D;1;trellis=\(other)", "D;1;trellis=\(nonce.prefix(31))", "D;1;trellis=\(nonce);trellis=\(nonce)", "Z;trellis=\(nonce)",
            "AA;trellis=\(nonce)", ""
        ] {
            XCTAssertNil(ShellIntegrationEvent.parse(mark(payload), nonce: nonce), payload)
        }
        XCTAssertNil(ShellIntegrationEvent.parse(mark("D;1;trellis=\(nonce)"), nonce: "not-a-nonce"))
        XCTAssertNil(ShellIntegrationEvent.parse([0xFF, 0x3B], nonce: nonce))
        let oversized = "C;trellis=\(nonce);cmdline_url=" + String(repeating: "a", count: ShellIntegrationEvent.maximumPayloadBytes)
        XCTAssertNil(ShellIntegrationEvent.parse(mark(oversized), nonce: nonce))
    }

    func testUnusableDirectoriesAndCommandsDegradeWithoutDroppingTheMark() {
        for cwd in ["relative/path", "/tmp/%1B%5B31m", "/tmp/%00", "%ZZ", String(repeating: "/a", count: Int(PATH_MAX))] {
            XCTAssertEqual(ShellIntegrationEvent.parse(mark("A;trellis=\(nonce);cwd=\(cwd)"), nonce: nonce), .promptStart(directory: nil), cwd)
        }
        XCTAssertEqual(ShellIntegrationEvent.parse(mark("C;trellis=\(nonce);cmdline_url=%00"), nonce: nonce), .commandStart(commandLine: nil))
        let long = String(repeating: "%C3%A9", count: 3000)
        guard case .commandStart(let line?) = ShellIntegrationEvent.parse(mark("C;trellis=\(nonce);cmdline_url=\(long)"), nonce: nonce) else {
            return XCTFail("long command lines are truncated, not dropped")
        }
        XCTAssertLessThanOrEqual(line.utf8.count, ShellIntegrationEvent.maximumCommandLineBytes)
        XCTAssertTrue(line.allSatisfy { $0 == "é" })
    }

    func testStateTracksCommandsDirectoryAndFailure() {
        var state = ShellIntegrationState()
        let start = Date(timeIntervalSince1970: 100)
        state.apply(.promptStart(directory: "/tmp"), at: start)
        XCTAssertEqual(state.currentDirectory, "/tmp")
        state.apply(.commandStart(commandLine: "sudo -E /usr/bin/vim notes"), at: start)
        XCTAssertTrue(state.commandRunning)
        XCTAssertEqual(state.commandName, "vim")
        state.apply(.commandFinished(exitCode: 2), at: start.addingTimeInterval(3))
        XCTAssertTrue(state.lastCommandFailed)
        XCTAssertEqual(state.lastExitCode, 2)
        XCTAssertEqual(state.lastDuration, 3)
        XCTAssertNil(state.commandName)
        state.apply(.promptStart(directory: nil), at: start)
        XCTAssertEqual(state.currentDirectory, "/tmp", "an unusable report keeps the last known directory")
        state.apply(.commandStart(commandLine: "true"), at: start)
        XCTAssertFalse(state.lastCommandFailed, "a new command clears the failure")
        state.apply(.commandFinished(exitCode: 0), at: start)
        XCTAssertFalse(state.lastCommandFailed)
        state.apply(.commandFinished(exitCode: 9), at: start)
        XCTAssertEqual(state.lastExitCode, 0, "a finish without a start is ignored")
    }

    func testFinishedCommandKeepsOnlyItsProgramNameAndDuration() {
        var state = ShellIntegrationState()
        let start = Date(timeIntervalSince1970: 100)
        state.apply(.commandStart(commandLine: "env TOKEN=s3cret /usr/bin/make release"), at: start)
        XCTAssertNil(state.lastCommandName)
        state.apply(.commandFinished(exitCode: 0), at: start.addingTimeInterval(125))
        XCTAssertEqual(state.lastCommandName, "make")
        XCTAssertNil(state.commandLine, "the command line is gone once the command finishes")
        XCTAssertEqual(state.durationText, "2 min 5 s")
        state.apply(.commandStart(commandLine: "sleep 20"), at: start)
        state.apply(.promptStart(directory: nil), at: start.addingTimeInterval(20))
        XCTAssertEqual(state.lastCommandName, "sleep", "a prompt while running finishes the command too")
        XCTAssertNil(state.lastExitCode)
        XCTAssertEqual(state.durationText, "20 s")
    }

    func testRemoteMarksNeedNoNonceButOnlyCarryPromptAndCommandState() {
        XCTAssertEqual(ShellIntegrationEvent.parseRemote(mark("A")), .promptStart(directory: nil))
        XCTAssertEqual(ShellIntegrationEvent.parseRemote(mark("A;cwd=/etc")), .promptStart(directory: nil), "a remote directory comes from OSC 7 or 1337")
        XCTAssertEqual(ShellIntegrationEvent.parseRemote(mark("C")), .commandStart(commandLine: nil))
        XCTAssertEqual(ShellIntegrationEvent.parseRemote(mark("C;cmdline_url=make%20all")), .commandStart(commandLine: "make all"))
        XCTAssertEqual(ShellIntegrationEvent.parseRemote(mark("D;3")), .commandFinished(exitCode: 3))
        XCTAssertEqual(ShellIntegrationEvent.parseRemote(mark("D")), .commandFinished(exitCode: nil))
        for payload in ["B", "Z", "AA", "", "D;1;k=a;k=b"] { XCTAssertNil(ShellIntegrationEvent.parseRemote(mark(payload)), payload) }
        XCTAssertNil(ShellIntegrationEvent.parseRemote([0xFF]))
        XCTAssertNil(ShellIntegrationEvent.parseRemote(mark("C;cmdline_url=" + String(repeating: "a", count: ShellIntegrationEvent.maximumPayloadBytes))))
    }

    func testLocalParsingStillRejectsNonceLessMarks() {
        for payload in ["A", "A;cwd=/tmp", "C", "D;0", "D;1"] { XCTAssertNil(ShellIntegrationEvent.parse(mark(payload), nonce: nonce), payload) }
    }

    func testRemoteDirectoryReportsAreDecodedAndBounded() {
        XCTAssertEqual(ShellIntegrationEvent.parseRemote(osc7: mark("file://web-1.example/srv/my%20app")), .reportedDirectory("/srv/my app", host: "web-1.example"))
        XCTAssertEqual(ShellIntegrationEvent.parseRemote(osc7: mark("FILE:///var/log")), .reportedDirectory("/var/log", host: nil))
        XCTAssertEqual(ShellIntegrationEvent.parseRemote(osc7: mark("file://[::1]/tmp")), .reportedDirectory("/tmp", host: "[::1]"))
        for payload in [
            "file://host", "file://host/tmp/%1B%5D", "file://host/%00", "http://host/tmp", "file://bad host/tmp", "file://h%C3%A9/tmp",
            "file://" + String(repeating: "h", count: 254) + "/tmp", "file://host/" + String(repeating: "a/", count: Int(PATH_MAX))
        ] {
            XCTAssertNil(ShellIntegrationEvent.parseRemote(osc7: mark(payload)), payload)
        }
        XCTAssertEqual(ShellIntegrationEvent.parseRemote(osc1337: mark("CurrentDir=/home/deploy/100%")), .reportedDirectory("/home/deploy/100%", host: nil))
        XCTAssertEqual(ShellIntegrationEvent.parseRemote(osc1337: mark("RemoteHost=deploy@web-1")), .reportedHost("web-1"))
        XCTAssertEqual(ShellIntegrationEvent.parseRemote(osc1337: mark("RemoteHost=web-1")), .reportedHost("web-1"))
        for payload in ["CurrentDir=relative", "CurrentDir=/tmp/\u{1B}[31m", "RemoteHost=deploy@", "RemoteHost=a@b c", "File=inline=1:AAAA", "SetMark"] {
            XCTAssertNil(ShellIntegrationEvent.parseRemote(osc1337: mark(payload)), payload)
        }
    }

    func testOnlyRemoteStateTakesReportedLocations() {
        var local = ShellIntegrationState()
        local.apply(.reportedDirectory("/srv", host: "web"), at: Date())
        local.apply(.reportedHost("web"), at: Date())
        XCTAssertNil(local.currentDirectory)
        XCTAssertNil(local.remoteHost)
        var remote = ShellIntegrationState(origin: .remote)
        remote.apply(.reportedDirectory("/srv", host: "web"), at: Date())
        remote.apply(.reportedDirectory("/srv/app", host: nil), at: Date())
        XCTAssertEqual(remote.currentDirectory, "/srv/app")
        XCTAssertEqual(remote.remoteHost, "web", "a path without a host keeps the last host")
        remote.apply(.reportedHost("db"), at: Date())
        XCTAssertEqual(remote.remoteHost, "db")
        XCTAssertEqual(remote.origin, .remote)
    }

    func testDurationTextUsesWholeUnits() {
        XCTAssertEqual(ShellIntegrationState.durationText(0.4), "0 s")
        XCTAssertEqual(ShellIntegrationState.durationText(59.9), "59 s")
        XCTAssertEqual(ShellIntegrationState.durationText(60), "1 min")
        XCTAssertEqual(ShellIntegrationState.durationText(3600), "1 h")
        XCTAssertEqual(ShellIntegrationState.durationText(3725), "1 h 2 min")
        XCTAssertEqual(ShellIntegrationState.durationText(-5), "0 s", "a clock step backwards never shows a negative time")
        XCTAssertEqual(ShellIntegrationState.durationText(.infinity), "0 s")
        XCTAssertNil(ShellIntegrationState().durationText)
    }

    func testBundledScriptsArePackaged() throws {
        let directory = try XCTUnwrap(BundledShellIntegration.directory())
        for kind in ShellIntegrationKind.allCases {
            let plan = try XCTUnwrap(ShellIntegrationInjection.plan(kind: kind, arguments: ["-l"], inheritedEnvironment: [:], resourceDirectory: directory, nonce: nonce))
            XCTAssertTrue(FileManager.default.isReadableFile(atPath: plan.scriptPath), plan.scriptPath)
        }
    }
}
