import AppKit
import XCTest
import TrellisControl
import TrellisCore
@testable import TrellisUI

/// Permissions through the real model (API2-06b, API2-06e) and the grant sheet's rules (API2-06c, API2-06d).
final class AutomationV2PermissionTests: XCTestCase {
    private static let orchestrator = GrantSettings(
        name: "", preset: .agentOrchestrator, capabilities: GrantPreset.agentOrchestrator.capabilities!, scope: GrantPreset.agentOrchestrator.defaultScope)

    /// A `created` grant makes a space, then reads and changes it, its tabs, panes and sessions, and nothing else. UI-made
    /// spaces never join; another grant's created spaces look missing; host.connect into a new space joins it too.
    @MainActor
    func testCreatedScopeEndToEnd() async throws {
        let v = try HarnessV2()
        defer { v.cleanUp() }
        try await v.grant("full")
        let mine = try await v.grant("mine", settings: Self.orchestrator)
        try await v.grant("other", settings: Self.orchestrator)
        let theirs = object(try await v.ok("space.create", ["name": "Theirs"], as: "other"), "space")
        let theirsID = try XCTUnwrap(theirs["id"] as? String)
        // The UI path: the same command the sidebar's New Space runs.
        let uiResult = try await v.model.automationExecute(.createSpace(name: "From the app"))
        let ui = try XCTUnwrap(uiResult.createdSpaceID)
        let user = object(try await v.ok("space.create", ["name": "User's"]), "space")

        let created = try await v.ok("space.create", ["name": "Mine", "start": true], as: "mine")
        let space = object(created, "space")
        let spaceID = try XCTUnwrap(space["id"] as? String)
        XCTAssertEqual(space["name"] as? String, "Mine", "The result shows the new space although the call began without it")
        let tabID = try XCTUnwrap(object(created, "tab")["id"] as? String)
        let paneID = try XCTUnwrap((created["panes"] as? [[String: Any]])?.first?["id"] as? String)
        let recorded = await v.base.grants.activeGrant(id: mine.id)
        XCTAssertEqual(recorded?.createdSpaces.map { $0.uuidString.lowercased() }, [spaceID])

        let list = try await v.ok("space.list", as: "mine")
        XCTAssertEqual((list["spaces"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [spaceID], "Only its own space")
        _ = try await v.ok("space.update", ["id": spaceID, "name": "Renamed"], as: "mine")
        _ = try await v.ok("tab.create", ["spaceId": spaceID], as: "mine")
        let split = try await v.ok("pane.split", ["id": paneID, "axis": "x"], as: "mine")
        XCTAssertNotNil(object(split, "pane")["id"])
        _ = try await v.ok("tab.get", ["id": tabID], as: "mine")
        let sessionID = try XCTUnwrap(v.model.snapshot.panes[try XCTUnwrap(UUID(uuidString: paneID))]?.sessionID)
        let session = object(try await v.ok("session.get", ["id": sessionID.uuidString], as: "mine"), "session")
        XCTAssertEqual(session["state"] as? String, "running", "start: true started the new pane")
        for id in [theirsID, ui.uuidString, try XCTUnwrap(user["id"] as? String)] {
            let hidden = try await v.code("space.get", ["id": id], as: "mine")
            XCTAssertEqual(hidden, "NOT_FOUND", "Another grant's, the app's and the user's spaces look missing")
            let tabs = try await v.code("tab.list", ["spaceId": id], as: "mine")
            XCTAssertEqual(tabs, "NOT_FOUND")
        }
        let reorder = try await v.code("space.reorder", ["ids": [spaceID]], as: "mine")
        XCTAssertEqual(reorder, "PERMISSION_DENIED")
        let everything = try await v.ok("space.list")
        XCTAssertEqual((everything["spaces"] as? [[String: Any]])?.count, 4, "An all-spaces grant still sees everything")

        // host.connect into a new space joins the created scope as well (host approved for this grant).
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent("fake-ssh-\(UUID().uuidString)")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        defer { try? FileManager.default.removeItem(at: fake) }
        v.model.sshExecutable = fake.path
        v.model.resolveHost = { [hosts = v.base.hosts] id in await hosts.host(id) }
        let host = object(try await v.ok("host.create", ["name": "Prod", "destination": "prod"]), "host")
        let hostID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(host["id"] as? String)))
        let saved = try XCTUnwrap(v.base.hosts.hosts.first { $0.id == hostID })
        // Reapproval refreshes hosts already approved and never adds one; approving a new host is a confirmed widening.
        try await v.base.grants.approveHosts(mine.id, hosts: [SavedHostApprovalInput(id: hostID, connectionRevision: saved.connectionRevision)])
        let unchanged = try await v.code("host.connect", ["hostId": hostID.uuidString, "placement": ["kind": "space"]], as: "mine")
        XCTAssertEqual(unchanged, "NOT_FOUND", "Reapprove can't add a host")
        let fetched = await v.base.grants.activeGrant(id: mine.id)
        let current = try XCTUnwrap(fetched)
        var approved = current.settings
        approved.scope.hosts = .approved([HostApproval(hostID: hostID, connectionRevision: saved.connectionRevision)])
        try await v.base.grants.update(mine.id, to: approved, expectedRevision: current.revision, confirmedWidening: true)
        let connected = try await v.ok("host.connect", ["hostId": hostID.uuidString, "placement": ["kind": "space"]], as: "mine")
        let sshPane = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(object(connected, "pane")["id"] as? String)))
        let sshSpace = try XCTUnwrap(v.model.snapshot.panes[sshPane].flatMap { v.model.snapshot.tabs[$0.tabID]?.spaceID })
        let after = try await v.ok("space.list", as: "mine")
        XCTAssertEqual(Set((after["spaces"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []), [spaceID, sshSpace.uuidString.lowercased()])

        // Closing a space it made works; the app then drops it from the scope (AppMain does so once its events are out).
        let scratchResult = try await v.ok("space.create", ["name": "Scratch"], as: "mine")
        let scratch = try XCTUnwrap(object(scratchResult, "space")["id"] as? String)
        let closed = try await v.ok("space.close", ["id": scratch], as: "mine")
        XCTAssertEqual((closed["deleted"] as? [String: String])?["id"], scratch)
        await v.base.grants.forgetCreatedSpaces([try XCTUnwrap(UUID(uuidString: scratch))])
        let pruned = await v.base.grants.activeGrant(id: mine.id)
        XCTAssertEqual(pruned?.createdSpaces.map { $0.uuidString.lowercased() }.sorted(), [spaceID, sshSpace.uuidString.lowercased()].sorted())
    }

    /// A saved agent launch needs agent.control and the agent in the grant's agent scope; refused before anything is created.
    @MainActor
    func testStartingAnAgentPaneFollowsAgentScope() async throws {
        let v = try HarnessV2()
        defer { v.cleanUp() }
        try await v.grant("full")
        let created = try await v.ok("space.create", ["name": "Agents"])
        let tabID = try XCTUnwrap(object(created, "tab")["id"] as? String)
        let paneID = try XCTUnwrap(v.model.snapshot.tabs[try XCTUnwrap(UUID(uuidString: tabID))]?.activePaneID)
        _ = try await v.model.automationExecute(.configureStoppedSession(paneID: paneID, launch: .agent(AgentLaunch(agentID: "trellis-claude-code", directory: nil))))
        var codexOnly = GrantSettings(name: "", capabilities: Set(CapabilityV2.allCases), scope: GrantScope(agents: .agents(["trellis-codex"])))
        try await v.grant("codex", settings: codexOnly)
        let committed = v.model.snapshot
        let duplicate = try await v.call("tab.duplicate", ["id": tabID, "start": true], as: "codex")
        XCTAssertEqual(errorCode(duplicate), "PERMISSION_DENIED")
        XCTAssertEqual(v.model.snapshot, committed, "Refused before anything was created")
        let start = try await v.code("session.start", ["paneId": paneID.uuidString], as: "codex")
        XCTAssertEqual(start, "PERMISSION_DENIED")
        codexOnly.capabilities.remove(.agentControl)
        codexOnly.scope.agents = .all
        try await v.grant("noControl", settings: codexOnly)
        let missing = try await v.call("tab.duplicate", ["id": tabID, "start": true], as: "noControl")
        XCTAssertEqual(details(missing)?["missing"] as? [String], ["agent.control"])
        XCTAssertEqual(v.model.snapshot, committed)
    }

    // MARK: - The grant sheet's rules

    func testPresetsFillCapabilitiesAndScopesAndAnyChangeIsCustom() {
        for preset in GrantPreset.allCases where preset != .custom {
            var draft = GrantDraft(preset: .custom)
            draft.choose(preset)
            let settings = draft.settings(savedHosts: [])
            XCTAssertEqual(settings.capabilities, preset.capabilities, "\(preset)")
            XCTAssertEqual(settings.scope, preset.defaultScope, "\(preset)")
            XCTAssertEqual(settings.preset, preset)
        }
        var draft = GrantDraft(preset: .operator)
        draft.set(.sessionInput, true)
        XCTAssertEqual(draft.preset, .operator, "Setting what it already holds changes nothing")
        draft.set(.sessionInput, false)
        XCTAssertEqual(draft.preset, .custom, "Changing one capability shows Custom")
        XCTAssertFalse(draft.capabilities.contains(.sessionInput))
        draft.choose(.custom)
        XCTAssertFalse(draft.capabilities.contains(.sessionInput), "Choosing Custom keeps the current capabilities")
        draft.choose(.fullControl)
        XCTAssertEqual(draft.capabilities, Set(CapabilityV2.allCases))
        XCTAssertEqual(Set(CapabilityV2.allCases.map(\.area)), Set(CapabilityV2.Area.allCases), "Every area has capabilities")
        for capability in CapabilityV2.allCases {
            XCTAssertFalse(capability.localizedSummary.contains(capability.rawValue), "\(capability.rawValue) is described in plain language")
        }
    }

    func testAdvancedOpensByItselfOnlyWhenARoleWouldHideSomething() {
        XCTAssertEqual(GrantDraft().lifetime, 7 * 86_400, "A new grant lasts 7 days unless another expiry is chosen")
        for preset in GrantPreset.allCases where preset != .custom {
            var draft = GrantDraft(preset: preset)
            XCTAssertFalse(draft.needsAdvanced, "\(preset) with its default scopes stays collapsed")
            draft.spaceChoice = .chosen
            XCTAssertFalse(draft.needsAdvanced, "Spaces are on the main form")
        }
        var custom = GrantDraft(preset: .operator)
        custom.set(.sessionInput, false)
        XCTAssertTrue(custom.needsAdvanced, "A Custom grant shows its capabilities")
        var projects = GrantDraft(preset: .observer)
        projects.allProjects = false
        XCTAssertTrue(projects.needsAdvanced, "Chosen projects differ from the role's all")
        var hosts = GrantDraft(preset: .operator)
        XCTAssertFalse(hosts.needsAdvanced, "Approved hosts, none chosen, is Operator's default")
        hosts.hosts = [UUID()]
        XCTAssertTrue(hosts.needsAdvanced, "An approved host was chosen in Advanced")
        var agents = GrantDraft(preset: .fullControl)
        agents.allAgents = false
        XCTAssertTrue(agents.needsAdvanced)
    }

    func testEditingDecidesWhenToConfirm() throws {
        let host = SavedHost(id: UUID(), draft: try HostDraft(name: "Prod", destination: "prod").validated { _ in false }, revision: 4)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let grant = AutomationGrant(
            id: UUID(), tokenHash: "",
            settings: GrantSettings(
                name: "Bot", preset: .operator, capabilities: GrantPreset.operator.capabilities!,
                scope: GrantScope(hosts: .approved([HostApproval(hostID: host.id, connectionRevision: 1)]))),
            createdAt: now, expiresAt: now.addingTimeInterval(3_600))
        let untouched = GrantDraft(grant: grant)
        XCTAssertEqual(untouched.change(from: grant, savedHosts: [host], now: now), GrantChange(), "Opening and saving changes nothing")
        XCTAssertEqual(
            untouched.settings(savedHosts: [host], existing: grant.hostScope).scope.hosts, grant.hostScope, "A kept host keeps the revision it was approved at")
        var added = untouched
        added.set(.sessionExecute, true)
        XCTAssertTrue(added.change(from: grant, savedHosts: [host], now: now).widens)
        var removed = untouched
        removed.set(.sessionInput, false)
        XCTAssertEqual(removed.change(from: grant, savedHosts: [host], now: now), GrantChange(narrows: true))
        var allHosts = untouched
        allHosts.allHosts = true
        XCTAssertTrue(allHosts.change(from: grant, savedHosts: [host], now: now).widens)
        var later = untouched
        later.lifetime = 86_400
        XCTAssertTrue(later.change(from: grant, savedHosts: [host], now: now).widens, "A later expiry widens")
        var created = untouched
        created.spaceChoice = .created
        XCTAssertEqual(created.change(from: grant, savedHosts: [host], now: now), GrantChange(narrows: true))
    }

    /// Cancel on the confirmation keeps the grant exactly as it was; confirming applies it; narrowing needs no question.
    @MainActor
    func testTheListModelAsksBeforeWideningOnly() async throws {
        let store = GrantStore(url: nil, secrets: NoSecrets())
        let model = GrantListModel(store: store)
        let token = await model.create(GrantSettings(name: "Bot", preset: .observer, capabilities: GrantPreset.observer.capabilities!), lifetime: 3_600)
        XCTAssertNotNil(try token.get())
        await model.refresh()
        let grant = try XCTUnwrap(model.grants.first)
        var draft = GrantDraft(grant: grant)
        draft.set(.sessionInput, true)
        let first = await model.edit(grant, to: draft.settings(savedHosts: []), lifetime: nil, confirmed: false)
        XCTAssertEqual(first, .needsConfirmation)
        let unchanged = await store.activeGrant(id: grant.id)
        XCTAssertEqual(unchanged, grant)
        let confirmed = await model.edit(grant, to: draft.settings(savedHosts: []), lifetime: nil, confirmed: true)
        XCTAssertEqual(confirmed, .saved)
        let current = await store.activeGrant(id: grant.id)
        let widened = try XCTUnwrap(current)
        XCTAssertEqual(widened.revision, 2)
        XCTAssertEqual(widened.preset, .custom)
        var narrower = GrantDraft(grant: widened)
        narrower.set(.sessionInput, false)
        narrower.set(.hostRead, false)
        let narrowed = await model.edit(widened, to: narrower.settings(savedHosts: []), lifetime: nil, confirmed: false)
        XCTAssertEqual(narrowed, .saved, "Narrowing applies without a question")
        let stale = await model.edit(widened, to: narrower.settings(savedHosts: []), lifetime: nil, confirmed: true)
        XCTAssertEqual(stale, .failed(.conflict, applied: false), "An edit from an old copy of the grant is refused")
    }
}
