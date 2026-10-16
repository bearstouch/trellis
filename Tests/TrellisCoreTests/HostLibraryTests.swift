import Darwin
import XCTest
@testable import TrellisCore

final class HostLibraryTests: XCTestCase {
    func testS018_UT01_validateHostBoundaries() throws {
        let keys: Set<String> = ["/Users/me/.ssh/id_ed25519"]
        func check(_ draft: HostDraft) -> [HostField: String] {
            do {
                _ = try draft.validated(isRegularFile: keys.contains)
                return [:]
            } catch { return error.fields }
        }
        let valid = HostDraft(name: " Prod ", destination: "api.example.com", user: "deploy", port: "1", identityFile: "/Users/me/.ssh/id_ed25519", tags: "prod, API, prod")
        let accepted = try valid.validated(isRegularFile: keys.contains)
        XCTAssertEqual(accepted.name, "Prod")
        XCTAssertEqual(accepted.port, 1)
        XCTAssertEqual(accepted.tags, ["prod", "API"])
        XCTAssertEqual(check(HostDraft(name: "a", destination: "prod-alias", port: "65535")), [:])
        XCTAssertEqual(check(HostDraft(name: "v6", destination: "[fe80::1%en0]")), [:])

        XCTAssertNotNil(check(HostDraft(name: "a", destination: "h", port: "0"))[.port])
        XCTAssertNotNil(check(HostDraft(name: "a", destination: "h", port: "65536"))[.port])
        XCTAssertNotNil(check(HostDraft(name: "a", destination: "h", port: "２２"))[.port])
        XCTAssertNotNil(check(HostDraft(name: "a", destination: "-oProxyCommand=touch /tmp/x"))[.destination])
        XCTAssertNotNil(check(HostDraft(name: "a", destination: "user@host"))[.destination])
        XCTAssertNotNil(check(HostDraft(name: "a", destination: "host\u{7}"))[.destination])
        XCTAssertNotNil(check(HostDraft(name: "a", destination: "two words"))[.destination])
        XCTAssertNotNil(check(HostDraft(name: "a\u{1b}[31m", destination: "h"))[.name])
        XCTAssertNotNil(check(HostDraft(name: "a", destination: "h", user: "-lroot"))[.user])
        XCTAssertNotNil(check(HostDraft(name: "a", destination: "h", identityFile: "id_ed25519"))[.identityFile])
        XCTAssertNotNil(check(HostDraft(name: "a", destination: "h", identityFile: "/Users/me/.ssh/missing"))[.identityFile])
        XCTAssertNotNil(check(HostDraft(name: "a", destination: "h", identityFile: "/Users/me/../me/.ssh/id_ed25519"))[.identityFile])
        // Every invalid field is reported at once, each with an actionable message.
        let all = check(HostDraft(name: "", destination: "", port: "x", identityFile: "rel"))
        XCTAssertEqual(Set(all.keys), [.name, .destination, .port, .identityFile])
        XCTAssertTrue(all[.port]!.contains("1 to 65535"))
    }

    func testS018_UT02_searchAcrossMetadata() async throws {
        let library = HostLibrary(storage: MemoryHostStorage())
        let db = try await library.create(HostDraft(name: "Database", destination: "db.internal", tags: "Prod, sql"))
        let api = try await library.create(HostDraft(name: "API", destination: "api.example.com", user: "Deploy", tags: "prod"))
        let lab = try await library.create(HostDraft(name: "Lab box", destination: "lab-alias", tags: "test"))
        let ids = { (hosts: [SavedHost]) in hosts.map(\.id) }
        let all = await library.hosts
        var found: [String: [UUID]] = [:]
        for query in ["PROD", "example", "deploy", "prod SQL", "LAB", "  ", "nothing"] { found[query] = await library.search(query).map(\.id) }
        XCTAssertEqual(ids(all), [api.id, db.id, lab.id], "Display order is by name")
        XCTAssertEqual(found["PROD"], [api.id, db.id])
        XCTAssertEqual(found["example"], [api.id])
        XCTAssertEqual(found["deploy"], [api.id])
        XCTAssertEqual(found["prod SQL"], [db.id])
        XCTAssertEqual(found["LAB"], [lab.id])
        XCTAssertEqual(found["  "], ids(all))
        XCTAssertEqual(found["nothing"], [])
        XCTAssertEqual(ids(SavedHost.search(all.reversed(), query: "prod")), [db.id, api.id], "Search keeps the caller's order")
    }

    func testS018_UT03_editDoesNotMutateLiveLaunch() async throws {
        let library = HostLibrary(storage: MemoryHostStorage())
        let host = try await library.create(HostDraft(name: "Prod", destination: "old.example.com", user: "deploy", port: "2222"))
        let store = try WorkspaceStore()
        _ = try await store.execute(.createWindow(name: "Ops"))
        let initial = await store.snapshot()
        let pane = try XCTUnwrap(initial.panes.keys.first)
        _ = try await store.execute(.configureStoppedSession(paneID: pane, launch: .host(host.id)))
        let started = try await store.execute(.startSession(paneID: pane, resolvedLaunch: host.connectionLaunch))
        guard case .start(let request) = try XCTUnwrap(started.effects.first) else { return XCTFail("No launch") }
        _ = try await store.execute(.completeLaunch(sessionID: request.sessionID, attemptID: request.attemptID, outcome: .started(processID: 4242)))
        let liveSnapshot = await store.snapshot()
        let live = try XCTUnwrap(liveSnapshot.sessions[request.sessionID])
        XCTAssertEqual(live.launch, .process(executable: "/usr/bin/ssh", arguments: ["-p", "2222", "-l", "deploy", "--", "old.example.com"], directory: nil))

        let edited = try await library.update(id: host.id, HostDraft(name: "Prod", destination: "new.example.com", user: "deploy", port: "2222"), expectedRevision: host.revision)
        XCTAssertGreaterThan(edited.revision, host.revision)
        XCTAssertEqual(edited.connectionLaunch, .process(executable: "/usr/bin/ssh", arguments: ["-p", "2222", "-l", "deploy", "--", "new.example.com"], directory: nil))
        let afterSnapshot = await store.snapshot()
        let after = try XCTUnwrap(afterSnapshot.sessions[request.sessionID])
        XCTAssertEqual(after, live, "The running session keeps its frozen descriptor")

        // A stale editor cannot overwrite the newer revision; an unchanged save keeps the revision.
        do {
            _ = try await library.update(id: host.id, HostDraft(name: "Stale", destination: "x"), expectedRevision: host.revision)
            XCTFail("Stale update accepted")
        } catch { XCTAssertEqual(error, .conflict(expected: host.revision, actual: edited.revision)) }
        let unchanged = try await library.update(id: host.id, edited.draft, expectedRevision: edited.revision)
        XCTAssertEqual(unchanged, edited)
    }

    func testS018_UT04_deleteDoesNotTouchSshFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-hosts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ssh = root.appendingPathComponent("ssh", isDirectory: true), state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        var originals: [URL: Data] = [:]
        for name in ["id_ed25519", "config", "known_hosts"] {
            let url = ssh.appendingPathComponent(name)
            originals[url] = Data("\(name) fixture\n".utf8)
            try originals[url]!.write(to: url)
        }
        let key = ssh.appendingPathComponent("id_ed25519").path
        let storage = RecordingHostStorage(base: HostFileStorage(directory: state))
        let library = HostLibrary(storage: storage)
        let host = try await library.create(HostDraft(name: "Prod", destination: "prod", identityFile: key))
        let store = try WorkspaceStore()
        _ = try await store.execute(.createWindow(name: "Ops"))
        let initial = await store.snapshot()
        let pane = try XCTUnwrap(initial.panes.keys.first)
        let started = try await store.execute(.startSession(paneID: pane, resolvedLaunch: host.connectionLaunch))
        guard case .start(let request) = try XCTUnwrap(started.effects.first) else { return XCTFail("No launch") }
        let running = try await store.execute(.completeLaunch(sessionID: request.sessionID, attemptID: request.attemptID, outcome: .started(processID: 4242))).snapshot

        try await library.delete(id: host.id)
        let remaining = await library.hosts
        XCTAssertEqual(remaining, [])
        XCTAssertEqual(storage.writes, 2, "Only the app-owned host document was written")
        let afterDelete = await store.snapshot()
        XCTAssertEqual(afterDelete, running, "No session was signalled, closed, or changed")
        for (url, data) in originals { XCTAssertEqual(try Data(contentsOf: url), data, url.lastPathComponent) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ssh.path).sorted(), ["config", "id_ed25519", "known_hosts"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: state.path).sorted(), ["hosts.backup.json", "hosts.json"])
        let stored = try Data(contentsOf: state.appendingPathComponent("hosts.json"))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("fixture"), "Key contents are never stored")
    }

    func testHostFilePersistsOwnerOnlyAndReloads() async throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-hosts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let library = HostLibrary(storage: HostFileStorage(directory: state))
        let host = try await library.create(HostDraft(name: "Prod", destination: "prod", port: "22", tags: "a"))
        var info = stat()
        XCTAssertEqual(stat(state.appendingPathComponent("hosts.json").path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let reloaded = HostLibrary(storage: HostFileStorage(directory: state))
        let loaded = await reloaded.load()
        XCTAssertTrue(loaded)
        let reloadedHosts = await reloaded.hosts
        XCTAssertEqual(reloadedHosts, [host])
    }

    func testUnreadableOrTamperedLibraryIsPreservedAndReadOnly() async throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-hosts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let file = state.appendingPathComponent("hosts.json")
        let library = HostLibrary(storage: HostFileStorage(directory: state))
        let host = try await library.create(HostDraft(name: "Prod", destination: "prod"))
        // A hand edit introducing an option-like destination is rejected on load.
        let tampered = String(decoding: try Data(contentsOf: file), as: UTF8.self).replacingOccurrences(of: "\"prod\"", with: "\"-oProxyCommand=x\"")
        try Data(tampered.utf8).write(to: file)
        let reloaded = HostLibrary(storage: HostFileStorage(directory: state))
        let loadedTampered = await reloaded.load()
        XCTAssertFalse(loadedTampered)
        do {
            _ = try await reloaded.create(HostDraft(name: "New", destination: "new"))
            XCTFail("Wrote over an unreadable library")
        } catch { XCTAssertEqual(error, .readOnly) }
        XCTAssertEqual(String(decoding: try Data(contentsOf: file), as: UTF8.self), tampered)

        try await reloaded.resetUnreadable()
        let stillFailed = await reloaded.loadFailed
        XCTAssertFalse(stillFailed)
        let kept = try FileManager.default.contentsOfDirectory(atPath: state.path).filter { $0.hasPrefix("hosts.unreadable.") }
        XCTAssertEqual(kept.count, 1)
        let created = try await reloaded.create(HostDraft(name: "New", destination: "new"))
        XCTAssertNotEqual(host.id, created.id)
    }

    func testFailedWriteKeepsPreviousLibrary() async throws {
        let storage = MemoryHostStorage()
        let library = HostLibrary(storage: storage)
        let host = try await library.create(HostDraft(name: "Prod", destination: "prod"))
        storage.failWrites = true
        do {
            _ = try await library.create(HostDraft(name: "Other", destination: "other"))
            XCTFail("Write failure ignored")
        } catch { XCTAssertEqual(error, .io(EIO)) }
        do {
            try await library.delete(id: host.id)
            XCTFail("Write failure ignored")
        } catch { XCTAssertEqual(error, .io(EIO)) }
        let unchangedHosts = await library.hosts
        XCTAssertEqual(unchangedHosts, [host])
    }
}

final class MemoryHostStorage: HostStorage, @unchecked Sendable {
    var data: Data?
    var failWrites = false
    var writeCount = 0
    func read() throws -> Data? { data }
    func write(_ data: Data) throws {
        if failWrites { throw CocoaError(.fileWriteUnknown) }
        writeCount += 1
        self.data = data
    }
    func preserveUnreadable() throws {}
}

final class RecordingHostStorage: HostStorage, @unchecked Sendable {
    let base: HostFileStorage
    var writes = 0
    init(base: HostFileStorage) { self.base = base }
    func read() throws -> Data? { try base.read() }
    func write(_ data: Data) throws {
        writes += 1
        try base.write(data)
    }
    func preserveUnreadable() throws { try base.preserveUnreadable() }
}
