import XCTest
import TrellisCore
@testable import TrellisControl

/// Review-driven checks of protocol 2 events: a closed `created` space's last events and the order of live status.
final class EventsV2ReviewTests: XCTestCase {
    private let secrets = MemorySecrets()
    private lazy var store = GrantStore(url: nil, secrets: secrets)

    private func types(_ result: Result<JSONValue, ControlError>) throws -> [String] {
        guard case .object(let object) = try result.get(), case .array(let items)? = object["events"] else { throw ControlError.internalError }
        return items.compactMap { if case .object(let event) = $0, case .string(let type)? = event["type"] { type } else { nil } }
    }

    /// The space leaves the grant's `created` scope right after its `space.deleted` is published (events.md), yet a poll
    /// made afterwards still returns that space's last events to the grant that created it, and to no other.
    func testACreatedScopeGrantStillPollsItsClosedSpacesLastEvents() async throws {
        let created = try await store.create(GrantSettings(name: "Bot", capabilities: Set(CapabilityV2.allCases), scope: GrantScope(spaces: .created)), lifetime: 3600).grant
        let other = try await store.create(GrantSettings(name: "Other", capabilities: Set(CapabilityV2.allCases), scope: GrantScope(spaces: .created)), lifetime: 3600).grant
        let space = UUID(), pane = PaneRefV2(pane: UUID(), session: UUID(), tab: UUID(), space: space)
        store.createdSpaceLedger.record(space, grant: created.id)
        let hub = EventHubV2(instanceID: UUID(), grants: store)
        await hub.publish([.commandStarted(pane), EventDraftV2("pane.deleted", kind: "pane", id: pane.pane, spaceID: space), EventDraftV2("space.deleted", kind: "space", id: space, spaceID: space)])
        await store.forgetCreatedSpaces([space])
        let filter = EventFilterV2(topics: [.workspace, .shell])
        let mine = try types(await hub.poll(grantID: created.id, filter: filter, afterSequence: 0, instanceID: nil, timeoutMs: 0, limit: 10))
        XCTAssertEqual(mine, ["command.started", "pane.deleted", "space.deleted"])
        let theirs = try types(await hub.poll(grantID: other.id, filter: filter, afterSequence: 0, instanceID: nil, timeoutMs: 0, limit: 10))
        XCTAssertEqual(theirs, [])
        // A later event in a space the grant no longer has (a stale ID) isn't shown.
        await hub.publish([.commandStarted(pane)])
        let later = try types(await hub.poll(grantID: created.id, filter: filter, afterSequence: 3, instanceID: nil, timeoutMs: 0, limit: 10))
        XCTAssertEqual(later, [])
    }

    /// Live status waiting for its window goes out before the event that ends its resource, never after it.
    func testPendingLiveStatusPrecedesTheEventThatEndsItsResource() async throws {
        let grant = try await store.create(GrantSettings(name: "Bot", capabilities: Set(CapabilityV2.allCases)), lifetime: 3600).grant
        let hub = EventHubV2(instanceID: UUID(), grants: store, coalesceWindow: .seconds(30))
        let pane = PaneRefV2(pane: UUID(), session: UUID(), tab: UUID(), space: UUID())
        await hub.publish([.agentState(pane, agentID: "a", state: .working, previous: .ready)])
        await hub.publish([.agentState(pane, agentID: "a", state: .done, previous: .working)])
        await hub.publish([.needsInput(pane, reason: .attention)])
        await hub.publish([.needsInput(pane, reason: nil)])
        await hub.publish([.agentEnded(pane, agentID: "a")])
        await hub.publish([EventDraftV2("pane.deleted", kind: "pane", id: pane.pane, spaceID: pane.space, related: [pane.session, pane.tab])])
        let all = try types(
            await hub.poll(grantID: grant.id, filter: EventFilterV2(topics: [.agent, .attention, .workspace]), afterSequence: 0, instanceID: nil, timeoutMs: 0, limit: 20))
        XCTAssertEqual(all, ["agent.state", "pane.needsInput", "agent.state", "pane.needsInput", "agent.ended", "pane.deleted"])
    }
}
