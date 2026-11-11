import Foundation
import TrellisControl
import TrellisCore

/// `workspace.*` and `space.*` (methods.md#system-and-workspace, #spaces).
extension AutomationServiceV2 {
    /// workspace.get answers within the 1 MiB frame, leaving room for the JSON-RPC envelope.
    static let workspaceResultLimit = ControlFramer.maximumFrame - 4_096

    @MainActor func performSpaces(_ call: CallV2) async throws -> JSONValue {
        let p = call.params
        switch call.spec.name {
        case "workspace.get": return try workspaceGet(call)
        case "workspace.save":
            guard !model.isRestoring, !model.persistenceReadOnly, model.recoveryMessage == nil else {
                throw Self.invalidState("The workspace can't be saved now: it is restoring, read-only or being recovered.", state: model.isRestoring ? "busy" : "readOnly")
            }
            guard await model.flushWorkspaceSave() else { throw Self.invalidState("The workspace could not be written. Retry shortly.", retryable: true) }
            return .object(["savedAt": .string(ConventionsV2.timestamp(Date()))])
        case "space.list":
            let projection = projection(call)
            let page = try PageV2(p, method: call.spec.name).slice(projection.visibleSpaces())
            return ConventionsV2.list("spaces", page.items.map(projection.space), revision: projection.snapshot.revision, nextCursor: page.nextCursor)
        case "space.get": return ConventionsV2.resource("space", try space(call, try p.uuid("id")))
        case "space.create":
            guard let name = try Self.name(p, "name") else { throw ControlError.invalidParams("name is required.", fields: ["name": "1–200 characters"]) }
            let result = try await run(.createSpace(name: name), expecting: p.expectedRevision.map { .workspace(revision: $0) })
            guard let spaceID = result.createdSpaceID, let space = result.snapshot.spaces.first(where: { $0.id == spaceID }), let tab = result.snapshot.tabs[space.activeTabID]
            else { throw ControlError.internalError }
            if try p.optionalBool("start") == true { await model.automationStart(tab.root.paneIDs) }
            return try created(call, spaceID: spaceID, tabID: tab.id, includeSpace: true)
        case "space.update":
            let id = try p.uuid("id")
            guard let name = try Self.name(p, "name") else { throw ControlError.invalidParams("name is required.", fields: ["name": "1–200 characters"]) }
            let result = try await run(.renameSpace(id: id, name: name), expecting: p.expectedRevision.map { .space(id, revision: $0) })
            return ConventionsV2.resource("space", try space(call, id), workspaceRevision: result.snapshot.revision)
        case "space.reorder":
            let result = try await run(.reorderSpaces(ids: try p.uuids("ids")), expecting: p.expectedRevision.map { .workspace(revision: $0) })
            let projection = projection(call)
            return ConventionsV2.list("spaces", projection.visibleSpaces().map(projection.space), revision: result.snapshot.revision)
        case "space.focus":
            let id = try p.uuid("id")
            let result = try await run(.selectSpace(id: id), expecting: p.expectedRevision.map { .space(id, revision: $0) })
            return ConventionsV2.resource("space", try space(call, id), workspaceRevision: result.snapshot.revision)
        case "space.close":
            let id = try p.uuid("id")
            return try await close(.deleteSpace(id: id), kind: "space", id: id, p, expecting: p.expectedRevision.map { .space(id, revision: $0) })
        default: throw ControlError.methodNotFound
        }
    }

    @MainActor private func space(_ call: CallV2, _ id: UUID) throws -> JSONValue {
        let projection = projection(call, spaces: [id])
        guard let space = projection.snapshot.spaces.first(where: { $0.id == id }), projection.access.canSee(space: id) else { throw Self.notFound }
        return projection.space(space)
    }

    /// `{space?, tab, panes, workspaceRevision}` after a create; the tab carries its layout.
    @MainActor func created(_ call: CallV2, spaceID: UUID, tabID: UUID, includeSpace: Bool) throws -> JSONValue {
        let projection = projection(call, spaces: [spaceID])
        guard let tab = projection.snapshot.tabs[tabID], let space = projection.snapshot.spaces.first(where: { $0.id == spaceID }) else { throw Self.notFound }
        var object: [String: JSONValue] = [
            "tab": projection.tab(tab, layout: true), "panes": .array(tab.root.paneIDs.compactMap { projection.snapshot.panes[$0] }.map(projection.pane)),
            "workspaceRevision": ConventionsV2.number(projection.snapshot.revision)
        ]
        if includeSpace { object["space"] = projection.space(space) }
        return .object(object)
    }

    /// Close through the shared closure policy; `{deleted, workspaceRevision}` once it is gone.
    @MainActor func close(_ command: WorkspaceCommand, kind: String, id: UUID, _ p: ParamsV2, expecting: ResourceExpectation?) async throws -> JSONValue {
        let allowRunning = try p.optionalBool("allowRunning") == true, force = try p.optionalBool("force") == true
        let outcome: AutomationCloseResult
        do { outcome = try await model.automationClose(command, allowRunning: allowRunning, force: force, expecting: expecting) } catch { throw Self.map(error) }
        if let failure = Self.closeFailure(outcome) { throw failure }
        return ConventionsV2.deleted(kind: kind, id: id, workspaceRevision: model.snapshot.revision)
    }

    /// One snapshot pass over everything in scope; too large for one frame is LIMIT_EXCEEDED, so the client pages instead.
    @MainActor private func workspaceGet(_ call: CallV2) throws -> JSONValue {
        let include = Set(try call.params.optionalStrings("include") ?? [])
        let projection = projection(call)
        let spaces = projection.visibleSpaces()
        let snapshot = projection.snapshot
        var object: [String: JSONValue] = ["revision": ConventionsV2.number(snapshot.revision), "spaces": .array(spaces.map(projection.space))]
        if let active = snapshot.activeSpaceID, projection.access.canSee(space: active) { object["activeSpaceId"] = ConventionsV2.idJSON(active) }
        let tabs = spaces.flatMap { $0.tabIDs.compactMap { snapshot.tabs[$0] } }
        let panes = tabs.flatMap { $0.root.paneIDs.compactMap { snapshot.panes[$0] } }
        if include.contains("tabs") || include.contains("layout") { object["tabs"] = .array(tabs.map { projection.tab($0, layout: include.contains("layout")) }) }
        if include.contains("panes") { object["panes"] = .array(panes.map(projection.pane)) }
        if include.contains("sessions") {
            object["sessions"] = .array(panes.compactMap { pane in snapshot.sessions[pane.sessionID].map { projection.session($0, paneID: pane.id) } })
        }
        let result = JSONValue.object(object)
        guard (try? JSONEncoder().encode(result).count).map({ $0 <= Self.workspaceResultLimit }) ?? false else {
            throw ControlError.api(.limitExceeded, "The workspace is too large for one reply. Page through space.list, tab.list and pane.list instead.")
        }
        return result
    }
}
