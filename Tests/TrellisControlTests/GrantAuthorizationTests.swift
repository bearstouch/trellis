import Darwin
import XCTest
import TrellisCore
@testable import TrellisControl

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

final class MemorySecrets: GrantSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: String] = [:]
    var failNextStore = false
    func store(_ token: String, grantID: UUID) throws {
        try lock.withLock {
            if failNextStore { failNextStore = false; throw GrantError.secretStore }
            items[grantID] = token
        }
    }
    func remove(grantID: UUID) { _ = lock.withLock { items.removeValue(forKey: grantID) } }
    func token(_ id: UUID) -> String? { lock.withLock { items[id] } }
}

/// Two windows (A with a split, B plain) and editable hosts.
final class FakeDomain: ControlDomain, @unchecked Sendable {
    let windowA = UUID(), windowB = UUID(), tabA = UUID(), tabB = UUID(), branchA = UUID()
    let paneA = UUID(), paneA2 = UUID(), paneB = UUID(), sessionA = UUID(), sessionA2 = UUID(), sessionB = UUID()
    let snapshotValue: WorkspaceSnapshot
    private let lock = NSLock()
    private var _hosts: [UUID: SavedHost] = [:]
    private var _executed: [String] = []
    var executed: [String] { lock.withLock { _executed } }

    init() {
        var s = WorkspaceSnapshot()
        s.windows = [
            ManagedWindow(id: windowA, name: "A", tabIDs: [tabA], activeTabID: tabA), ManagedWindow(id: windowB, name: "B", tabIDs: [tabB], activeTabID: tabB)
        ]
        s.activeWindowID = windowA
        s.tabs[tabA] = WorkspaceTab(
            id: tabA, windowID: windowA, title: "a", root: .split(id: branchA, axis: .x, ratio: 0.5, children: [.pane(paneA), .pane(paneA2)]), activePaneID: paneA)
        s.tabs[tabB] = WorkspaceTab(id: tabB, windowID: windowB, title: "b", root: .pane(paneB), activePaneID: paneB)
        for (pane, tab, session) in [(paneA, tabA, sessionA), (paneA2, tabA, sessionA2), (paneB, tabB, sessionB)] {
            s.panes[pane] = WorkspacePane(id: pane, tabID: tab, sessionID: session)
            s.sessions[session] = WorkspaceSession(id: session)
        }
        snapshotValue = s
    }

    func setHost(_ host: SavedHost) { lock.withLock { _hosts[host.id] = host } }
    func snapshot() async -> WorkspaceSnapshot { snapshotValue }
    func host(_ id: UUID) async -> SavedHost? { lock.withLock { _hosts[id] } }
    func execute(_ method: String, params: JSONValue?, access: GrantAccess) async -> Result<JSONValue, ControlError> {
        lock.withLock { _executed.append(method) }
        return .success(.object([:]))
    }
}

func request(_ id: Int, _ method: String, _ params: [String: JSONValue] = [:]) -> Data {
    var data = try! JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": .object(params)]))
    data.append(0x0A)
    return data
}

final class GrantAuthorizationTests: XCTestCase {
    private let clock = TestClock()
    private let secrets = MemorySecrets()
    private let domain = FakeDomain()
    private lazy var store = GrantStore(url: nil, secrets: secrets, now: { [clock] in clock.now })
    private lazy var handler = AuthorizingControlHandler(
        grants: store, domain: domain, limiter: AuthenticationRateLimiter(now: { [clock] in clock.now }))

    private func reply(_ session: ControlSession, _ data: Data) async throws -> [String: Any] {
        let output = await session.receive(data).output
        return try XCTUnwrap(try responses(output).last)
    }

    private func authenticate(_ session: ControlSession, token: String, version: Double = 1) async throws -> [String: Any] {
        try await reply(session, request(0, "auth.authenticate", ["protocolVersion": .number(version), "token": .string(token)]))
    }

    private func expect(
        _ response: @autoclosure () async throws -> [String: Any], _ expected: String, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) async rethrows {
        let value = try await response()
        XCTAssertEqual(code(value), expected, message, file: file, line: line)
    }

    private func code(_ response: [String: Any]) -> String? { response["result"] != nil ? "OK" : appCode(response) ?? "\((response["error"] as? [String: Any])?["code"] ?? "")" }

    func testS022_UT01_denyBeforeAuthentication() async throws {
        let (_, token) = try await store.create(name: "CI", capabilities: Set(Capability.allCases), windowScope: .all, hostScope: .all, lifetime: 3600)
        let session = ControlSession(peerUID: geteuid(), handler: handler)
        let probes: [(String, [String: JSONValue])] = [
            ("window.get", ["id": .string(domain.windowA.uuidString)]), ("session.readOutput", ["id": .string(domain.sessionA.uuidString)]),
            ("session.execute", ["id": .string(domain.sessionA.uuidString), "command": .string("rm -rf /")]), ("window.create", ["name": .string("x")]),
            ("system.info", [:])
        ]
        for (index, probe) in probes.enumerated() {
            try await expect(try await reply(session, request(index + 1, probe.0, probe.1)), "AUTH_REQUIRED", probe.0)
        }
        try await expect(try await authenticate(session, token: "trl_wrong"), "AUTH_REQUIRED")
        try await expect(try await authenticate(session, token: token, version: 2), "UNSUPPORTED_VERSION")
        try await expect(try await reply(session, request(9, "window.list")), "AUTH_REQUIRED")
        XCTAssertEqual(domain.executed, [], "No effects before authentication")

        // Failures are rate limited, even for a correct token, until the window passes.
        for _ in 0..<3 { _ = try await authenticate(session, token: "trl_wrong") }
        let limited = try await authenticate(session, token: token)
        XCTAssertEqual(code(limited), "LIMIT_EXCEEDED")
        XCTAssertEqual(((limited["error"] as? [String: Any])?["data"] as? [String: Any])?["retryable"] as? Bool, true)
        clock.advance(61)
        let accepted = try await authenticate(session, token: token)
        let result = try XCTUnwrap(accepted["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? Int, 1)
        XCTAssertNotNil(result["expiresAt"] as? String)
        XCTAssertFalse(String(describing: accepted).contains(token), "Tokens are never echoed")
        try await expect(try await reply(session, request(10, "window.list")), "OK")
        XCTAssertEqual(domain.executed, ["window.list"])
    }

    func testS022_UT02_scopeAndCapabilityMatrix() async throws {
        let d = domain
        let (layoutGrant, layoutToken) = try await store.create(
            name: "Layout", capabilities: [.metadataRead, .layoutWrite], windowScope: .windows([d.windowA]), hostScope: .approved([]), lifetime: 3600)
        let (_, fullToken) = try await store.create(name: "Full", capabilities: Set(Capability.allCases), windowScope: .all, hostScope: .all, lifetime: 3600)
        XCTAssertEqual(layoutGrant.windowScope, .windows([d.windowA]))
        func id(_ value: UUID) -> JSONValue { .string(value.uuidString) }
        let cases: [(String, [String: JSONValue], layout: String, full: String)] = [
            ("window.list", [:], "OK", "OK"),
            ("window.get", ["id": id(d.windowA)], "OK", "OK"),
            ("window.get", ["id": id(d.windowB)], "NOT_FOUND", "OK"),
            ("window.get", ["id": id(UUID())], "NOT_FOUND", "NOT_FOUND"),
            ("window.get", ["id": .string("not-a-uuid")], "-32602", "-32602"),
            ("window.get", [:], "-32602", "-32602"),
            ("window.create", ["name": .string("New")], "PERMISSION_DENIED", "OK"),
            ("window.reorder", ["ids": .array([])], "PERMISSION_DENIED", "OK"),
            ("tab.get", ["id": id(d.tabB)], "NOT_FOUND", "OK"),
            ("pane.split", ["paneId": id(d.paneA), "axis": .string("x")], "OK", "OK"),
            ("pane.split", ["paneId": id(d.paneB), "axis": .string("x")], "NOT_FOUND", "OK"),
            ("pane.split", ["paneId": id(d.paneA), "axis": .string("x"), "start": .bool(true)], "PERMISSION_DENIED", "OK"),
            ("pane.split", ["paneId": id(d.paneA), "axis": .string("x"), "start": .bool(false)], "OK", "OK"),
            ("pane.resize", ["branchId": id(d.branchA), "ratio": .number(0.4)], "OK", "OK"),
            ("pane.close", ["id": id(d.paneA2), "allowRunning": .bool(true)], "PERMISSION_DENIED", "OK"),
            ("session.get", ["id": id(d.sessionA)], "OK", "OK"),
            ("session.get", ["id": id(d.sessionB)], "NOT_FOUND", "OK"),
            ("session.readOutput", ["id": id(d.sessionA), "view": .string("screen")], "PERMISSION_DENIED", "OK"),
            ("session.sendInput", ["id": id(d.sessionA), "text": .string("ls")], "PERMISSION_DENIED", "OK"),
            ("session.execute", ["id": id(d.sessionA), "command": .string("ls")], "PERMISSION_DENIED", "OK"),
            ("session.start", ["paneId": id(d.paneA)], "PERMISSION_DENIED", "OK"),
            ("session.start", ["paneId": id(d.paneA), "launch": .object(["kind": .string("process")])], "PERMISSION_DENIED", "OK"),
            ("host.list", [:], "PERMISSION_DENIED", "OK"),
            ("theme.list", [:], "PERMISSION_DENIED", "OK"),
            ("appearance.set", ["mode": .string("dark")], "PERMISSION_DENIED", "OK"),
            ("layout.apply", ["namespace": .string("x")], "PERMISSION_DENIED", "OK"),
            ("debug.shell", [:], "-32601", "-32601")
        ]
        for (token, expectLayout) in [(layoutToken, true), (fullToken, false)] {
            let session = ControlSession(peerUID: geteuid(), handler: handler)
            _ = try await authenticate(session, token: token)
            for (index, testCase) in cases.enumerated() {
                let expected = expectLayout ? testCase.layout : testCase.full
                let response = try await reply(session, request(index + 1, testCase.0, testCase.1))
                XCTAssertEqual(code(response), expected, "\(expectLayout ? "layout" : "full") \(testCase.0) \(testCase.1)")
                // Hidden IDs never appear in errors.
                XCTAssertFalse(String(describing: response["error"] ?? "").contains(d.windowB.uuidString))
            }
        }
        // Denied calls never reach the domain.
        let allowedLayout = cases.filter { $0.layout == "OK" }.count, allowedFull = cases.filter { $0.full == "OK" }.count
        XCTAssertEqual(domain.executed.count, allowedLayout + allowedFull)
    }

    func testThemeWritesAreGlobalAndListedIDsAndFieldsAreAuthorized() async throws {
        let d = domain
        let host = SavedHost(id: UUID(), draft: try HostDraft(name: "Prod", destination: "prod").validated { _ in false }, revision: 1)
        d.setHost(host)
        let (_, scopedToken) = try await store.create(
            name: "Scoped", capabilities: [.metadataRead, .layoutWrite, .themeRead, .themeWrite, .hostRead, .hostWrite], windowScope: .windows([d.windowA]),
            hostScope: .all, lifetime: 3600)
        let (_, globalToken) = try await store.create(name: "Theme", capabilities: [.themeWrite], windowScope: .all, hostScope: .approved([]), lifetime: 3600)
        func id(_ value: UUID) -> JSONValue { .string(value.uuidString) }
        func ids(_ values: UUID...) -> JSONValue { .array(values.map(id)) }
        let cases: [(String, [String: JSONValue], String)] = [
            ("theme.list", [:], "OK"),
            ("appearance.set", ["mode": .string("dark")], "PERMISSION_DENIED"),
            ("theme.import", ["document": .object([:])], "PERMISSION_DENIED"),
            ("theme.delete", ["id": .string("mine")], "PERMISSION_DENIED"),
            ("layout.export", ["windowIds": ids(d.windowA)], "OK"),
            ("layout.export", ["windowIds": ids(d.windowA, d.windowB)], "NOT_FOUND"),
            ("layout.export", ["windowIds": .string(d.windowA.uuidString)], "-32602"),
            ("tab.reorder", ["windowId": id(d.windowA), "ids": ids(d.tabA)], "OK"),
            ("tab.reorder", ["windowId": id(d.windowA), "ids": ids(d.tabB)], "NOT_FOUND"),
            ("events.subscribe", ["topics": .array([.string("session.state")]), "resourceIds": ids(d.paneA, d.sessionA2, d.branchA)], "OK"),
            ("events.subscribe", ["topics": .array([.string("session.state")]), "resourceIds": ids(d.sessionB)], "NOT_FOUND"),
            ("events.subscribe", ["topics": .array([.string("session.output")])], "PERMISSION_DENIED"),
            ("events.subscribe", [:], "PERMISSION_DENIED"),
            ("host.update", ["id": id(host.id), "name": .string("Production"), "tags": .array([])], "OK"),
            ("host.update", ["id": id(host.id), "destination": .string("evil")], "PERMISSION_DENIED"),
            ("host.update", ["id": id(host.id), "host": .object(["destination": .string("evil")])], "PERMISSION_DENIED")
        ]
        let scoped = ControlSession(peerUID: geteuid(), handler: handler)
        _ = try await authenticate(scoped, token: scopedToken)
        for (index, testCase) in cases.enumerated() {
            let response = try await reply(scoped, request(index + 1, testCase.0, testCase.1))
            XCTAssertEqual(code(response), testCase.2, "\(testCase.0) \(testCase.1)")
        }
        XCTAssertEqual(d.executed.count, cases.filter { $0.2 == "OK" }.count)
        let global = ControlSession(peerUID: geteuid(), handler: handler)
        _ = try await authenticate(global, token: globalToken)
        try await expect(try await reply(global, request(1, "appearance.set", ["mode": .string("dark")])), "OK", "Theme writes ignore window scope only when global")
    }

    func testUnreadableGrantFileIsPreservedAndGrantsNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("grants.json")
        let disk = GrantStore(url: url, secrets: secrets, now: { [clock] in clock.now })
        let (_, token) = try await disk.create(name: "CI", capabilities: [.metadataRead], windowScope: .all, hostScope: .all, lifetime: 3600)
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "metadata.read", with: "future.capability")
        try OwnerOnlyFile.publish(Data(text.utf8), to: url)
        let reloaded = GrantStore(url: url, secrets: secrets, now: { [clock] in clock.now })
        await reloaded.load()
        let found = await reloaded.activeGrant(token: token), failed = await reloaded.loadFailed
        XCTAssertNil(found)
        XCTAssertTrue(failed)
        do {
            _ = try await reloaded.create(name: "New", capabilities: [.metadataRead], windowScope: .all, hostScope: .all, lifetime: 3600)
            XCTFail("Overwrote an unreadable grant file")
        } catch { XCTAssertEqual(error, .readOnly) }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text, "The unreadable file is left untouched")
    }

    func testS022_UT03_expiryAndRevocationStopAccess() async throws {
        let (expiring, expiringToken) = try await store.create(name: "Short", capabilities: [.metadataRead], windowScope: .all, hostScope: .all, lifetime: 120)
        let session = ControlSession(peerUID: geteuid(), handler: handler)
        _ = try await authenticate(session, token: expiringToken)
        try await expect(try await reply(session, request(1, "window.list")), "OK")
        clock.advance(121)
        try await expect(try await reply(session, request(2, "window.list")), "AUTH_REQUIRED")
        try await expect(try await authenticate(session, token: expiringToken), "AUTH_REQUIRED", "Expired grants cannot reauthenticate")
        let expiredCount = await handler.connections(for: expiring.id).count
        XCTAssertEqual(expiredCount, 0)

        let (revocable, token) = try await store.create(name: "Agent", capabilities: [.metadataRead], windowScope: .all, hostScope: .all, lifetime: 3600)
        XCTAssertEqual(secrets.token(revocable.id), token)
        let revoked = RevocationLog()
        await store.onRevocation { revoked.append($0) }
        let live = ControlSession(peerUID: geteuid(), handler: handler)
        _ = try await authenticate(live, token: token)
        let bound = await handler.connections(for: revocable.id)
        XCTAssertEqual(bound, [live.connectionID], "The server can disconnect this connection on revocation")
        try await store.revoke(revocable.id)
        XCTAssertEqual(revoked.ids, [revocable.id])
        XCTAssertNil(secrets.token(revocable.id), "The Keychain secret is deleted")
        try await expect(try await reply(live, request(3, "window.list")), "AUTH_REQUIRED")
        try await expect(try await reply(live, request(4, "window.list")), "AUTH_REQUIRED")
        XCTAssertEqual(domain.executed, ["window.list"])
    }

    func testRevocationDisconnectsALiveSocketClient() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(mkdir(runtime.path, 0o700), 0)
        let server = ControlServer(endpoint: ControlEndpoint(stateDirectory: root, runtimeRoot: runtime), handler: handler)
        let discovery = try server.start()
        defer { server.stop() }
        let (grant, token) = try await store.create(name: "Live", capabilities: [.metadataRead], windowScope: .all, hostScope: .all, lifetime: 3600)
        let handler = self.handler
        await store.onRevocation { id in Task { server.closeConnections(await handler.connections(for: id)) } }
        let client = try SocketClient(path: discovery.socketPath)
        defer { client.close() }
        let auth = try client.request(String(decoding: request(1, "auth.authenticate", ["protocolVersion": .number(1), "token": .string(token)]).dropLast(), as: UTF8.self))
        XCTAssertNotNil(auth["result"])
        try await store.revoke(grant.id)
        let remainder = await Task.detached { client.readUntilClosed() }.value
        XCTAssertEqual(remainder, Data(), "The connection was closed by the server")
    }

    func testS022_UT04_hostRevisionInvalidatesApproval() async throws {
        let valid = try HostDraft(name: "Prod", destination: "prod").validated { _ in false }
        var host = SavedHost(id: UUID(), draft: valid, revision: 3)
        let other = SavedHost(id: UUID(), draft: try HostDraft(name: "Other", destination: "other").validated { _ in false }, revision: 1)
        domain.setHost(host)
        domain.setHost(other)
        let (grant, token) = try await store.create(
            name: "Deploy", capabilities: [.hostRead, .sessionStart, .layoutWrite], windowScope: .all,
            hostScope: .approved([HostApproval(hostID: host.id, connectionRevision: host.connectionRevision)]), lifetime: 3600)
        let session = ControlSession(peerUID: geteuid(), handler: handler)
        _ = try await authenticate(session, token: token)
        let connect: [String: JSONValue] = ["hostId": .string(host.id.uuidString), "windowId": .string(domain.windowA.uuidString)]
        try await expect(try await reply(session, request(1, "host.connect", connect)), "OK")
        try await expect(try await reply(session, request(2, "host.get", ["id": .string(other.id.uuidString)])), "NOT_FOUND")

        // A rename keeps the connection revision and the approval.
        host.name = "Production"; host.revision = 7
        domain.setHost(host)
        try await expect(try await reply(session, request(3, "host.connect", connect)), "OK")

        // A destination change requires reapproval before any further start.
        host.destination = "prod-new"; host.revision = 9; host.connectionRevision = 9
        domain.setHost(host)
        let denied = try await reply(session, request(4, "host.connect", connect))
        XCTAssertEqual(code(denied), "PERMISSION_DENIED")
        XCTAssertTrue(((denied["error"] as? [String: Any])?["message"] as? String ?? "").contains("Reapprove"))
        try await expect(try await reply(session, request(5, "host.get", ["id": .string(host.id.uuidString)])), "PERMISSION_DENIED")

        try await store.approveHosts(grant.id, hosts: [SavedHostApprovalInput(id: host.id, connectionRevision: host.connectionRevision)])
        try await expect(try await reply(session, request(6, "host.connect", connect)), "OK")
        XCTAssertEqual(domain.executed, ["host.connect", "host.connect", "host.connect"])
    }

    func testGrantFileStoresHashNotTokenAndSecretFailureCreatesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("grants.json")
        let disk = GrantStore(url: url, secrets: secrets, now: { [clock] in clock.now })
        let (grant, token) = try await disk.create(name: "CI", capabilities: [.metadataRead], windowScope: .all, hostScope: .all, lifetime: 3600)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains(token))
        XCTAssertTrue(text.contains(GrantToken.hash(token)))
        var info = stat()
        XCTAssertEqual(stat(url.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let reloaded = GrantStore(url: url, secrets: secrets, now: { [clock] in clock.now })
        await reloaded.load()
        let found = await reloaded.activeGrant(token: token)
        XCTAssertEqual(found, grant)

        secrets.failNextStore = true
        do {
            _ = try await disk.create(name: "Fails", capabilities: [.metadataRead], windowScope: .all, hostScope: .all, lifetime: 3600)
            XCTFail("Created without a stored secret")
        } catch { XCTAssertEqual(error, .secretStore) }
        let count = await disk.grants.count
        XCTAssertEqual(count, 1)
        do {
            _ = try await disk.create(name: "  ", capabilities: [.metadataRead], windowScope: .all, hostScope: .all, lifetime: 3600)
            XCTFail("Empty name accepted")
        } catch { XCTAssertEqual(error, .invalidName) }
        do {
            _ = try await disk.create(name: "None", capabilities: [], windowScope: .all, hostScope: .all, lifetime: 3600)
            XCTFail("No capabilities accepted")
        } catch { XCTAssertEqual(error, .noCapabilities) }
    }
}

final class RevocationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _ids: [UUID] = []
    var ids: [UUID] { lock.withLock { _ids } }
    func append(_ id: UUID) { lock.withLock { _ids.append(id) } }
}
