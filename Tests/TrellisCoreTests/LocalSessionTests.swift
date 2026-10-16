import Darwin
import XCTest
@testable import TrellisCore

private struct TestLaunchFiles: LaunchFileAccess {
    var directoryAccessible = true
    func isExecutableFile(_ path: String) -> Bool { path.hasPrefix("/bin/") }
    func isAccessibleDirectory(_ path: String) -> Bool { directoryAccessible }
}

@MainActor
private final class TestSessionTransport: LocalSessionTransport {
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32?) -> Void)?
    var onInputError: ((Error) -> Void)?
    var launches: [ValidatedLocalLaunch] = []
    var sizes: [TerminalSize] = []
    var signals: [Int32] = []
    var exitDuringLaunch = false
    var suspendLaunch = false
    var launchContinuation: CheckedContinuation<Void, Never>?
    func launch(_ configuration: ValidatedLocalLaunch, size: TerminalSize) async throws -> Int32 {
        launches.append(configuration); sizes.append(size)
        if suspendLaunch { await withCheckedContinuation { launchContinuation = $0 } }
        if exitDuringLaunch { onExit?(7) }
        return 42
    }
    func send(_ data: Data) throws {}
    func resize(_ size: TerminalSize) { sizes.append(size) }
    func signalGroup(_ signal: Int32) { signals.append(signal) }
}

final class LocalSessionTests: XCTestCase {
    @MainActor
    func testResizeDuringSpawnReachesNewProcess() async throws {
        let transport = TestSessionTransport(); transport.suspendLaunch = true
        let session = LocalSessionController(transport: transport, validator: LocalLaunchValidator(files: TestLaunchFiles()))
        let initial = try TerminalSize(columns: 80, rows: 24)
        let latest = try TerminalSize(columns: 120, rows: 40)
        let start = Task { await session.start(LocalLaunchConfiguration(executable: "/bin/zsh", directory: "/tmp"), size: initial) }
        while transport.launchContinuation == nil { await Task.yield() }
        session.resize(latest)
        // A real transport has no descriptor until launch completes.
        transport.sizes.removeAll()
        transport.launchContinuation?.resume()
        await start.value
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(transport.sizes, [latest])
    }

    @MainActor
    func testRejectInaccessibleDirectory() async throws {
        let transport = TestSessionTransport()
        let session = LocalSessionController(
            transport: transport,
            validator: LocalLaunchValidator(files: TestLaunchFiles(directoryAccessible: false)))
        await session.start(
            LocalLaunchConfiguration(executable: "/bin/zsh", directory: "/denied"),
            size: try TerminalSize(columns: 80, rows: 24))
        XCTAssertEqual(session.state, .failed)
        XCTAssertEqual(session.failure, .inaccessibleDirectory)
        XCTAssertTrue(transport.launches.isEmpty)
    }

    @MainActor
    func testPreserveLaunchArguments() async throws {
        let transport = TestSessionTransport()
        let session = LocalSessionController(transport: transport, validator: LocalLaunchValidator(files: TestLaunchFiles()))
        let arguments = ["file with spaces", "$(must stay literal)", "it's literal", "", "one\ntwo"]
        let configuration = LocalLaunchConfiguration(
            executable: "/bin/tool with spaces", arguments: arguments,
            directory: "/directory with spaces", inheritedEnvironment: [:])
        let size = try TerminalSize(columns: 111, rows: 33)
        await session.start(configuration, size: size)
        XCTAssertEqual(transport.launches.first?.arguments, arguments)
        XCTAssertEqual(transport.launches.first?.directory, configuration.directory)
        XCTAssertEqual(transport.sizes, [size])
        XCTAssertEqual(session.processID, 42)
        XCTAssertEqual(session.state, .running)
    }

    func testStripControlSecrets() throws {
        let configuration = LocalLaunchConfiguration(
            executable: "/bin/zsh", directory: "/tmp",
            inheritedEnvironment: ["TRELLIS_TOKEN": "secret-a", "__TRELLIS_SOCKET": "secret-b", "trellis_grant": "secret-c", "PATH": "/bin", "GOOD": "before", "ITERM_SESSION_ID": "old"],
            environmentOverrides: ["GOOD": "after", "SPECIAL": "x=y"])
        let validated = try LocalLaunchValidator(files: TestLaunchFiles()).validate(configuration)
        XCTAssertEqual(validated.environment["GOOD"], "after")
        XCTAssertEqual(validated.environment["SPECIAL"], "x=y")
        XCTAssertFalse(validated.environmentArray.joined().contains("secret-"))
        XCTAssertNil(validated.environment["ITERM_SESSION_ID"])
        XCTAssertEqual(validated.environment["TERM"], "xterm-256color")
    }

    @MainActor
    func testExitAndCleanupOnce() async throws {
        let transport = TestSessionTransport()
        let session = LocalSessionController(transport: transport, validator: LocalLaunchValidator(files: TestLaunchFiles()))
        var exits = 0
        session.onExit = { _ in exits += 1 }
        await session.start(
            LocalLaunchConfiguration(executable: "/bin/zsh", directory: "/tmp"),
            size: try TerminalSize(columns: 80, rows: 24))
        session.stop(); session.stop()
        XCTAssertEqual(transport.signals, [SIGTERM])
        transport.onExit?(7); transport.onExit?(7)
        session.stop()
        XCTAssertEqual(exits, 1)
        XCTAssertEqual(session.exitCode, 7)
        XCTAssertEqual(session.state, .exited)
        XCTAssertNil(session.processID)
    }

    @MainActor
    func testFastExitCannotBeOverwrittenByRunningState() async throws {
        let transport = TestSessionTransport(); transport.exitDuringLaunch = true
        let session = LocalSessionController(transport: transport, validator: LocalLaunchValidator(files: TestLaunchFiles()))
        var states: [SessionState] = []
        session.onStateChanged = { states.append($0) }
        await session.start(
            LocalLaunchConfiguration(executable: "/bin/zsh", directory: "/tmp"),
            size: try TerminalSize(columns: 80, rows: 24))
        XCTAssertEqual(states, [.starting, .running, .exited])
        XCTAssertEqual(session.exitCode, 7)
        XCTAssertNil(session.processID)
    }

    func testRejectInvalidLaunchValuesAndReservedOverrides() throws {
        let validator = LocalLaunchValidator(files: TestLaunchFiles())
        for configuration in [
            LocalLaunchConfiguration(executable: "relative", directory: "/tmp"),
            LocalLaunchConfiguration(executable: "/bin/zsh", arguments: ["bad\0arg"], directory: "/tmp"),
            LocalLaunchConfiguration(executable: "/bin/zsh", directory: "relative"),
            LocalLaunchConfiguration(executable: "/bin/zsh", directory: "/tmp", environmentOverrides: ["TRELLIS_TOKEN": "secret"]),
            LocalLaunchConfiguration(executable: "/bin/zsh", directory: "/tmp", environmentOverrides: ["BAD=KEY": "x"])
        ] { XCTAssertThrowsError(try validator.validate(configuration)) }
    }
}
