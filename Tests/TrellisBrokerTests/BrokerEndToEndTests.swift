import Darwin
import Foundation
import XCTest
@testable import TrellisBroker

/// Drives the built `trellis-broker`, detached as the app starts it. The test runner stands in for the app.
@MainActor
final class BrokerEndToEndTests: XCTestCase {
    private var launchers: [BrokerLauncher] = []
    private var connections: [BrokerConnection] = []

    private func launcher(client: String? = nil, idleExit: Int = 5) throws -> BrokerLauncher {
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent(BrokerProtocol.helperName).path
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw XCTSkip("Run `swift build` first to build \(BrokerProtocol.helperName).") }
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-broker-state-\(UUID())")
        let me = try XCTUnwrap(BrokerLauncher.currentExecutable())
        let launcher = BrokerLauncher(stateDirectory: state, helperPath: helper, clientPath: client ?? me, idleExit: idleExit)
        launchers.append(launcher)
        return launcher
    }

    override func tearDown() async throws {
        // Never leave a broker or its sessions behind: a broker refuses a second client, so stop it through ours first.
        for connection in connections where connection.isOpen { connection.sendStopAll() }
        try? await Task.sleep(for: .milliseconds(100))
        connections.forEach { $0.close() }
        connections = []
        for launcher in launchers {
            if let path = launcher.discovery()?.socketPath, let connection = try? BrokerConnection.connect(socketPath: path, brokerExecutable: launcher.helperPath) {
                connection.sendStopAll()
                try? await Task.sleep(for: .milliseconds(100))
                connection.close()
            }
            try? FileManager.default.removeItem(at: launcher.stateDirectory)
        }
        launchers = []
    }

    private func connect(_ launcher: BrokerLauncher, socket: String) async throws -> BrokerConnection {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            // A just-closed client may not have been noticed yet; the broker then refuses as busy.
            if let connection = try? BrokerConnection.connect(socketPath: socket, brokerExecutable: launcher.helperPath), (try? await connection.hello()) != nil {
                connections.append(connection)
                return connection
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw BrokerClientError.timedOut
    }

    private func start(_ launcher: BrokerLauncher) async throws -> (String, BrokerConnection) {
        let socket = try launcher.spawn()
        launcher.publish(socketPath: socket)
        return (socket, try await connect(launcher, socket: socket))
    }

    private func spawn(_ connection: BrokerConnection, _ script: String, sink: Sink) async throws -> UUID {
        let id = UUID()
        connection.register(sink, sessionID: id)
        let reply = try await connection.request(
            .spawn(BrokerSpawnRequest(sessionID: id, executable: "/bin/sh", arguments: ["/bin/sh", "-c", script], environment: ["PATH=/usr/bin:/bin"], directory: "/", columns: 80, rows: 24)))
        guard case .spawned(_, let pid) = reply else { XCTFail("\(reply)"); return id }
        XCTAssertGreaterThan(pid, 0)
        return id
    }

    private func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testSessionSurvivesDisconnectThenReplaysAndTakesInput() async throws {
        let launcher = try launcher()
        let (socket, first) = try await start(launcher)
        let sink = Sink()
        let id = try await spawn(first, "printf 'ready\\n'; read line; printf 'got:%s\\n' \"$line\"; exec sleep 600", sink: sink)
        try await waitFor { sink.text.contains("ready") }
        first.close()

        let second = try await connect(launcher, socket: socket)
        guard case .sessions(let records) = try await second.request(.list) else { return XCTFail("No listing") }
        XCTAssertEqual(records.map(\.sessionID), [id])
        XCTAssertEqual(records.first?.running, true)
        let adopted = Sink()
        second.register(adopted, sessionID: id)
        guard case .attached(let attachment) = try await second.request(.attach(sessionID: id, columns: 100, rows: 30)) else { return XCTFail("Not attached") }
        XCTAssertTrue(attachment.record.running)
        XCTAssertTrue(String(decoding: adopted.replay, as: UTF8.self).contains("ready"), "Output from before the disconnect is replayed")
        try second.sendInput(Data("hello\n".utf8), sessionID: id)
        try await waitFor { adopted.text.contains("got:hello") }

        let r1 = try await second.request(.signal(sessionID: id, signal: SIGHUP))

        XCTAssertEqual(r1, .ok)
        try await waitFor { adopted.exit != nil }
        XCTAssertEqual(adopted.exit.map(BrokerSessionRecord.exitCode), 128 + SIGHUP)
        let r2 = try await second.request(.release(sessionID: id))

        XCTAssertEqual(r2, .ok)
        guard case .sessions(let after) = try await second.request(.list) else { return XCTFail("No listing") }
        XCTAssertTrue(after.isEmpty)
    }

    func testInputOverTheLimitIsReportedNotDroppedSilently() async throws {
        let launcher = try launcher()
        let (_, connection) = try await start(launcher)
        let sink = Sink()
        // A program that never reads: input piles up in the broker.
        let id = try await spawn(connection, "printf 'ready\\n'; exec sleep 600", sink: sink)
        try await waitFor { sink.text.contains("ready") }
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 512 * 1024)
        for _ in 0..<4 { try connection.sendInput(chunk, sessionID: id) }
        try await waitFor { sink.rejected > 0 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sink.rejected, 1, "One report per overflow, not one per chunk")
    }

    func testAnInputTooLargeForTheOutboxSendsNothing() async throws {
        let launcher = try launcher()
        let (_, connection) = try await start(launcher)
        let sink = Sink()
        let id = try await spawn(connection, "exec sleep 600", sink: sink)
        XCTAssertThrowsError(try connection.sendInput(Data(count: BrokerConnection.outboxLimit + 1), sessionID: id)) {
            XCTAssertEqual($0 as? BrokerClientError, .queueFull)
        }
        // Nothing was queued, so a normal input still fits whole.
        XCTAssertNoThrow(try connection.sendInput(Data(count: BrokerConnection.outboxLimit / 2), sessionID: id))
    }

    func testExitStatusIsReportedAndRefusedSignalsAreNotSent() async throws {
        let launcher = try launcher()
        let (_, connection) = try await start(launcher)
        let sink = Sink()
        let id = try await spawn(connection, "exit 3", sink: sink)
        try await waitFor { sink.exit != nil }
        XCTAssertEqual(sink.exit.map(BrokerSessionRecord.exitCode), 3)
        let r3 = try await connection.request(.signal(sessionID: id, signal: SIGHUP))

        XCTAssertEqual(r3, .failed(code: "SIGNAL_REFUSED", errno: 0), "An ended session's PID is never signalled")
        let other = try await spawn(connection, "exec sleep 600", sink: Sink())
        let r4 = try await connection.request(.signal(sessionID: other, signal: SIGSTOP))

        XCTAssertEqual(r4, .failed(code: "SIGNAL_REFUSED", errno: 0))
        let r5 = try await connection.request(.release(sessionID: other))

        XCTAssertEqual(r5, .failed(code: "SESSION_RUNNING", errno: 0))
    }

    /// Review: the app reads one chunk at a time (bounded UI backlog); a large burst must still arrive whole and in order.
    func testLargeOutputArrivesWholeWithOneReadInFlight() async throws {
        let launcher = try launcher()
        let (_, connection) = try await start(launcher)
        let sink = Sink()
        _ = try await spawn(connection, "stty -opost; head -c 3000000 /dev/zero | tr '\\0' a; printf END", sink: sink)
        try await waitFor(20) { sink.output.count >= 3_000_003 }
        XCTAssertEqual(sink.output.count, 3_000_003)
        XCTAssertTrue(sink.text.hasSuffix("aEND"))
    }

    func testOnlyTheNamedClientMayConnect() async throws {
        let launcher = try launcher(client: "/usr/bin/true")
        let socket = try launcher.spawn()
        let deadline = Date().addingTimeInterval(3)
        var refused = false
        while Date() < deadline, !refused {
            if let connection = try? BrokerConnection.connect(socketPath: socket, brokerExecutable: launcher.helperPath) {
                do { try await connection.hello() } catch { refused = true }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(refused, "A peer that isn't the --client executable is disconnected before any request")
        // The broker has no session and no client, so it exits by itself.
        try await waitFor(10) { !FileManager.default.fileExists(atPath: socket) }
    }

    func testTheAppRefusesAListenerThatIsNotTheBroker() throws {
        let launcher = try launcher()
        XCTAssertThrowsError(try BrokerConnection.connect(socketPath: "/nonexistent/s", brokerExecutable: launcher.helperPath)) {
            XCTAssertEqual($0 as? BrokerClientError, .unavailable)
        }
    }

    func testIdleBrokerExitsAndRemovesItsSocket() async throws {
        let launcher = try launcher(idleExit: 1)
        let (socket, connection) = try await start(launcher)
        let sink = Sink()
        _ = try await spawn(connection, "exit 0", sink: sink)
        try await waitFor { sink.exit != nil }
        connection.close()
        try await waitFor(10) { !FileManager.default.fileExists(atPath: socket) }
        // The socket is unlinked just before its directory; give the broker the moment between them.
        try await waitFor(2) { !FileManager.default.fileExists(atPath: (socket as NSString).deletingLastPathComponent) }
    }
}

@MainActor
private final class Sink: BrokerSessionSink {
    var output = Data(), replay = Data(), exit: Int32?, disconnected = false, rejected = 0
    var text: String { String(decoding: output, as: UTF8.self) }
    func brokerOutput(_ data: Data) { output.append(data) }
    func brokerReplay(_ data: Data) { replay.append(data) }
    func brokerExited(waitStatus: Int32) { exit = waitStatus }
    func brokerPrompt(_ active: Bool) {}
    func brokerDisconnected() { disconnected = true }
    func brokerInputRejected() { rejected += 1 }
}
