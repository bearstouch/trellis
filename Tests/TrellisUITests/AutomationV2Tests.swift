import Darwin
import XCTest
import TrellisControl
import TrellisCore
@testable import TrellisUI

/// The protocol through the real domain adapter: protocol 2 only.
final class AutomationV2Tests: XCTestCase {
    @MainActor private func send(_ session: ControlSession, _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        var data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        data.append(0x0A)
        let output = await session.receive(data).output
        return try XCTUnwrap(JSONSerialization.jsonObject(with: output.prefix { $0 != 0x0A }) as? [String: Any])
    }

    @MainActor
    func testSystemInfoAndGrantGetThroughTheRealAdapter() async throws {
        let h = try Harness()
        defer { h.discardPreferences() }
        let instance = UUID()
        h.handler = AuthorizingControlHandler(
            grants: h.grants, domain: AutomationServiceV2(model: h.model, hosts: h.hosts, instanceID: instance),
            idempotency: IdempotencyCache(now: { [clock = h.clock] in clock.now }))
        let token = try await h.grants.create(name: "v2", capabilities: [.workspaceRead], spaceScope: .all, hostScope: .all, lifetime: 3600).token

        // Protocol 1 is gone: the version on offer is named, and nothing runs.
        let old = ControlSession(peerUID: geteuid(), handler: h.handler)
        let refused = try await send(old, "auth.authenticate", ["protocolVersion": 1, "token": token])
        let data = try XCTUnwrap((refused["error"] as? [String: Any])?["data"] as? [String: Any])
        XCTAssertEqual(data["code"] as? String, "UNSUPPORTED_VERSION")
        XCTAssertEqual((data["details"] as? [String: Any])?["supported"] as? [Int], [2])
        let unauthenticated = try await send(old, "space.list")
        XCTAssertEqual(errorCode(unauthenticated), "AUTH_REQUIRED")

        let session = ControlSession(peerUID: geteuid(), handler: h.handler)
        let auth = try result(try await send(session, "auth.authenticate", ["protocolVersion": 2, "token": token]))
        XCTAssertEqual(auth["protocolVersion"] as? Int, 2)
        let info = try result(try await send(session, "system.info"))
        XCTAssertEqual(info["appVersion"] as? String, AppVersion.bundled ?? "development")
        XCTAssertEqual(info["instanceId"] as? String, instance.uuidString.lowercased())
        XCTAssertEqual(info["protocolVersion"] as? Int, 2)
        XCTAssertNil(info["apiVersion"])
        let view = try result(try await send(session, "grant.get"))
        let grant = try XCTUnwrap(view["grant"] as? [String: Any])
        XCTAssertEqual(grant["capabilities"] as? [String], ["workspace.read"])
        XCTAssertEqual((grant["scope"] as? [String: Any])?["spaces"] as? String, "all")
        let window = try await send(session, "window.list")
        XCTAssertEqual((window["error"] as? [String: Any])?["code"] as? Int, -32601, "v1 names are gone")
        let readOnly = try await send(session, "space.create", ["name": "Nope"])
        XCTAssertEqual(errorCode(readOnly), "PERMISSION_DENIED")
        XCTAssertEqual(h.model.snapshot.spaces.filter { $0.name == "Nope" }.count, 0)
    }
}
