import Darwin
import XCTest
import TrellisCore
@testable import TrellisControl

/// grants.json schema 2 (permissions.md#storage, migration.md "What happens on upgrade"), presets, and grant editing at
/// the store (API2-06c, API2-06d).
final class GrantStorageTests: XCTestCase {
    private let clock = TestClock()
    private let secrets = MemorySecrets()
    private var root: URL!
    private var url: URL { root.appendingPathComponent("grants.json") }
    private var backup: URL { root.appendingPathComponent("grants.json.v1.bak") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tgs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func store() -> GrantStore { GrantStore(url: url, secrets: secrets, now: { [clock] in clock.now }) }
    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        return stat(url.path, &info) == 0 ? info.st_mode & 0o777 : 0
    }

    /// A schema 1 file as protocol 1 builds wrote it: a bare array with `windowScope`/`windows` and v1 capability names.
    private func legacyFile(scoped: UUID, host: UUID, tokens: (String, String)) -> String {
        """
        [{"id":"\(UUID().uuidString)","name":"Reader","tokenHash":"\(GrantToken.hash(tokens.0))","capabilities":["metadata.read","session.output.read"],
          "windowScope":{"windows":{"_0":["\(scoped.uuidString)"]}},"hostScope":{"approved":{"_0":[{"hostID":"\(host.uuidString)","connectionRevision":3}]}},
          "createdAt":"2027-01-15T08:00:00Z","expiresAt":"2027-02-15T08:00:00Z"},
         {"id":"\(UUID().uuidString)","name":"Everything","tokenHash":"\(GrantToken.hash(tokens.1))",
          "capabilities":["metadata.read","layout.write","session.start","session.input","session.execute","session.output.read","session.close","theme.read","theme.write","host.read","host.write"],
          "windowScope":{"all":{}},"hostScope":{"all":{}},"createdAt":"2027-01-15T08:00:00Z","expiresAt":"2027-02-15T08:00:00Z","revokedAt":"2027-01-16T08:00:00Z"}]
        """
    }

    // MARK: - Migration

    func testASchema1FileMigratesOnceWithABackupAndGainsNothing() async throws {
        let scoped = UUID(), host = UUID()
        let original = legacyFile(scoped: scoped, host: host, tokens: ("trl_reader", "trl_all"))
        try OwnerOnlyFile.publish(Data(original.utf8), to: url)
        let migrated = store()
        await migrated.load()
        let grants = await migrated.grants
        XCTAssertEqual(grants.count, 2)
        let reader = try XCTUnwrap(grants.first { $0.name == "Reader" })
        XCTAssertEqual(reader.capabilitiesV2, [.workspaceRead, .sessionOutputRead], "Exactly the mapped capabilities")
        XCTAssertEqual(reader.capabilities, [.metadataRead, .sessionOutputRead], "Protocol 1 sees what it saw before")
        XCTAssertEqual(reader.preset, .custom)
        XCTAssertEqual(reader.revision, 1)
        XCTAssertEqual(reader.spaceScope, .spaces([scoped]))
        XCTAssertEqual(reader.hostScope, .approved([HostApproval(hostID: host, connectionRevision: 3)]))
        XCTAssertEqual(reader.projectScope, .all)
        XCTAssertEqual(reader.agentScope, .all)
        let everything = try XCTUnwrap(grants.first { $0.name == "Everything" })
        XCTAssertEqual(everything.capabilities, Set(Capability.allCases))
        XCTAssertTrue(everything.capabilitiesV2.isDisjoint(with: [.agentControl, .agentRespond, .agentInstall, .remoteConnect, .remoteManage, .projectRead, .projectWrite, .projectLaunch, .taskRead, .taskRun]))
        XCTAssertNotNil(everything.revokedAt)

        XCTAssertEqual(try text(backup), original, "The schema 1 file is kept byte for byte")
        XCTAssertEqual(mode(backup), 0o600)
        XCTAssertEqual(mode(url), 0o600)
        let written = try text(url)
        XCTAssertTrue(written.contains("\"schemaVersion\" : 2"), written)
        for legacy in ["windowScope", "\"windows\"", "metadata.read", "layout.write", "hostID"] { XCTAssertFalse(written.contains(legacy), "\(legacy) is never written") }

        // Loading schema 2 again reads it as is and leaves the backup alone.
        try OwnerOnlyFile.publish(Data("kept".utf8), to: backup)
        let reloaded = store()
        await reloaded.load()
        let again = await reloaded.grants
        XCTAssertEqual(again, grants)
        XCTAssertEqual(try text(backup), "kept")
        let token = await reloaded.activeGrant(token: "trl_reader")
        XCTAssertEqual(token?.id, reader.id, "The token still authenticates")
    }

    func testAMigratedGrantAuthorizesProtocol1ExactlyAsBefore() async throws {
        let domain = FakeDomain()
        try OwnerOnlyFile.publish(Data(legacyFile(scoped: domain.spaceA, host: UUID(), tokens: ("trl_reader", "trl_all")).utf8), to: url)
        let migrated = store()
        let handler = AuthorizingControlHandler(grants: migrated, domain: domain, limiter: AuthenticationRateLimiter(now: { [clock] in clock.now }))
        let session = ControlSession(peerUID: geteuid(), handler: handler)
        let auth = try await lastReply(session, request(1, "auth.authenticate", ["protocolVersion": .number(1), "token": .string("trl_reader")]))
        let result = try XCTUnwrap(auth["result"] as? [String: Any])
        XCTAssertEqual(result["capabilities"] as? [String], ["metadata.read", "session.output.read"])
        XCTAssertEqual(result["spaceScope"] as? [String], [domain.spaceA.uuidString])
        func code(_ id: Int, _ method: String, _ params: [String: JSONValue]) async throws -> String {
            let response = try await lastReply(session, request(id, method, params))
            return response["result"] != nil ? "OK" : appCode(response) ?? "?"
        }
        let list = try await code(2, "space.list", [:])
        XCTAssertEqual(list, "OK")
        let hidden = try await code(3, "space.get", ["id": .string(domain.spaceB.uuidString)])
        XCTAssertEqual(hidden, "NOT_FOUND")
        let denied = try await code(4, "tab.create", ["spaceId": .string(domain.spaceA.uuidString)])
        XCTAssertEqual(denied, "PERMISSION_DENIED")
    }

    func testUnreadableNewerOrCorruptFilesAreNeverOverwritten() async throws {
        let schema2 = #"{"schemaVersion":2,"grants":[]}"#
        let unknownCapability = try await grantRecord(capability: "future.capability"), plain = try await grantRecord(capability: "workspace.read")
        let cases = [
            ("newer", #"{"schemaVersion":3,"grants":[]}"#), ("corrupt", "{not json"), ("no schema", #"{"grants":[]}"#),
            ("unknown capability", schema2.replacingOccurrences(of: "[]", with: unknownCapability)),
            ("unknown scope", schema2.replacingOccurrences(of: "[]", with: plain.replacingOccurrences(of: #""spaces" : "all""#, with: #""spaces" : "mine""#))),
            ("legacy with an unknown capability", legacyFile(scoped: UUID(), host: UUID(), tokens: ("a", "b")).replacingOccurrences(of: "metadata.read", with: "future.capability"))
        ]
        for (label, contents) in cases {
            try OwnerOnlyFile.publish(Data(contents.utf8), to: url)
            try? FileManager.default.removeItem(at: backup)
            let broken = store()
            await broken.load()
            let failed = await broken.loadFailed, grants = await broken.grants
            XCTAssertTrue(failed, label)
            XCTAssertEqual(grants, [], label)
            do {
                _ = try await broken.create(GrantSettings(name: "New", capabilities: [.workspaceRead]), lifetime: 3600)
                XCTFail("\(label): wrote over an unreadable file")
            } catch { XCTAssertEqual(error, .readOnly, label) }
            XCTAssertEqual(try text(url), contents, "\(label): left untouched")
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "\(label): no backup of an unreadable file")
        }
    }

    /// One schema 2 record, written by the store itself, with its capability renamed.
    private func grantRecord(capability: String) async throws -> String {
        let scratch = GrantStore(url: root.appendingPathComponent("scratch.json"), secrets: secrets, now: { [clock] in clock.now })
        _ = try await scratch.create(GrantSettings(name: "R", capabilities: [.workspaceRead]), lifetime: 3600)
        let file = try text(root.appendingPathComponent("scratch.json"))
        let start = try XCTUnwrap(file.range(of: "\"grants\" : ["))
        let end = try XCTUnwrap(file.range(of: "]", options: .backwards))
        return "[" + file[start.upperBound..<end.lowerBound].replacingOccurrences(of: "workspace.read", with: capability) + "]"
    }

    func testEveryScopeKindRoundTripsThroughSchema2() async throws {
        let disk = store()
        let project = UUID(), host = UUID(), space = UUID()
        let settings = GrantSettings(
            name: "Orchestrator", preset: .agentOrchestrator, capabilities: GrantPreset.agentOrchestrator.capabilities!,
            scope: GrantScope(
                spaces: .created, projects: .projects([project]), hosts: .approved([HostApproval(hostID: host, connectionRevision: 2)]), agents: .agents(["trellis-codex"])))
        let (grant, token) = try await disk.create(settings, lifetime: 3600)
        disk.recordCreatedSpace(space, grant: grant.id)
        let live = await disk.activeGrant(token: token)
        XCTAssertEqual(live?.createdSpaces, [space], "Recorded at once, before any save")
        // The background save lands.
        for _ in 0..<200 where !((try? text(url))?.contains(space.uuidString.lowercased()) ?? false) { try await Task.sleep(nanoseconds: 5_000_000) }
        let written = try text(url)
        XCTAssertTrue(written.contains(#""spaces" : "created""#) && written.contains(#""agents" : ["#) && written.contains(#""hostId""#), written)
        let reloaded = store()
        await reloaded.load()
        let read = await reloaded.activeGrant(token: token)
        var expected = grant
        expected.createdSpaces = [space]
        XCTAssertEqual(read, expected)
        XCTAssertEqual(read?.settings, settings)

        // Closed spaces leave the scope, and that is saved too.
        await reloaded.forgetCreatedSpaces([space])
        let pruned = await reloaded.activeGrant(token: token)
        XCTAssertEqual(pruned?.createdSpaces, [])
        for _ in 0..<200 where (try? text(url))?.contains(space.uuidString.lowercased()) ?? true { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(try text(url).contains("createdSpaces"))
    }

    // MARK: - Presets (API2-06c)

    func testPresetsHoldExactlyTheirCapabilitiesAndDefaultScopes() {
        let observer: Set<CapabilityV2> = [.workspaceRead, .sessionOutputRead, .hostRead, .projectRead, .taskRead, .themeRead]
        let operatorSet = observer.union([.workspaceWrite, .sessionStart, .sessionInput, .sessionClose, .taskRun])
        XCTAssertEqual(GrantPreset.observer.capabilities, observer)
        XCTAssertEqual(GrantPreset.operator.capabilities, operatorSet)
        XCTAssertEqual(GrantPreset.agentOrchestrator.capabilities, operatorSet.union([.agentControl, .agentRespond, .projectLaunch, .remoteConnect]))
        XCTAssertEqual(GrantPreset.fullControl.capabilities, Set(CapabilityV2.allCases))
        XCTAssertNil(GrantPreset.custom.capabilities)
        XCTAssertEqual(GrantPreset.observer.defaultScope, GrantScope())
        XCTAssertEqual(GrantPreset.operator.defaultScope, GrantScope(hosts: .approved([])))
        XCTAssertEqual(GrantPreset.agentOrchestrator.defaultScope, GrantScope(spaces: .created, projects: .all, hosts: .approved([]), agents: .all))
        XCTAssertEqual(GrantPreset.fullControl.defaultScope, GrantScope())
        XCTAssertEqual(GrantPreset.agentOrchestrator.rawValue, "agentOrchestrator", "The grant view's spelling")
        XCTAssertFalse(GrantPreset.observer.capabilities!.contains { [.workspaceWrite, .sessionStart, .sessionInput, .sessionExecute, .sessionClose].contains($0) }, "Observer changes nothing")
    }

    // MARK: - Editing (API2-06d)

    func testEditsBumpTheRevisionKeepTheTokenAndWideningNeedsConfirmation() async throws {
        let memory = GrantStore(url: nil, secrets: secrets, now: { [clock] in clock.now })
        let edits = EditLog()
        await memory.onEdit { edits.append($0) }
        let (grant, token) = try await memory.create(GrantSettings(name: "Bot", preset: .operator, capabilities: GrantPreset.operator.capabilities!), lifetime: 3600)
        var wider = grant.settings
        wider.capabilities.insert(.agentControl); wider.preset = .custom
        do {
            try await memory.update(grant.id, to: wider, expectedRevision: grant.revision, confirmedWidening: false)
            XCTFail("Widened without confirmation")
        } catch { XCTAssertEqual(error, .confirmationRequired) }
        let unchanged = await memory.activeGrant(id: grant.id)
        XCTAssertEqual(unchanged, grant, "Cancel keeps the grant exactly as it was")
        XCTAssertTrue(edits.edits.isEmpty)

        let widened = try await memory.update(grant.id, to: wider, expectedRevision: 1, confirmedWidening: true)
        XCTAssertEqual(widened.revision, 2)
        XCTAssertEqual(widened.tokenHash, grant.tokenHash)
        XCTAssertEqual(widened.preset, .custom)
        XCTAssertEqual(widened.reauthenticateBelow, 0, "Widening doesn't end authentications")
        let byToken = await memory.activeGrant(token: token)
        XCTAssertEqual(byToken?.capabilitiesV2.contains(.agentControl), true)
        XCTAssertEqual(edits.edits.last?.change, GrantChange(widens: true))

        do {
            try await memory.update(grant.id, to: grant.settings, expectedRevision: 1, confirmedWidening: true)
            XCTFail("A stale edit applied")
        } catch { XCTAssertEqual(error, .conflict) }

        var narrower = widened.settings
        narrower.capabilities.remove(.sessionInput)
        let narrowed = try await memory.update(grant.id, to: narrower, expectedRevision: 2, confirmedWidening: false)
        XCTAssertEqual(narrowed.revision, 3)
        XCTAssertEqual(narrowed.reauthenticateBelow, 3, "Connections from before the narrowing authenticate again")
        XCTAssertEqual(edits.edits.last?.change, GrantChange(narrows: true))

        var renamed = narrowed.settings
        renamed.name = "  Renamed  "
        let afterRename = try await memory.update(grant.id, to: renamed, expectedRevision: 3, confirmedWidening: false)
        XCTAssertEqual(afterRename.name, "Renamed")
        XCTAssertEqual(afterRename.revision, 4, "Every edit raises the revision")
        XCTAssertEqual(afterRename.reauthenticateBelow, 3)
        let same = try await memory.update(grant.id, to: afterRename.settings, expectedRevision: 4, confirmedWidening: false)
        XCTAssertEqual(same.revision, 4, "Saving without a change is no edit")

        clock.advance(10)
        do {
            try await memory.update(grant.id, to: afterRename.settings, lifetime: 7_200, expectedRevision: 4, confirmedWidening: false)
            XCTFail("A later expiry applied without confirmation")
        } catch { XCTAssertEqual(error, .confirmationRequired) }
        let shorter = try await memory.update(grant.id, to: afterRename.settings, lifetime: 600, expectedRevision: 4, confirmedWidening: false)
        XCTAssertEqual(shorter.expiresAt, clock.now.addingTimeInterval(600))
        XCTAssertEqual(shorter.reauthenticateBelow, 5)
        for invalid in [GrantSettings(name: " ", capabilities: [.workspaceRead]), GrantSettings(name: "X", capabilities: [])] {
            do {
                try await memory.update(grant.id, to: invalid, expectedRevision: 5, confirmedWidening: true)
                XCTFail("Invalid settings saved")
            } catch { XCTAssertTrue([.invalidName, .noCapabilities].contains(error)) }
        }
        try await memory.revoke(grant.id)
        do {
            try await memory.update(grant.id, to: shorter.settings, expectedRevision: 5, confirmedWidening: true)
            XCTFail("Edited a revoked grant")
        } catch { XCTAssertEqual(error, .notFound) }
    }

    func testAFailedSaveKeepsANarrowingButNeverAWidening() async throws {
        let disk = store()
        let (grant, _) = try await disk.create(GrantSettings(name: "Bot", capabilities: [.workspaceRead, .sessionInput]), lifetime: 3600)
        // Make the next atomic replace fail: the directory can't take a new file.
        XCTAssertEqual(chmod(root.path, 0o500), 0)
        defer { chmod(root.path, 0o700) }
        var wider = grant.settings
        wider.capabilities.insert(.sessionClose)
        do {
            try await disk.update(grant.id, to: wider, expectedRevision: 1, confirmedWidening: true)
            XCTFail("Saved into a read-only directory")
        } catch { XCTAssertEqual(error, .io) }
        let stillOld = await disk.activeGrant(id: grant.id)
        XCTAssertEqual(stillOld, grant, "An unsaved widening changes nothing")
        var narrower = grant.settings
        narrower.capabilities = [.workspaceRead]
        do {
            try await disk.update(grant.id, to: narrower, expectedRevision: 1, confirmedWidening: false)
            XCTFail("Saved into a read-only directory")
        } catch { XCTAssertEqual(error, .io) }
        let narrowed = await disk.activeGrant(id: grant.id)
        XCTAssertEqual(narrowed?.capabilitiesV2, [.workspaceRead], "A narrowing applies at once, saved or not")
    }

    func testChangeClassification() {
        let a = UUID(), b = UUID(), c = UUID()
        let grant = AutomationGrant(
            id: UUID(), tokenHash: "", settings: GrantSettings(name: "G", capabilities: [.workspaceRead], scope: GrantScope(spaces: .created)), createdAt: clock.now,
            expiresAt: clock.now.addingTimeInterval(60), createdSpaces: [a])
        func change(_ scope: GrantScope, _ capabilities: Set<CapabilityV2> = [.workspaceRead], expires: TimeInterval = 60) -> GrantChange {
            GrantChange(from: grant, to: GrantSettings(name: "G", capabilities: capabilities, scope: scope), expiresAt: clock.now.addingTimeInterval(expires))
        }
        XCTAssertEqual(change(GrantScope(spaces: .created)), GrantChange())
        XCTAssertEqual(change(GrantScope(spaces: .all)), GrantChange(widens: true))
        XCTAssertEqual(change(GrantScope(spaces: .spaces([a]))), GrantChange(narrows: true), "Its own spaces, but it can no longer create any")
        XCTAssertEqual(change(GrantScope(spaces: .spaces([b]))), GrantChange(widens: true, narrows: true))
        XCTAssertEqual(change(GrantScope(spaces: .created, projects: .projects([c]))), GrantChange(narrows: true))
        XCTAssertEqual(change(GrantScope(spaces: .created, agents: .agents(["x"]))), GrantChange(narrows: true))
        XCTAssertEqual(change(GrantScope(spaces: .created, hosts: .approved([]))), GrantChange(narrows: true))
        XCTAssertEqual(change(GrantScope(spaces: .created), [.workspaceRead, .workspaceWrite]), GrantChange(widens: true))
        XCTAssertEqual(change(GrantScope(spaces: .created), [.workspaceWrite]), GrantChange(widens: true, narrows: true))
        XCTAssertEqual(change(GrantScope(spaces: .created), expires: 120), GrantChange(widens: true))
        XCTAssertEqual(change(GrantScope(spaces: .created), expires: 30), GrantChange(narrows: true))

        XCTAssertEqual(GrantChange.compare(.spaces([a]), .created, created: [a]).widens, true, "created may make more spaces")
        XCTAssertEqual(GrantChange.compare(.spaces([a, b]), .spaces([a]), created: []).narrows, true)
        let old = HostScope.approved([HostApproval(hostID: a, connectionRevision: 1), HostApproval(hostID: b, connectionRevision: 1)])
        XCTAssertEqual(GrantChange.compare(old, .approved([HostApproval(hostID: a, connectionRevision: 2), HostApproval(hostID: b, connectionRevision: 1)])).widens, true)
        XCTAssertEqual(GrantChange.compare(old, .approved([HostApproval(hostID: a, connectionRevision: 1)])).narrows, true)
        XCTAssertEqual(GrantChange.compare(old, .all).widens, true)
    }
}

final class EditLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _edits: [GrantEdit] = []
    var edits: [GrantEdit] { lock.withLock { _edits } }
    func append(_ edit: GrantEdit) { lock.withLock { _edits.append(edit) } }
}
