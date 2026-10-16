import Darwin
import Foundation
import XCTest
@testable import TrellisCore

final class WorkspacePersistenceTests: XCTestCase {
    private enum InjectedFailure: Error { case beforeReplace }

    private static func fixture() async throws -> WorkspaceSnapshot {
        let store = try WorkspaceStore()
        let made = try await store.execute(.createWindow(name: "Project")).snapshot
        let first = try XCTUnwrap(made.panes.keys.first)
        _ = try await store.execute(.splitPane(id: first, axis: .x, availableSize: TerminalSize(columns: 80, rows: 24)))
        var state = await store.snapshot()
        let sessionIDs = Array(state.sessions.keys)
        for (index, id) in sessionIDs.enumerated() {
            state.sessions[id]?.state = .running
            state.sessions[id]?.processID = Int32(1000 + index)
            state.sessions[id]?.launch = .process(executable: "/bin/zsh", arguments: ["-l"], directory: "/tmp")
        }
        return state
    }

    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-persistence-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return path
    }

    func testRestoreNeverSpawns() async throws {
        let state = try await Self.fixture()
        let settings = WorkspaceSettings(shell: "/bin/zsh", directory: "/tmp", windowFrame: "{{10, 20}, {900, 600}}")
        let data = try WorkspaceSnapshotCodec.encode(state, settings: settings)
        let restored = try WorkspaceSnapshotCodec.decode(data)
        XCTAssertEqual(restored.snapshot.windows, state.windows)
        XCTAssertEqual(restored.snapshot.tabs, state.tabs)
        XCTAssertEqual(restored.snapshot.panes, state.panes)
        XCTAssertEqual(restored.settings, settings)
        for (id, session) in restored.snapshot.sessions {
            XCTAssertEqual(session.state, .stopped)
            XCTAssertNil(session.processID)
            XCTAssertNil(session.launchAttemptID)
            XCTAssertEqual(session.launch, state.sessions[id]?.launch)
        }
    }

    func testFailedAtomicWriteKeepsBackup() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = WorkspacePersistence(directory: directory)
        _ = await first.load()
        let state = try await Self.fixture()
        try await first.save(state, settings: WorkspaceSettings(), sequence: 1)
        let original = try Data(contentsOf: first.currentURL)
        let failing = WorkspacePersistence(
            directory: directory,
            beforeReplace: { target in
                if target.lastPathComponent == "workspace.json" { throw InjectedFailure.beforeReplace }
            })
        _ = await failing.load()
        var next = state; next.windows[0].name = "Changed"
        do { try await failing.save(next, settings: WorkspaceSettings(), sequence: 2); XCTFail("Write did not fail") } catch {}
        XCTAssertEqual(try Data(contentsOf: failing.currentURL), original)
        XCTAssertEqual(try Data(contentsOf: failing.backupURL), original)
        _ = try WorkspaceSnapshotCodec.decode(Data(contentsOf: failing.currentURL))
        _ = try WorkspaceSnapshotCodec.decode(Data(contentsOf: failing.backupURL))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".tmp") })
    }

    func testNewerSchemaIsReadOnly() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WorkspacePersistence(directory: directory)
        let original = Data("{\"schemaVersion\":999,\"futureData\":\"keep me\"}".utf8)
        try original.write(to: persistence.currentURL)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard case .recovery(reason: .unsupportedVersion(999), backup: _) = await persistence.load() else { return XCTFail("Expected newer-version recovery") }
        do { try await persistence.save(WorkspaceSnapshot(), settings: WorkspaceSettings(), sequence: 1); XCTFail("Rewrote future version") } catch {}
        do { try await persistence.authorizeRecovery(); XCTFail("Enabled writes over future version") } catch {}
        XCTAssertEqual(try Data(contentsOf: persistence.currentURL), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), before)
    }

    func testSnapshotOmitsSecretsAndBuffers() async throws {
        var state = try await Self.fixture()
        let marker = "DISTINCT_PRIVATE_TOKEN_INPUT_OUTPUT_\(UUID())"
        for id in state.sessions.keys {
            state.sessions[id]?.failureMessage = marker
            state.sessions[id]?.launch = .process(executable: "/bin/zsh", arguments: ["-c", marker], directory: "/tmp")
        }
        let data = try WorkspaceSnapshotCodec.encode(state, settings: WorkspaceSettings())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains(marker))
        for runtimeField in ["processID", "launchAttemptID", "failureMessage", "exitCode", "environment", "output", "transcript"] { XCTAssertFalse(text.contains(runtimeField)) }
        let restored = try WorkspaceSnapshotCodec.decode(data)
        XCTAssertEqual(restored.unconfiguredPaneIDs, Set(state.panes.keys))
        for session in restored.snapshot.sessions.values {
            guard case .process(let executable, let args, _) = session.launch else { return XCTFail("Expected unconfigured custom process") }
            XCTAssertTrue(executable.isEmpty); XCTAssertTrue(args.isEmpty)
        }
    }

    func testCorruptRecoveryPreservesOriginalAndBackupWithOwnerOnlyPermissions() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WorkspacePersistence(directory: directory)
        let corrupt = Data("broken workspace".utf8)
        let backup = try WorkspaceSnapshotCodec.encode(await Self.fixture(), settings: WorkspaceSettings())
        try corrupt.write(to: persistence.currentURL)
        try backup.write(to: persistence.backupURL)
        guard case .recovery(reason: .corrupt, backup: let restored?) = await persistence.load() else { return XCTFail("Expected recoverable backup") }
        XCTAssertEqual(try Data(contentsOf: persistence.currentURL), corrupt)
        try await persistence.authorizeRecovery()
        try await persistence.save(restored.snapshot, settings: restored.settings, sequence: 1)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let archive = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("workspace.corrupt.") })
        XCTAssertEqual(try Data(contentsOf: archive), corrupt)
        XCTAssertEqual(try Data(contentsOf: persistence.backupURL), backup)
        for path in [persistence.currentURL, archive] {
            let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        _ = try WorkspaceSnapshotCodec.decode(Data(contentsOf: persistence.currentURL))
    }

    func testPrototypeMigrationIsInMemoryUntilAtomicSave() async throws {
        let encoded = try WorkspaceSnapshotCodec.encode(await Self.fixture(), settings: WorkspaceSettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 0
        object.removeValue(forKey: "settings")
        let old = try JSONSerialization.data(withJSONObject: object)
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WorkspacePersistence(directory: directory)
        try old.write(to: persistence.currentURL)
        guard case .loaded(let restored) = await persistence.load() else { return XCTFail("Expected v0 migration") }
        XCTAssertEqual(try Data(contentsOf: persistence.currentURL), old)
        try await persistence.save(restored.snapshot, settings: restored.settings, sequence: 1)
        let updated = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: persistence.currentURL)) as? [String: Any])
        XCTAssertEqual(updated["schemaVersion"] as? Int, 1)
        XCTAssertEqual(try Data(contentsOf: persistence.backupURL), old)
    }

    func testNonregularStateFileEntersRecoveryWithoutBlocking() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WorkspacePersistence(directory: directory)
        XCTAssertEqual(mkfifo(persistence.currentURL.path, 0o600), 0)
        guard case .recovery(reason: .corrupt, backup: nil) = await persistence.load() else {
            return XCTFail("Nonregular state should enter recovery")
        }
        var info = stat()
        XCTAssertEqual(lstat(persistence.currentURL.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, mode_t(S_IFIFO))
    }

}
