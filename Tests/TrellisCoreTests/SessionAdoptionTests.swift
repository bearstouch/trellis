import Darwin
import XCTest
@testable import TrellisCore

@MainActor
private final class KeptTransport: LocalSessionTransport {
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32?) -> Void)?
    var onInputError: ((Error) -> Void)?
    var launches = 0, signals: [Int32] = [], sent: [Data] = []
    func launch(_ configuration: ValidatedLocalLaunch, size: TerminalSize) async throws -> Int32 { launches += 1; return 77 }
    func send(_ data: Data) throws { sent.append(data) }
    func resize(_ size: TerminalSize) {}
    func signalGroup(_ signal: Int32) { signals.append(signal) }
}

/// FR-R03: a restored stopped session takes over a process the broker kept; nothing is spawned.
final class SessionAdoptionTests: XCTestCase {
    func testStoreAdoptsOnlyAStoppedSessionWithAUniqueProcess() async throws {
        let store = try WorkspaceStore()
        let first = try await store.execute(.createWindow(name: "One")).snapshot
        let sessionID = try XCTUnwrap(first.sessions.keys.first)
        let adopted = try await store.execute(.adoptRunningSession(sessionID: sessionID, processID: 4242))
        XCTAssertEqual(adopted.snapshot.sessions[sessionID]?.state, .running)
        XCTAssertEqual(adopted.snapshot.sessions[sessionID]?.processID, 4242)
        XCTAssertNil(adopted.snapshot.sessions[sessionID]?.launchAttemptID)
        XCTAssertTrue(adopted.effects.isEmpty, "Adopting never asks for a launch")
        do { _ = try await store.execute(.adoptRunningSession(sessionID: sessionID, processID: 4243)); XCTFail("Running sessions can't adopt") } catch {
            XCTAssertEqual(error as? WorkspaceError, .invalidTransition)
        }
        let second = try await store.execute(.createWindow(name: "Two")).snapshot
        let other = try XCTUnwrap(second.sessions.keys.first { $0 != sessionID })
        let before = await store.snapshot()
        do { _ = try await store.execute(.adoptRunningSession(sessionID: other, processID: 4242)); XCTFail("A PID has one owner") } catch {}
        do { _ = try await store.execute(.adoptRunningSession(sessionID: other, processID: 0)); XCTFail("Invalid PID") } catch {}
        do { _ = try await store.execute(.adoptRunningSession(sessionID: UUID(), processID: 9)); XCTFail("Unknown session") } catch {
            XCTAssertEqual(error as? WorkspaceError, .notFound)
        }
        let after = await store.snapshot()
        XCTAssertEqual(after, before, "A refused adoption changes nothing")
        let paneID = try XCTUnwrap(after.panes.values.first { $0.sessionID == other }?.id)
        _ = try await store.execute(.startSession(paneID: paneID))
        do { _ = try await store.execute(.adoptRunningSession(sessionID: other, processID: 5000)); XCTFail("A launch attempt can't be adopted") } catch {
            XCTAssertEqual(error as? WorkspaceError, .invalidTransition)
        }
        let exit = try await store.execute(.recordSessionExit(sessionID: sessionID, code: 0))
        XCTAssertEqual(exit.snapshot.sessions[sessionID]?.state, .exited)
    }

    @MainActor
    func testControllerAdoptsWithoutLaunchingAndReportsTheLaterExit() async throws {
        let original = KeptTransport(), kept = KeptTransport()
        let session = LocalSessionController(transport: original)
        var exits: [Int32?] = [], states: [SessionState] = []
        session.onExit = { exits.append($0) }
        session.onStateChanged = { states.append($0) }
        XCTAssertTrue(session.replaceTransport(kept))
        XCTAssertFalse(session.adopt(processID: 0))
        XCTAssertTrue(session.adopt(processID: 99))
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.processID, 99)
        XCTAssertFalse(session.replaceTransport(original), "A running session keeps its owner")
        XCTAssertFalse(session.adopt(processID: 100))
        try session.send(Data("x".utf8))
        XCTAssertEqual(kept.sent, [Data("x".utf8)])
        original.onExit?(1)
        XCTAssertEqual(session.state, .running, "The replaced transport is disconnected")
        session.stop(signal: SIGHUP)
        XCTAssertEqual(kept.signals, [SIGHUP])
        kept.onExit?(129)
        XCTAssertEqual(exits, [129])
        XCTAssertEqual(states, [.running, .closing, .exited])
        XCTAssertEqual(original.launches + kept.launches, 0)
    }

    func testSessionSettingsDefaultOffAndRoundTripWithoutRuntimeState() async throws {
        let old = Data(#"{"shell":"/bin/zsh","directory":"/tmp"}"#.utf8)
        let decoded = try JSONDecoder().decode(WorkspaceSettings.self, from: old)
        XCTAssertFalse(decoded.keepSessionsRunning)
        XCTAssertFalse(decoded.restoreScrollback)
        let invalid = Data(#"{"shell":"/bin/zsh","directory":"/tmp","keepSessionsRunning":"yes"}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(WorkspaceSettings.self, from: invalid).keepSessionsRunning, "An unusable value is off")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-session-settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WorkspacePersistence(directory: directory)
        _ = await persistence.load()
        let store = try WorkspaceStore()
        let created = try await store.execute(.createWindow(name: "Kept")).snapshot
        let sessionID = try XCTUnwrap(created.sessions.keys.first)
        let running = try await store.execute(.adoptRunningSession(sessionID: sessionID, processID: 31337)).snapshot
        var settings = WorkspaceSettings()
        settings.keepSessionsRunning = true; settings.restoreScrollback = true
        try await persistence.save(running, settings: settings, sequence: 1)
        let text = try String(contentsOf: persistence.currentURL, encoding: .utf8)
        XCTAssertFalse(text.contains("31337"), "PIDs are never saved")
        XCTAssertFalse(text.contains("running"), "Session states are never saved")
        guard case .loaded(let restored) = await WorkspacePersistence(directory: directory).load() else { return XCTFail("Not loaded") }
        XCTAssertTrue(restored.settings.keepSessionsRunning)
        XCTAssertTrue(restored.settings.restoreScrollback)
        XCTAssertEqual(restored.snapshot.sessions[sessionID]?.state, .stopped)
    }
}
