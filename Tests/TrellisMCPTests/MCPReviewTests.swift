import XCTest
import TrellisControl
import TrellisCore
@testable import TrellisMCP

/// Review-driven checks: actor reentrancy, shutdown and parser hardening.
final class MCPReviewTests: XCTestCase {
    private let store = GrantStore(url: nil, secrets: MCPSecrets())
    private lazy var handler = AuthorizingControlHandler(grants: store, domain: MCPFakeDomain())
    private lazy var endpoint = MCPEndpoint(handler: handler, serverVersion: "test", loopbackOnly: true)

    private func grant() async throws -> (AutomationGrant, String) {
        let created = try await store.create(name: "agent", capabilities: [.metadataRead], windowScope: .all, hostScope: .all, lifetime: 3600)
        return (created.grant, created.token)
    }

    private static func initialize(_ token: String) -> HTTPRequest {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#
        return HTTPRequest(
            method: "POST", path: "/mcp", headers: ["Host": "127.0.0.1:7777", "Content-Type": "application/json", "Authorization": "Bearer \(token)"],
            body: Data(body.utf8))
    }

    func testConcurrentInitializesNeverExceedTheSessionBound() async throws {
        let (grant, token) = try await grant()
        let endpoint = endpoint
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<(MCPEndpoint.maximumSessions * 3) { group.addTask { _ = await endpoint.handle(Self.initialize(token)) } }
        }
        let count = await endpoint.sessionCount
        XCTAssertEqual(count, MCPEndpoint.maximumSessions)
        let tracked = await handler.connections(for: grant.id)
        XCTAssertEqual(tracked.count, MCPEndpoint.maximumSessions, "Evicted sessions release their authorizer connection")
    }

    func testInitializeAfterShutdownOpensNoSession() async throws {
        let (grant, token) = try await grant()
        let first = await endpoint.handle(Self.initialize(token))
        XCTAssertEqual(first.status, 200)
        await endpoint.closeAll()
        let late = await endpoint.handle(Self.initialize(token))
        XCTAssertEqual(late.status, 503)
        XCTAssertNil(late.header("Mcp-Session-Id"))
        let count = await endpoint.sessionCount
        XCTAssertEqual(count, 0)
        let tracked = await handler.connections(for: grant.id)
        XCTAssertTrue(tracked.isEmpty, "A refused initialize leaves no authorizer connection behind")
    }

    func testDuplicateHostHeaderIsRejected() {
        var parser = HTTPRequestParser()
        XCTAssertThrowsError(try parser.append(Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nHost: evil.example\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? HTTPParseError, .malformed)
        }
    }
}
