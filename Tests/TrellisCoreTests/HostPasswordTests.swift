import Darwin
import XCTest
@testable import TrellisCore

final class MemoryHostSecrets: HostSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: Data] = [:]
    var failStores = false
    var reads = 0
    subscript(id: UUID) -> Data? { lock.withLock { values[id] } }
    func store(_ password: Data, hostID: UUID) throws {
        try lock.withLock {
            if failStores { throw HostSecretError.unavailable(errSecAuthFailed) }
            values[hostID] = password
        }
    }
    func read(hostID: UUID) throws -> Data? {
        lock.withLock {
            reads += 1; return values[hostID]
        }
    }
    func remove(hostID: UUID) { _ = lock.withLock { values.removeValue(forKey: hostID) } }
}

struct FixedGate: UserPresenceGate {
    let allow: Bool
    func authorize(reason: String) async -> Bool { allow }
}

final class HostPasswordTests: XCTestCase {
    private let secret = Data("s3cret-PASSWORD-VALUE".utf8)

    private func library() async throws -> (HostLibrary, MemoryHostStorage, MemoryHostSecrets, SavedHost) {
        let storage = MemoryHostStorage(), secrets = MemoryHostSecrets()
        let library = HostLibrary(storage: storage, secrets: secrets)
        let host = try await library.create(HostDraft(name: "Prod", destination: "prod", user: "deploy"))
        return (library, storage, secrets, host)
    }

    func testSaveStoresInKeychainOnlyAndNeverInHostFile() async throws {
        let (library, storage, secrets, host) = try await library()
        let saved = try await library.setPassword(id: host.id, .save(secret, requiresUserPresence: false), expectedRevision: host.revision)
        XCTAssertEqual(saved.savedPassword, SavedPasswordPolicy(requiresUserPresence: false))
        XCTAssertEqual(secrets[host.id], secret)
        XCTAssertGreaterThan(saved.connectionRevision, host.connectionRevision, "A new password invalidates host approvals")
        let file = try XCTUnwrap(storage.data)
        XCTAssertNil(file.range(of: secret), "hosts.json never contains the password")
        XCTAssertEqual(try HostLibraryCodec.decode(file).hosts.first?.savedPassword, saved.savedPassword, "The policy round-trips")
    }

    func testOlderHostFilesDecodeWithoutSavedPassword() throws {
        let json = #"{"schemaVersion":1,"revision":1,"hosts":[{"id":"\#(UUID().uuidString)","name":"A","destination":"a","tags":[],"revision":1}]}"#
        XCTAssertNil(try HostLibraryCodec.decode(Data(json.utf8)).hosts.first?.savedPassword)
    }

    func testReplacePolicyAndRemove() async throws {
        let (library, _, secrets, host) = try await library()
        var current = try await library.setPassword(id: host.id, .save(secret, requiresUserPresence: false), expectedRevision: host.revision)
        current = try await library.setPassword(id: host.id, .save(Data("other".utf8), requiresUserPresence: false), expectedRevision: current.revision)
        XCTAssertEqual(secrets[host.id], Data("other".utf8))
        let connection = current.connectionRevision
        current = try await library.setPassword(id: host.id, .policy(requiresUserPresence: true), expectedRevision: current.revision)
        XCTAssertEqual(current.savedPassword?.requiresUserPresence, true)
        XCTAssertEqual(current.connectionRevision, connection, "Only the gate changed")
        current = try await library.setPassword(id: host.id, .remove, expectedRevision: current.revision)
        XCTAssertNil(current.savedPassword)
        XCTAssertNil(secrets[host.id])
    }

    func testStaleEditorAndInvalidPasswordsAreRefused() async throws {
        let (library, _, secrets, host) = try await library()
        _ = try await library.update(id: host.id, HostDraft(name: "Renamed", destination: "prod", user: "deploy"), expectedRevision: host.revision)
        do {
            _ = try await library.setPassword(id: host.id, .save(secret, requiresUserPresence: false), expectedRevision: host.revision)
            XCTFail("Stale revision accepted")
        } catch { guard case .conflict = error else { return XCTFail("\(error)") } }
        let latest = await library.hosts.first
        let current = try XCTUnwrap(latest)
        for bad in ["", "line\nbreak", "cr\rhere", String(repeating: "x", count: HostPassword.byteLimit + 1)] {
            do {
                _ = try await library.setPassword(id: host.id, .save(Data(bad.utf8), requiresUserPresence: false), expectedRevision: current.revision)
                XCTFail("Invalid password accepted")
            } catch { guard case .invalid(let validation) = error, validation.fields[.password] != nil else { return XCTFail("\(error)") } }
        }
        XCTAssertNil(secrets[host.id])
    }

    func testLongestPasswordSSHCanReadIsAccepted() throws {
        // ssh reads at most 1023 bytes of askpass output; 1024 would arrive truncated.
        XCTAssertEqual(HostPassword.byteLimit, 1023)
        XCTAssertEqual(try HostPassword.validated(String(repeating: "x", count: 1023)).count, 1023)
    }

    func testKeychainFailureLeavesHostUnchanged() async throws {
        let (library, _, secrets, host) = try await library()
        secrets.failStores = true
        do {
            _ = try await library.setPassword(id: host.id, .save(secret, requiresUserPresence: false), expectedRevision: host.revision)
            XCTFail("Keychain failure ignored")
        } catch { XCTAssertEqual(error, .secretStore) }
        let hosts = await library.hosts
        XCTAssertEqual(hosts, [host])
    }

    func testMetadataWriteFailureRestoresPreviousKeychainValue() async throws {
        let (library, storage, secrets, host) = try await library()
        let saved = try await library.setPassword(id: host.id, .save(secret, requiresUserPresence: false), expectedRevision: host.revision)
        storage.failWrites = true
        do {
            _ = try await library.setPassword(id: host.id, .save(Data("new".utf8), requiresUserPresence: false), expectedRevision: saved.revision)
            XCTFail("Write failure ignored")
        } catch { XCTAssertEqual(error, .io(EIO)) }
        XCTAssertEqual(secrets[host.id], secret, "The previous password is restored")
        let hosts = await library.hosts
        XCTAssertEqual(hosts, [saved])
    }

    func testDeleteRemovesKeychainItem() async throws {
        let (library, _, secrets, host) = try await library()
        let saved = try await library.setPassword(id: host.id, .save(secret, requiresUserPresence: false), expectedRevision: host.revision)
        try await library.delete(id: host.id, expectedRevision: saved.revision)
        XCTAssertNil(secrets[host.id])
    }

    func testConnectionChangeDropsPasswordButRenameKeepsIt() async throws {
        let (library, _, secrets, host) = try await library()
        var current = try await library.setPassword(id: host.id, .save(secret, requiresUserPresence: true), expectedRevision: host.revision)
        current = try await library.update(id: host.id, HostDraft(name: "Prod API", destination: "prod", user: "deploy", tags: "api"), expectedRevision: current.revision)
        XCTAssertEqual(current.savedPassword?.requiresUserPresence, true)
        XCTAssertEqual(secrets[host.id], secret)
        current = try await library.update(id: host.id, HostDraft(name: "Prod API", destination: "elsewhere", user: "deploy"), expectedRevision: current.revision)
        XCTAssertNil(current.savedPassword, "A password is never offered to a different server")
        XCTAssertNil(secrets[host.id])
    }

    func testImportReplacementWithNewConnectionDropsPassword() async throws {
        let (library, _, secrets, host) = try await library()
        let saved = try await library.setPassword(id: host.id, .save(secret, requiresUserPresence: false), expectedRevision: host.revision)
        var changes = HostLibrary.ImportChanges()
        changes.replacements = [(id: host.id, draft: HostDraft(name: "Prod", destination: "moved"), expectedRevision: saved.revision)]
        let undo = try await library.applyImport(changes)
        let imported = await library.hosts.first
        XCTAssertNil(imported?.savedPassword)
        XCTAssertNil(secrets[host.id])
        try await library.revertImport(undo)
        let reverted = await library.hosts.first
        XCTAssertEqual(reverted?.destination, "prod")
        XCTAssertNil(reverted?.savedPassword, "Revert never claims a password the Keychain no longer has")
    }

    func testPasswordReadAppliesPolicyAndConnectionRevision() async throws {
        let (library, _, secrets, host) = try await library()
        let saved = try await library.setPassword(id: host.id, .save(secret, requiresUserPresence: true), expectedRevision: host.revision)
        let denied = await library.password(hostID: host.id, connectionRevision: saved.connectionRevision, gate: FixedGate(allow: false))
        XCTAssertNil(denied)
        XCTAssertEqual(secrets.reads, 0, "A denied confirmation never reads the Keychain")
        let allowed = await library.password(hostID: host.id, connectionRevision: saved.connectionRevision, gate: FixedGate(allow: true))
        XCTAssertEqual(allowed, secret)
        let stale = await library.password(hostID: host.id, connectionRevision: host.connectionRevision, gate: FixedGate(allow: true))
        XCTAssertNil(stale, "A session started for an older connection gets nothing")
        let unknown = await library.password(hostID: UUID(), connectionRevision: saved.connectionRevision, gate: FixedGate(allow: true))
        XCTAssertNil(unknown)
    }
}
