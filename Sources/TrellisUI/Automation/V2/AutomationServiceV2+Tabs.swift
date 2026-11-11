import Foundation
import TrellisControl
import TrellisCore

/// `tab.*` and `pane.*` (methods.md#tabs, #panes).
extension AutomationServiceV2 {
    @MainActor func performTabs(_ call: CallV2) async throws -> JSONValue {
        let p = call.params
        switch call.spec.name {
        case "tab.list":
            let spaceID = try p.uuid("spaceId")
            let projection = projection(call, spaces: [spaceID])
            guard let space = projection.snapshot.spaces.first(where: { $0.id == spaceID }) else { throw Self.notFound }
            let layout = try p.optionalStrings("include")?.contains("layout") == true
            let page = try PageV2(p, method: call.spec.name).slice(space.tabIDs.compactMap { projection.snapshot.tabs[$0] })
            return ConventionsV2.list("tabs", page.items.map { projection.tab($0, layout: layout) }, revision: space.revision, nextCursor: page.nextCursor)
        case "tab.get": return ConventionsV2.resource("tab", try tab(call, try p.uuid("id")))
        case "tab.create":
            let spaceID = try p.uuid("spaceId")
            let title = try Self.name(p, "title"), color = try p.optionalString("color").flatMap(TabColor.init(rawValue:))
            if try p.optionalBool("start") == true { try await requireStartable(space: spaceID, call) }
            // Create and title in one store transaction, so a failure leaves no tab; the color, already validated, follows.
            let result = try await run(
                .createTab(spaceID: spaceID), expecting: p.expectedRevision.map { .space(spaceID, revision: $0) },
                then: { created in title.flatMap { title in created.createdTabID.map { .renameTab(id: $0, title: title) } } })
            guard let tabID = result.createdTabID, let tab = result.snapshot.tabs[tabID] else { throw ControlError.internalError }
            if let color { _ = try await run(.setTabColor(id: tabID, color: color)) }
            if try p.optionalBool("start") == true { await model.automationStart(tab.root.paneIDs) }
            return try created(call, spaceID: spaceID, tabID: tabID, includeSpace: false)
        case "tab.update":
            let id = try p.uuid("id")
            let expecting = p.expectedRevision.map { ResourceExpectation.tab(id, revision: $0) }
            // A null title returns to the automatic one (FR-SI05): the default title is what the tab bar replaces.
            var title: String?, color: WorkspaceCommand?
            if p.sent("title") { title = try Self.name(p, "title") ?? WorkspaceTab.defaultTitle }
            if p.sent("color") { color = .setTabColor(id: id, color: try p.optionalString("color").flatMap(TabColor.init(rawValue:))) }
            let result: WorkspaceCommandResult
            if let title {
                // Title and color change together or not at all.
                let follow = color
                result = try await run(.renameTab(id: id, title: title), expecting: expecting, then: { _ in follow })
            } else if let color {
                result = try await run(color, expecting: expecting)
            } else {
                throw ControlError.invalidParams("Send title, color or both.", fields: ["title": "send at least one of title, color", "color": "send at least one of title, color"])
            }
            return ConventionsV2.resource("tab", try tab(call, id), workspaceRevision: result.snapshot.revision)
        case "tab.duplicate":
            let id = try p.uuid("id")
            // The copies run what the source panes run: an agent or a saved host needs what starting it directly needs.
            if try p.optionalBool("start") == true, let source = model.snapshot.tabs[id] {
                let launches = source.root.paneIDs.compactMap { model.snapshot.panes[$0].flatMap { model.snapshot.sessions[$0.sessionID]?.launch } }
                for launch in launches { try requireLaunchAccess(launch, call) }
                for launch in launches { try await readyRemoteLink(for: launch, call) }
            }
            let result = try await run(.duplicateTab(id: id), expecting: p.expectedRevision.map { .tab(id, revision: $0) })
            guard let tabID = result.createdTabID, let tab = result.snapshot.tabs[tabID] else { throw ControlError.internalError }
            if try p.optionalBool("start") == true { await model.automationStart(tab.root.paneIDs) }
            return try created(call, spaceID: tab.spaceID, tabID: tabID, includeSpace: false)
        case "tab.reorder":
            let spaceID = try p.uuid("spaceId")
            let result = try await run(.reorderTabs(spaceID: spaceID, ids: try p.uuids("ids")), expecting: p.expectedRevision.map { .space(spaceID, revision: $0) })
            let projection = projection(call, spaces: [spaceID])
            guard let space = result.snapshot.spaces.first(where: { $0.id == spaceID }) else { throw Self.notFound }
            return ConventionsV2.list("tabs", space.tabIDs.compactMap { projection.snapshot.tabs[$0] }.map { projection.tab($0, layout: false) }, revision: space.revision)
        case "tab.focus":
            let id = try p.uuid("id")
            let result = try await run(.selectTab(id: id), expecting: p.expectedRevision.map { .tab(id, revision: $0) })
            return ConventionsV2.resource("tab", try tab(call, id), workspaceRevision: result.snapshot.revision)
        case "tab.close":
            let id = try p.uuid("id")
            return try await close(.deleteTab(id: id), kind: "tab", id: id, p, expecting: p.expectedRevision.map { .tab(id, revision: $0) })
        default: throw ControlError.methodNotFound
        }
    }

    @MainActor func tab(_ call: CallV2, _ id: UUID, layout: Bool = true) throws -> JSONValue {
        guard let spaceID = model.snapshot.tabs[id]?.spaceID else { throw Self.notFound }
        let projection = projection(call, spaces: [spaceID])
        guard let tab = projection.snapshot.tabs[id], projection.access.canSee(space: spaceID) else { throw Self.notFound }
        return projection.tab(tab, layout: layout)
    }

    @MainActor func pane(_ call: CallV2, _ id: UUID) throws -> JSONValue {
        let projection = projection(call, spaces: spaceOf(pane: id))
        guard let pane = projection.snapshot.panes[id], projection.canSee(.pane, id) else { throw Self.notFound }
        return projection.pane(pane)
    }

    @MainActor func performPanes(_ call: CallV2) async throws -> JSONValue {
        let p = call.params
        switch call.spec.name {
        case "pane.list":
            let snapshot = model.snapshot
            let tabs: [WorkspaceTab], revision: UInt64, spaceID: UUID
            if let tabID = try p.optionalUUID("tabId") {
                guard let tab = snapshot.tabs[tabID] else { throw Self.notFound }
                tabs = [tab]; revision = tab.revision; spaceID = tab.spaceID
            } else {
                let id = try p.uuid("spaceId")
                guard let space = snapshot.spaces.first(where: { $0.id == id }) else { throw Self.notFound }
                tabs = space.tabIDs.compactMap { snapshot.tabs[$0] }; revision = space.revision; spaceID = id
            }
            let projection = projection(call, spaces: [spaceID])
            let page = try PageV2(p, method: call.spec.name).slice(tabs.flatMap { $0.root.paneIDs.compactMap { snapshot.panes[$0] } })
            return ConventionsV2.list("panes", page.items.map(projection.pane), revision: revision, nextCursor: page.nextCursor)
        case "pane.get": return ConventionsV2.resource("pane", try pane(call, try p.uuid("id")))
        case "pane.split": return try await split(call)
        case "pane.resize":
            let branchID = try p.uuid("branchId")
            guard let ratio = try p.optionalDouble("ratio"), let tab = model.snapshot.tabs.values.first(where: { $0.root.contains(branch: branchID) }) else { throw Self.notFound }
            let result = try await run(
                .resizeSplit(tabID: tab.id, splitID: branchID, ratio: ratio, canvas: model.automationCanvas(tab.id)), expecting: p.expectedRevision.map { .tab(tab.id, revision: $0) })
            return ConventionsV2.resource("tab", try self.tab(call, tab.id), workspaceRevision: result.snapshot.revision)
        case "pane.focus":
            let id = try p.uuid("id")
            let result = try await run(.selectPane(id: id))
            return ConventionsV2.resource("pane", try pane(call, id), workspaceRevision: result.snapshot.revision)
        case "pane.maximize":
            let id = try p.uuid("id")
            let maximized = try p.bool("maximized")
            do { try await model.automationSetMaximized(id, maximized) } catch { throw Self.map(error) }
            guard let tabID = model.snapshot.panes[id]?.tabID else { throw Self.notFound }
            return .object([
                "pane": try pane(call, id), "tab": try tab(call, tabID, layout: false), "workspaceRevision": ConventionsV2.number(model.snapshot.revision)
            ])
        case "pane.close":
            let id = try p.uuid("id")
            return try await close(.deletePane(id: id), kind: "pane", id: id, p, expecting: nil)
        default: throw ControlError.methodNotFound
        }
    }

    /// As the app splits: the existing pane is the first child, the new pane inherits its machine (the space's) and folder.
    @MainActor private func split(_ call: CallV2) async throws -> JSONValue {
        let p = call.params
        let paneID = try p.uuid("id")
        let axis: SplitAxis = try p.string("axis") == "y" ? .y : .x
        let ratio = try p.optionalDouble("ratio")
        guard let size = model.automationTerminalSize(paneID), let tabID = model.snapshot.panes[paneID]?.tabID else { throw Self.notFound }
        // Same rule as the UI: a new pane must not open hidden behind a maximized one.
        guard model.maximizedPanes[tabID] == nil else { throw Self.invalidState("Restore the maximized pane (pane.maximize false) before splitting this tab.", state: "maximized") }
        if try p.optionalBool("start") == true, let spaceID = model.snapshot.tabs[tabID]?.spaceID { try await requireStartable(space: spaceID, call) }
        let canvas = model.automationCanvas(tabID)
        // Split and apply the ratio in one store transaction, so a ratio that breaks the size rules leaves no split behind.
        let result = try await run(
            .splitPane(id: paneID, axis: axis, availableSize: size),
            then: { split in
                guard let ratio, ratio != 0.5, let newID = split.createdPaneID, let tab = split.snapshot.panes[newID].flatMap({ split.snapshot.tabs[$0.tabID] }),
                    case .split(let branch, _, _, _)? = tab.root.parent(of: newID)
                else { return nil }
                return .resizeSplit(tabID: tab.id, splitID: branch, ratio: ratio, canvas: canvas)
            })
        guard let newID = result.createdPaneID else { throw ControlError.internalError }
        await model.inheritDirectory(from: paneID, into: newID)
        if try p.optionalBool("start") == true { await model.automationStart([newID]) }
        return .object([
            "pane": try pane(call, newID), "tab": try tab(call, tabID), "workspaceRevision": ConventionsV2.number(model.snapshot.revision)
        ])
    }
}

extension AutomationServiceV2 {
    /// A new pane runs its space's default launch: in a remote workspace that connects to the space's host, so its link
    /// is made ready (and the helperInstall rule applied) before anything is created.
    @MainActor func requireStartable(space id: UUID, _ call: CallV2) async throws {
        guard let space = model.snapshot.spaces.first(where: { $0.id == id }) else { throw Self.notFound }
        try requireLaunchAccess(space.defaultLaunch, call)
        try await readyRemoteLink(for: space.defaultLaunch, call)
    }
}

extension PaneLayout {
    /// The split whose child is this pane.
    func parent(of paneID: UUID) -> PaneLayout? {
        guard case .split(_, _, _, let children) = self else { return nil }
        if children.contains(.pane(paneID)) { return self }
        return children.lazy.compactMap { $0.parent(of: paneID) }.first
    }
}
