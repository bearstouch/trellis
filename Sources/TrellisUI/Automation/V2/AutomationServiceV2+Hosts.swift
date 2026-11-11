import Foundation
import TrellisControl
import TrellisCore

/// `host.*` (methods.md#hosts). The host library validates and versions hosts; passwords stay a UI action (FR-H09).
extension AutomationServiceV2 {
    @MainActor func performHosts(_ call: CallV2) async throws -> JSONValue {
        let p = call.params
        switch call.spec.name {
        case "host.list":
            let tags = Set((try p.optionalStrings("tags") ?? []).map { $0.lowercased() })
            let visible = SavedHost.search(hosts.hosts, query: try p.optionalString("query") ?? "").filter { host in
                call.access.hostAccess(host) == .allowed && tags.isSubset(of: Set(host.tags.map { $0.lowercased() }))
            }
            let page = try PageV2(p, method: call.spec.name).slice(visible)
            let projection = projection(call, spaces: [])
            return ConventionsV2.list("hosts", page.items.map { projection.host($0, remote: remote($0.id)) }, revision: nil, nextCursor: page.nextCursor)
        case "host.get": return ConventionsV2.resource("host", try host(call, try p.uuid("id")))
        case "host.create":
            let saved = try Self.saved(await hosts.save(try Self.draft(p, base: nil), editing: nil))
            // The creator sees what it saved even when its host scope (approved hosts) doesn't include the new host yet;
            // using it still needs an approval.
            return ConventionsV2.resource("host", projection(call, spaces: []).host(saved, remote: remote(saved.id)))
        case "host.update":
            guard var editing = hosts.hosts.first(where: { $0.id == (try? p.uuid("id")) }) else { throw Self.notFound }
            let draft = try Self.draft(p, base: editing.draft)
            // The library checks the revision atomically with the change.
            if let expected = p.expectedRevision { editing.revision = expected }
            let saved = try Self.saved(await hosts.save(draft, editing: editing))
            return ConventionsV2.resource("host", try host(call, saved.id))
        case "host.delete":
            guard var current = hosts.hosts.first(where: { $0.id == (try? p.uuid("id")) }) else { throw Self.notFound }
            if let expected = p.expectedRevision { current.revision = expected }
            if let error = await hosts.delete(current) { throw Self.map(error) }
            return ConventionsV2.deleted(kind: "host", id: current.id, workspaceRevision: nil)
        case "host.connect": return try await connect(call)
        default: throw ControlError.methodNotFound
        }
    }

    @MainActor private func host(_ call: CallV2, _ id: UUID) throws -> JSONValue {
        guard let host = hosts.hosts.first(where: { $0.id == id }), call.access.hostAccess(host) == .allowed else { throw Self.notFound }
        return projection(call, spaces: []).host(host, remote: remote(id))
    }

    /// The helper and link of a host used as a remote workspace (FR-RW07, FR-RW17).
    @MainActor private func remote(_ id: UUID) -> HostRuntimeV2 {
        let preferences = model.remoteHosts?.preferences[id]
        let link: RemoteLinkV2? =
            switch model.remoteLinks[id] {
            case .connecting?: .connecting
            case .connected?: .connected
            case .reconnecting(let attempt, let at)?: .reconnecting(attempt: attempt, at: at)
            case .offline?: .offline
            case .needsInput?: .needsInput
            case .disconnected?: .disconnected
            case nil: nil
            }
        return HostRuntimeV2(helper: preferences?.helper, autoInstall: preferences?.autoInstall ?? false, link: link)
    }

    private static func saved(_ result: Result<SavedHost, HostLibraryError>) throws -> SavedHost {
        switch result {
        case .success(let host): return host
        case .failure(let error): throw map(error)
        }
    }

    /// Host fields; omitted fields keep `base`, and `null` clears an optional one.
    private static func draft(_ p: ParamsV2, base: HostDraft?) throws -> HostDraft {
        var draft = base ?? HostDraft()
        if let name = try p.optionalString("name") { draft.name = name }
        if let destination = try p.optionalString("destination") { draft.destination = destination }
        if p.sent("user") { draft.user = try p.optionalString("user") ?? "" }
        if p.sent("port") { draft.port = try p.optionalInteger("port").map(String.init) ?? "" }
        if p.sent("identityFile") { draft.identityFile = try p.optionalString("identityFile") ?? "" }
        if p.sent("tags") {
            let tags = try p.optionalStrings("tags") ?? []
            guard tags.allSatisfy({ !$0.contains(",") }) else { throw ControlError.invalidParams("Tags can't contain commas.", fields: ["tags": "array of strings without commas"]) }
            draft.tags = tags.joined(separator: ",")
        }
        return draft
    }

    /// An ssh pane in a new tab, a split or a new space, as the app's Connect does; the tab is named after the host.
    @MainActor private func connect(_ call: CallV2) async throws -> JSONValue {
        let p = call.params
        let hostID = try p.uuid("hostId")
        guard let host = hosts.hosts.first(where: { $0.id == hostID }), let placement = try p.optionalObject("placement") else { throw Self.notFound }
        let title = host.name
        let paneID: UUID
        switch try placement.string("kind") {
        case "split":
            let target = try placement.uuid("paneId")
            guard let pane = model.snapshot.panes[target], let size = model.automationTerminalSize(target) else { throw Self.notFound }
            try requireLocalSpace(model.snapshot.tabs[pane.tabID]?.spaceID)
            guard model.maximizedPanes[pane.tabID] == nil else { throw Self.invalidState("Restore the maximized pane before connecting in a split.", state: "maximized") }
            let axis: SplitAxis = try placement.optionalString("axis") == "y" ? .y : .x
            guard let created = try await run(.splitPane(id: target, axis: axis, availableSize: size)).createdPaneID else { throw ControlError.internalError }
            paneID = created
        case "tab":
            let spaceID = try placement.uuid("spaceId")
            try requireLocalSpace(spaceID)
            let result = try await run(.createTab(spaceID: spaceID), then: { result in result.createdTabID.map { .renameTab(id: $0, title: title) } })
            guard let tab = result.createdTabID.flatMap({ result.snapshot.tabs[$0] }) else { throw ControlError.internalError }
            paneID = tab.activePaneID
        default:
            let name = try Self.name(placement, "name") ?? title
            let result = try await run(
                .createSpace(name: name),
                then: { result in result.createdSpaceID.flatMap { id in result.snapshot.spaces.first { $0.id == id }?.activeTabID }.map { .renameTab(id: $0, title: title) } })
            guard let space = result.createdSpaceID.flatMap({ id in result.snapshot.spaces.first { $0.id == id } }), let tab = result.snapshot.tabs[space.activeTabID] else {
                throw ControlError.internalError
            }
            paneID = tab.activePaneID
        }
        do { try await model.automationStartSession(paneID, launch: .host(hostID), environment: [:]) } catch { throw Self.map(error) }
        await model.waitForUpdates()
        guard let sessionID = model.snapshot.panes[paneID]?.sessionID else { throw Self.notFound }
        let session = try session(call, sessionID)
        if model.snapshot.sessions[sessionID]?.state == .failed || model.terminals[paneID]?.sessionState == .failed {
            throw ControlError.api(.launchFailed, "ssh could not be started.", details: .object(["session": session]))
        }
        return .object(["session": session, "pane": try pane(call, paneID), "workspaceRevision": ConventionsV2.number(model.snapshot.revision)])
    }

    /// A remote workspace runs only remote shells on its own host, so an ssh pane can't open in one (checked before
    /// anything is created).
    @MainActor private func requireLocalSpace(_ spaceID: UUID?) throws {
        guard let space = model.snapshot.spaces.first(where: { $0.id == spaceID }) else { throw Self.notFound }
        guard space.remoteHostID == nil else { throw Self.invalidState("An ssh pane can't open in a remote workspace.", state: "remote") }
    }
}
