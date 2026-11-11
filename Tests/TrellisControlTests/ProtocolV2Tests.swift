import Darwin
import XCTest
import TrellisCore
@testable import TrellisControl

/// The v2 side of the fake workspace: `FakeDomain`'s spaces and hosts, recording every call that reaches the domain.
final class FakeDomainV2: ControlDomainV2, @unchecked Sendable {
    let base: FakeDomain
    let instanceID = UUID()
    private let lock = NSLock()
    private var _performed: [String] = []
    var performed: [String] { lock.withLock { _performed } }

    init(base: FakeDomain) { self.base = base }

    private var _revisions: [UUID: UInt64] = [:]
    private var _params: [JSONValue] = []
    /// Pane and session revisions the fake reports (the store versions only spaces and tabs).
    func setRevision(_ id: UUID, _ revision: UInt64) { lock.withLock { _revisions[id] = revision } }
    /// The params of each call that reached the domain, as the dispatcher passed them.
    var performedParams: [JSONValue] { lock.withLock { _params } }

    func snapshot() async -> WorkspaceSnapshot { await base.snapshot() }
    func host(_ id: UUID) async -> SavedHost? { await base.host(id) }
    func revision(of subject: RevisionSubjectV2) async -> UInt64? {
        if let answer = subject.revision(in: await base.snapshot()) { return answer }
        switch subject {
        case .resource(.host, let id): return await base.host(id)?.revision
        case .resource(.pane, let id), .resource(.session, let id): return lock.withLock { _revisions[id] }
        default: return nil
        }
    }
    func perform(_ call: CallV2) async -> Result<JSONValue, ControlError> {
        let count = lock.withLock { () -> Int in
            _performed.append(call.spec.name)
            _params.append(.object(call.params.values))
            return _performed.count
        }
        switch call.spec.name {
        case "system.info": return .success(ResultsV2.systemInfo(appVersion: "9.9.9", instanceID: instanceID))
        default: return .success(.object(["call": .number(Double(count))]))
        }
    }
}

final class ProtocolV2Tests: XCTestCase {
    private let clock = TestClock()
    private let secrets = MemorySecrets()
    private let domain = FakeDomain()
    private lazy var domainV2 = FakeDomainV2(base: domain)
    private lazy var store = GrantStore(url: nil, secrets: secrets, now: { [clock] in clock.now })

    private func handler(v2: Bool) -> AuthorizingControlHandler {
        AuthorizingControlHandler(
            grants: store, domain: domain, limiter: AuthenticationRateLimiter(now: { [clock] in clock.now }), idempotency: IdempotencyCache(now: { [clock] in clock.now }),
            v2Domain: v2 ? domainV2 : nil)
    }

    private func reply(_ session: ControlSession, _ data: Data) async throws -> [String: Any] {
        let output = await session.receive(data).output
        return try XCTUnwrap(try responses(output).last)
    }

    private func call(_ session: ControlSession, _ method: String, _ params: [String: JSONValue] = [:]) async throws -> [String: Any] {
        try await reply(session, request(1, method, params))
    }

    private func authenticate(_ session: ControlSession, _ token: String, version: Double) async throws -> [String: Any] {
        try await call(session, "auth.authenticate", ["protocolVersion": .number(version), "token": .string(token)])
    }

    private func grant(_ capabilities: Set<Capability> = Set(Capability.allCases), spaces: SpaceScope = .all, hosts: HostScope = .all) async throws -> (
        AutomationGrant, String
    ) {
        try await store.create(name: "Bot", capabilities: capabilities, spaceScope: spaces, hostScope: hosts, lifetime: 3600)
    }

    private func error(_ response: [String: Any]) -> [String: Any]? { response["error"] as? [String: Any] }
    private func data(_ response: [String: Any]) -> [String: Any]? { error(response)?["data"] as? [String: Any] }
    private func result(_ response: [String: Any]) -> [String: Any]? { response["result"] as? [String: Any] }

    // MARK: - Negotiation (API2-01)

    func testProtocol2IsRefusedExactlyAsBeforeWithoutTheFlag() async throws {
        let (_, token) = try await grant()
        let handler = handler(v2: false)
        XCTAssertEqual(handler.supportedProtocolVersions, [1])
        let session = ControlSession(peerUID: geteuid(), handler: handler)
        let refused = try await authenticate(session, token, version: 2)
        XCTAssertEqual(error(refused)?["message"] as? String, "Use protocolVersion 1.")
        XCTAssertEqual(data(refused)?.count, 2, "v1 shape: only code and retryable")
        XCTAssertEqual(data(refused)?["code"] as? String, "UNSUPPORTED_VERSION")
        XCTAssertNil(data(refused)?["supported"])
        XCTAssertNil(data(refused)?["details"])
        // v1 is unaffected.
        let accepted = try await authenticate(session, token, version: 1)
        XCTAssertEqual(result(accepted)?["protocolVersion"] as? Int, 1)
        XCTAssertNotNil(result(accepted)?["spaceScope"], "v1 authentication result keeps its fields")
        let r2 = try await call(session, "grant.get")
        XCTAssertEqual(error(r2)?["code"] as? Int, -32601, "v1 connections never see v2 methods")
        XCTAssertEqual(domainV2.performed, [])
    }

    func testProtocol2IsNegotiatedPerConnectionWithTheFlag() async throws {
        let (grant, token) = try await grant([.metadataRead, .layoutWrite, .sessionInput])
        let handler = handler(v2: true)
        XCTAssertEqual(handler.supportedProtocolVersions, [1, 2])
        let v2 = ControlSession(peerUID: geteuid(), handler: handler), v1 = ControlSession(peerUID: geteuid(), handler: handler)

        let r3 = try await authenticate(v2, token, version: 2)
        let auth = try XCTUnwrap(result(r3))
        XCTAssertEqual(auth["protocolVersion"] as? Int, 2)
        XCTAssertEqual(auth["connectionId"] as? String, v2.connectionID.uuidString.lowercased())
        let view = try XCTUnwrap(auth["grant"] as? [String: Any])
        XCTAssertEqual(view["id"] as? String, grant.id.uuidString.lowercased())
        XCTAssertEqual(view["capabilities"] as? [String], ["session.input", "workspace.read", "workspace.write"], "v1 capabilities under their v2 names")
        XCTAssertNil(view["grantId"])

        // The other connection on the same handler still speaks v1, aliases included.
        let r4 = try await authenticate(v1, token, version: 1)
        XCTAssertEqual(result(r4)?["protocolVersion"] as? Int, 1)
        let r5 = try await call(v1, "window.list")
        XCTAssertNotNil(result(r5))
        XCTAssertEqual(domain.executed, ["space.list"], "window.list still maps to space.list on v1")
        let r6 = try await call(v1, "system.info")
        XCTAssertNotNil(result(r6), "v1 system.info reaches the v1 domain")
        let r7 = try await call(v1, "grant.get")
        XCTAssertEqual(error(r7)?["code"] as? Int, -32601, "v1 connections never see v2 methods")
        XCTAssertEqual(domainV2.performed, [])

        let r8 = try await call(v2, "system.info")
        let info = try XCTUnwrap(result(r8))
        XCTAssertEqual(info["protocolVersion"] as? Int, 2)
        XCTAssertEqual(info["appVersion"] as? String, "9.9.9")
        XCTAssertEqual(info["instanceId"] as? String, domainV2.instanceID.uuidString.lowercased())
        XCTAssertNil(info["apiVersion"])
        XCTAssertNil(info["capabilities"], "Capabilities are in grant.get")
        let limits = try XCTUnwrap(info["limits"] as? [String: Int])
        XCTAssertEqual(limits["maxFrameBytes"], 1_048_576)
        XCTAssertEqual(limits["maxJsonDepth"], 64)
        XCTAssertEqual(limits["maxPageSize"], 500)
        XCTAssertEqual(domainV2.performed, ["system.info"])
        XCTAssertEqual(domain.executed, ["space.list", "system.info"], "v2 calls never reach the v1 domain")
    }

    func testUnsupportedVersionWithTheFlagNamesBothVersions() async throws {
        let (_, token) = try await grant()
        let session = ControlSession(peerUID: geteuid(), handler: handler(v2: true))
        for version in [0.0, 3, 1.5] {
            // Until a client asks for 2, replies keep the v1 shape: details merged into data.
            let refused = try await authenticate(session, token, version: version)
            XCTAssertEqual(data(refused)?["code"] as? String, "UNSUPPORTED_VERSION")
            XCTAssertEqual(data(refused)?["supported"] as? [Int], [1, 2])
            XCTAssertNil(data(refused)?["details"])
        }
        // After asking for 2, replies use the v2 error shape: data {code, message, retryable, details?}.
        let failed = try await authenticate(session, "trl_wrong", version: 2)
        XCTAssertEqual(data(failed)?["code"] as? String, "AUTH_REQUIRED")
        XCTAssertEqual(data(failed)?["message"] as? String, "Authentication failed.")
        XCTAssertEqual(data(failed)?["retryable"] as? Bool, false)
        let v2Refused = try await authenticate(session, token, version: 3)
        XCTAssertEqual((data(v2Refused)?["details"] as? [String: Any])?["supported"] as? [Int], [1, 2])
        XCTAssertNil(data(v2Refused)?["supported"])
    }

    func testGrantGetReturnsTheCallersOwnGrantView() async throws {
        let valid = try HostDraft(name: "Prod", destination: "prod").validated { _ in false }
        var host = SavedHost(id: UUID(), draft: valid, revision: 1)
        domain.setHost(host)
        let gone = UUID()
        let (grant, token) = try await grant(
            [.metadataRead], spaces: .spaces([domain.spaceB, domain.spaceA]),
            hosts: .approved([HostApproval(hostID: host.id, connectionRevision: host.connectionRevision), HostApproval(hostID: gone, connectionRevision: 4)]))
        let session = ControlSession(peerUID: geteuid(), handler: handler(v2: true))
        _ = try await authenticate(session, token, version: 2)
        let r9 = try await call(session, "grant.get")
        let view = try XCTUnwrap(result(r9)?["grant"] as? [String: Any])
        XCTAssertEqual(Set(view.keys), ["id", "name", "preset", "revision", "capabilities", "scope", "createdAt", "expiresAt"])
        XCTAssertEqual(view["preset"] as? String, "custom", "A grant made with v1 capabilities is Custom")
        XCTAssertEqual(view["revision"] as? Int, 1)
        XCTAssertEqual(view["name"] as? String, "Bot")
        XCTAssertEqual(view["createdAt"] as? String, "2027-01-15T08:00:00.000Z")
        XCTAssertEqual(view["expiresAt"] as? String, "2027-01-15T09:00:00.000Z")
        let scope = try XCTUnwrap(view["scope"] as? [String: Any])
        XCTAssertEqual(scope["spaces"] as? [String], [domain.spaceA, domain.spaceB].map { $0.uuidString.lowercased() }.sorted())
        XCTAssertEqual(scope["projects"] as? String, "all")
        XCTAssertEqual(scope["agents"] as? String, "all")
        let hosts = try XCTUnwrap(scope["hosts"] as? [[String: Any]])
        let current = Dictionary(uniqueKeysWithValues: hosts.map { ($0["hostId"] as? String ?? "", $0["current"] as? Bool) })
        XCTAssertEqual(current, [host.id.uuidString.lowercased(): true, gone.uuidString.lowercased(): false])
        XCTAssertEqual(hosts.first { $0["hostId"] as? String == gone.uuidString.lowercased() }?["connectionRevision"] as? Int, 4)

        // A changed connection makes the approval stale, which the view shows.
        host.connectionRevision += 1
        domain.setHost(host)
        let r10 = try await call(session, "grant.get")
        let stale = try XCTUnwrap(result(r10)?["grant"] as? [String: Any])
        let staleHosts = try XCTUnwrap((stale["scope"] as? [String: Any])?["hosts"] as? [[String: Any]])
        XCTAssertEqual(staleHosts.first { $0["hostId"] as? String == host.id.uuidString.lowercased() }?["current"] as? Bool, false)
        XCTAssertEqual(grant.id.uuidString.lowercased(), view["id"] as? String)
        XCTAssertEqual(domainV2.performed, [], "grant.get is answered by the authorizer, never the domain")
    }

    func testV2RejectsV1NamesAliasesAndBadParams() async throws {
        let (_, token) = try await grant()
        let session = ControlSession(peerUID: geteuid(), handler: handler(v2: true))
        _ = try await authenticate(session, token, version: 2)
        for method in ["window.list", "window.get", "events.subscribe", "auth.whoami", "agent.list", "layout.apply"] {
            let r11 = try await call(session, method)
            XCTAssertEqual(error(r11)?["code"] as? Int, -32601, method)
        }
        let alias = try await call(session, "grant.get", ["windowId": .string(domain.spaceA.uuidString)])
        XCTAssertEqual(error(alias)?["code"] as? Int, -32602)
        XCTAssertEqual((data(alias)?["fields"] as? [String: String])?["windowId"], "unknown parameter")
        let array = try await reply(session, Data(#"{"jsonrpc":"2.0","id":2,"method":"system.info","params":[]}"#.utf8 + [0x0A]))
        XCTAssertEqual((data(array)?["fields"] as? [String: String])?["params"], "object")
        XCTAssertEqual(domain.executed, [], "Nothing reached the v1 domain")
        XCTAssertEqual(domainV2.performed, [])

        // Notifications are never dispatched; mutating or unknown ones are refused, read-only ones are silent.
        let silent = await session.receive(Data(#"{"jsonrpc":"2.0","method":"system.info"}"#.utf8 + [0x0A])).output
        XCTAssertEqual(silent, Data())
        let r12 = await session.receive(Data(#"{"jsonrpc":"2.0","method":"space.close"}"#.utf8 + [0x0A])).output
        let refused = try XCTUnwrap(try responses(r12).first)
        XCTAssertEqual(error(refused)?["code"] as? Int, -32600)
        XCTAssertEqual(domainV2.performed, [])
    }

    func testRevokedGrantEndsAV2ConnectionWithV2ShapedErrors() async throws {
        let (grant, token) = try await grant()
        let session = ControlSession(peerUID: geteuid(), handler: handler(v2: true))
        _ = try await authenticate(session, token, version: 2)
        try await store.revoke(grant.id)
        let revoked = try await call(session, "system.info")
        XCTAssertEqual(data(revoked)?["code"] as? String, "AUTH_REQUIRED")
        XCTAssertNotNil(data(revoked)?["message"])
        XCTAssertNil(data(revoked)?["details"])
        let r13 = try await call(session, "system.info")
        XCTAssertEqual(error(r13)?["message"] as? String, "Authenticate with auth.authenticate first.", "The connection is no longer authenticated")
        XCTAssertEqual(domainV2.performed, [])
    }

    func testDiscoveryListsProtocol2OverARealSocketOnlyWithTheFlag() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tv2-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state"), withIntermediateDirectories: true)
        XCTAssertEqual(mkdir(runtime.path, 0o700), 0)
        let endpoint = ControlEndpoint(stateDirectory: root.appendingPathComponent("state"), runtimeRoot: runtime)
        let (_, token) = try await grant()
        let server = ControlServer(endpoint: endpoint, handler: handler(v2: true))
        let discovery = try server.start()
        defer { server.stop() }
        let published = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: endpoint.discoveryURL)) as? [String: Any])
        XCTAssertEqual(published["protocolVersion"] as? Int, 1, "The shipped CLI keeps finding protocol 1")
        XCTAssertEqual(published["protocolVersions"] as? [Int], [1, 2])
        let v1Only = try JSONEncoder().encode(ControlDiscovery(protocolVersion: 1, instanceID: UUID(), socketPath: "/s"))
        XCTAssertNil((try JSONSerialization.jsonObject(with: v1Only) as? [String: Any])?["protocolVersions"], "Without the flag control.json is unchanged")
        let client = try SocketClient(path: discovery.socketPath)
        defer { client.close() }
        let versions = try await Task.detached {
            [
                try client.request(#"{"jsonrpc":"2.0","id":1,"method":"auth.authenticate","params":{"protocolVersion":2,"token":"\#(token)"}}"#),
                try client.request(#"{"jsonrpc":"2.0","id":2,"method":"system.info"}"#)
            ].map { ($0["result"] as? [String: Any])?["protocolVersion"] as? Int }
        }.value
        XCTAssertEqual(versions, [2, 2], "auth.authenticate and system.info both answer protocol 2")
    }

    // MARK: - Authorization and idempotency derived from declarations

    private func dispatcher() -> DispatcherV2 {
        DispatcherV2(domain: domainV2, idempotency: IdempotencyCache(now: { [clock] in clock.now }), catalog: Dictionary(uniqueKeysWithValues: ContractV2Tests.samples.map { ($0.name, $0) }))
    }

    private func identity(_ grant: AutomationGrant) -> ControlIdentity { ControlIdentity(connectionID: UUID(), peerUID: geteuid(), grantID: grant.id, protocolVersion: 2) }

    func testAuthorizationComesFromTheDeclaration() async throws {
        let dispatcher = dispatcher()
        let pane = JSONValue.string(domain.paneA.uuidString.lowercased())
        let (reader, _) = try await grant([.metadataRead])
        guard case .failure(let denied) = await dispatcher.dispatch("pane.close", params: .object(["id": pane]), grant: reader, identity: identity(reader)) else { return XCTFail() }
        XCTAssertEqual(denied.appCode, "PERMISSION_DENIED")
        XCTAssertEqual(denied.details, .object(["missing": .array([.string("workspace.write")])]))

        let (writer, _) = try await grant([.layoutWrite])
        guard case .failure(let conditional) = await dispatcher.dispatch("pane.close", params: .object(["id": pane, "allowRunning": .bool(true)]), grant: writer, identity: identity(writer))
        else { return XCTFail() }
        XCTAssertEqual(conditional.details, .object(["missing": .array([.string("session.close")])]), "Conditional capabilities apply when the param is set")
        guard case .success = await dispatcher.dispatch("pane.close", params: .object(["id": pane, "allowRunning": .bool(false)]), grant: writer, identity: identity(writer))
        else { return XCTFail() }

        let (scoped, _) = try await grant([.layoutWrite], spaces: .spaces([domain.spaceB]))
        guard case .failure(let hidden) = await dispatcher.dispatch("pane.close", params: .object(["id": pane]), grant: scoped, identity: identity(scoped)) else { return XCTFail() }
        XCTAssertEqual(hidden.appCode, "NOT_FOUND", "Out of scope looks like missing")
        guard case .failure(let missing) = await dispatcher.dispatch("pane.close", params: .object(["id": .string(UUID().uuidString)]), grant: writer, identity: identity(writer))
        else { return XCTFail() }
        XCTAssertEqual(missing, hidden)
        guard case .success = await dispatcher.dispatch("pane.close", params: .object(["id": .string(domain.paneB.uuidString)]), grant: scoped, identity: identity(scoped)) else {
            return XCTFail("Uppercase IDs are accepted")
        }
        let ids = JSONValue.array([.string(domain.spaceB.uuidString)])
        guard case .failure(let narrow) = await dispatcher.dispatch("space.reorder", params: .object(["ids": ids]), grant: scoped, identity: identity(scoped)) else {
            return XCTFail()
        }
        XCTAssertEqual(narrow.appCode, "PERMISSION_DENIED", "All-spaces methods need all-spaces scope")
        XCTAssertEqual(domainV2.performed, ["pane.close", "pane.close"], "Only authorized calls reached the domain")
    }

    func testIdempotencyReplaysPerKeyAndRefusesReuse() async throws {
        let dispatcher = dispatcher()
        let (grant, _) = try await grant()
        let params: JSONValue = .object(["id": .string(domain.paneA.uuidString), "idempotencyKey": .string("close-1")])
        guard case .success(let first) = await dispatcher.dispatch("pane.close", params: params, grant: grant, identity: identity(grant)),
            case .success(let again) = await dispatcher.dispatch("pane.close", params: params, grant: grant, identity: identity(grant))
        else { return XCTFail() }
        XCTAssertEqual(first, again, "The same key replays the first result")
        XCTAssertEqual(domainV2.performed, ["pane.close"])
        let other: JSONValue = .object(["id": .string(domain.paneA2.uuidString), "idempotencyKey": .string("close-1")])
        guard case .failure(let reused) = await dispatcher.dispatch("pane.close", params: other, grant: grant, identity: identity(grant)) else { return XCTFail() }
        XCTAssertEqual(reused.appCode, "CONFLICT")
        // Keys are kept per grant for ten minutes.
        clock.advance(601)
        guard case .success = await dispatcher.dispatch("pane.close", params: other, grant: grant, identity: identity(grant)) else { return XCTFail() }
        XCTAssertEqual(domainV2.performed, ["pane.close", "pane.close"])
        guard case .failure(let invalid) = await dispatcher.dispatch("pane.close", params: .object(["id": .string(domain.paneA.uuidString), "idempotencyKey": .string("")]), grant: grant, identity: identity(grant))
        else { return XCTFail() }
        XCTAssertEqual(invalid.code, -32602)
    }
}
