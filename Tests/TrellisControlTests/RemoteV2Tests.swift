import Darwin
import XCTest
import TrellisCore
@testable import TrellisControl

/// Phase 6 in the control layer: the `remote.*` declarations, out-of-order answers for calls that wait on a host, and
/// reason codes in `remote.link` events. The model side is `AutomationV2RemoteTests`.
final class RemoteV2Tests: XCTestCase {
    private let clock = TestClock()
    private let domain = FakeDomain()
    private lazy var domainV2 = FakeDomainV2(base: domain)
    private lazy var store = GrantStore(url: nil, secrets: MemorySecrets(), now: { [clock] in clock.now })
    private lazy var host = SavedHost(id: UUID(), draft: try! HostDraft(name: "Prod", destination: "prod").validated { _ in false }, revision: 4)

    func testRemoteDeclarations() throws {
        XCTAssertEqual(MethodCatalogV2.methods.filter(\.waits).map(\.name), ["remote.open", "remote.reconnect", "remote.helper.install", "remote.helper.remove"])
        let open = try XCTUnwrap(MethodCatalogV2.spec("remote.open"))
        XCTAssertEqual(open.requirementSummary, "remote.connect + workspace.write (+session.start if start), all or created spaces")
        XCTAssertTrue(open.createsSpace)
        XCTAssertTrue(open.errors.isSuperset(of: [.confirmationRequired, .remoteDisconnected, .launchFailed, .invalidState, .notFound, .permissionDenied]))
        XCTAssertEqual(open.revisionTarget, .container("workspace"))
        let status = try XCTUnwrap(MethodCatalogV2.spec("remote.status"))
        XCTAssertFalse(status.isMutating)
        XCTAssertEqual(status.requirementSummary, "host.read")
        for name in ["remote.reconnect", "remote.helper.install", "remote.helper.remove"] {
            XCTAssertEqual(MethodCatalogV2.spec(name)?.revisionTarget, .resource(param: "hostId"), "\(name) compares the host's revision")
        }
        XCTAssertEqual(MethodCatalogV2.spec("remote.helper.remove")?.requirementSummary, "remote.manage (+session.close if stopSessions)")
        XCTAssertTrue(MethodCatalogV2.spec("remote.helper.remove")?.isDestructive == true)
        XCTAssertTrue(MethodCatalogV2.spec("remote.helper.install")?.isDestructive == true, "migration.md marks remote_helper_* destructive")
        XCTAssertEqual(MethodCatalogV2.toolName("remote.helper.install"), "remote_helper_install")
    }

    /// A remote call waiting on its host (or on the person answering ssh in the app) is answered out of order, so the
    /// connection keeps serving; without an outbox it is answered in order, as before.
    func testAWaitingRemoteCallDoesNotBlockTheConnection() async throws {
        domain.setHost(host)
        domainV2.hold(["remote.reconnect"])
        let handler = AuthorizingControlHandler(grants: store, domain: domainV2)
        let (_, token) = try await store.create(GrantSettings(name: "Bot", capabilities: Set(CapabilityV2.allCases)), lifetime: 3600)
        let replies = DeliveryLog()
        let session = ControlSession(peerUID: geteuid(), handler: handler, reply: { replies.deliver($0) })
        _ = await session.receive(request(1, "auth.authenticate", ["protocolVersion": .number(2), "token": .string(token)]))
        let deferred = await session.receive(request(7, "remote.reconnect", ["hostId": .string(host.id.uuidString)])).output
        XCTAssertTrue(deferred.isEmpty, "Answered later")
        let info = try responses(await session.receive(request(8, "system.info")).output)
        XCTAssertNotNil(info.last?["result"], "Later frames are served while it waits")
        XCTAssertTrue(replies.messages.isEmpty)
        domainV2.release()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while replies.messages.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(replies.messages.first?["id"] as? Int, 7)
        XCTAssertNotNil(replies.messages.first?["result"])

        let inOrder = ControlSession(peerUID: geteuid(), handler: handler)
        _ = await inOrder.receive(request(1, "auth.authenticate", ["protocolVersion": .number(2), "token": .string(token)]))
        let answered = try responses(await inOrder.receive(request(9, "remote.reconnect", ["hostId": .string(host.id.uuidString)])).output)
        XCTAssertEqual(answered.last?["id"] as? Int, 9, "No outbox: answered in order")
        await session.connectionClosed()
    }

    /// At most 16 calls wait beside later frames per connection; one more is answered in order (delayed, never refused),
    /// and closing the connection drops the replies of calls still waiting.
    func testWaitingCallsAreCappedAndDroppedOnClose() async throws {
        domain.setHost(host)
        domainV2.hold(["remote.reconnect"])
        let handler = AuthorizingControlHandler(grants: store, domain: domainV2)
        let (_, token) = try await store.create(GrantSettings(name: "Bot", capabilities: Set(CapabilityV2.allCases)), lifetime: 3600)
        let replies = DeliveryLog()
        let session = ControlSession(peerUID: geteuid(), handler: handler, reply: { replies.deliver($0) })
        _ = await session.receive(request(1, "auth.authenticate", ["protocolVersion": .number(2), "token": .string(token)]))
        let params: [String: JSONValue] = ["hostId": .string(host.id.uuidString)]
        for id in 10..<(10 + ControlSession.maximumWaiting) {
            let output = await session.receive(request(id, "remote.reconnect", params)).output
            XCTAssertTrue(output.isEmpty, "Call \(id) waits beside later frames")
        }
        let extra = Task { await session.receive(request(99, "remote.reconnect", params)).output }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(replies.messages.isEmpty)
        domainV2.release()
        let answered = try responses(await extra.value)
        XCTAssertEqual(answered.last?["id"] as? Int, 99, "The 17th is answered in order")
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while replies.messages.count < ControlSession.maximumWaiting, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(Set(replies.messages.compactMap { $0["id"] as? Int }), Set(10..<(10 + ControlSession.maximumWaiting)))

        domainV2.hold(["remote.reconnect"])
        let before = replies.messages.count
        let held = await session.receive(request(100, "remote.reconnect", params)).output
        XCTAssertTrue(held.isEmpty)
        await session.connectionClosed()
        domainV2.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(replies.messages.count, before, "No reply after the connection closed")
    }

    func testRemoteLinkEventsCarryReasonCodesOnly() {
        let ref = EventHostV2(id: host.id, connectionRevision: 1)
        XCTAssertEqual(EventDraftV2.remoteLink(host: ref, state: "needsInput", reason: .hostKeyChanged).data, ["state": .string("needsInput"), "reason": .string("hostKeyChanged")])
        XCTAssertEqual(EventDraftV2.remoteLink(host: ref, state: "connected").data, ["state": .string("connected")])
        XCTAssertEqual(
            ProjectionV2.link(.needsInput(reason: .needsPassphrase)), .object(["state": .string("needsInput"), "reason": .string("needsPassphrase")]))
    }
}
