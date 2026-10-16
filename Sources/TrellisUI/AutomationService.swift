import Foundation
import TrellisControl
import TrellisCore

/// Executes authorized API methods through the shared workspace model and
/// host library. Authorization has already run; this layer still filters
/// listings and redacts fields by grant so hidden data is never returned.
public final class AutomationService: ControlDomain, @unchecked Sendable {
    private let model: AppWorkspaceModel
    private let hosts: HostListModel
    private let instanceID: UUID

    @MainActor public init(model: AppWorkspaceModel, hosts: HostListModel, instanceID: UUID = UUID()) {
        self.model = model; self.hosts = hosts; self.instanceID = instanceID
    }

    public func snapshot() async -> WorkspaceSnapshot { await model.snapshotForAutomation() }
    public func host(_ id: UUID) async -> SavedHost? { await hosts.host(id) }

    public func execute(_ method: String, params: JSONValue?, access: GrantAccess) async -> Result<JSONValue, ControlError> {
        await perform(method, Params(params), access)
    }

    // MARK: - Dispatch

    @MainActor private func perform(_ method: String, _ p: Params, _ access: GrantAccess) async -> Result<JSONValue, ControlError> {
        do {
            switch method {
            case "system.info": return .success(systemInfo(access))
            case "window.list": return .success(.object(["windows": .array(visibleWindows(access).map(windowJSON)), "revision": revision(model.snapshot.revision)]))
            case "window.get": return .success(try windowDetail(try p.uuid("id")))
            case "window.create": return .success(try await createWindow(p))
            case "window.update":
                let id = try p.uuid("id"), name = try p.string("name")
                let result = try await run(.renameWindow(id: id, name: name), expecting: try p.revision().map { .window(id, revision: $0) })
                return .success(try windowJSON(result.snapshot, id))
            case "window.reorder":
                let ids = try p.uuids("ids")
                let result = try await run(.reorderWindows(ids: ids), expecting: try p.revision().map { .workspace(revision: $0) })
                return .success(.object(["ids": .array(result.snapshot.windows.map { .string($0.id.uuidString) }), "revision": revision(result.snapshot.revision)]))
            case "window.focus":
                let result = try await run(.selectWindow(id: try p.uuid("id")))
                return .success(.object(["activeWindowId": .string(result.snapshot.activeWindowID?.uuidString ?? ""), "revision": revision(result.snapshot.revision)]))
            case "window.close":
                let id = try p.uuid("id")
                return try await close(.deleteWindow(id: id), p, expecting: try p.revision().map { .window(id, revision: $0) })
            case "tab.list":
                let windowID = try p.uuid("windowId")
                let tabs = model.snapshot.windows.first { $0.id == windowID }?.tabIDs.compactMap { model.snapshot.tabs[$0] } ?? []
                return .success(.object(["tabs": .array(tabs.map { tabJSON($0, access, tree: false) })]))
            case "tab.get":
                guard let tab = model.snapshot.tabs[try p.uuid("id")] else { throw ControlError.notFound }
                return .success(tabJSON(tab, access, tree: true))
            case "tab.create": return .success(try await createTab(p, access))
            case "tab.update":
                let id = try p.uuid("id"), title = try p.string("title")
                let result = try await run(.renameTab(id: id, title: title), expecting: try p.revision().map { .tab(id, revision: $0) })
                return .success(tabJSON(try existing(result.snapshot.tabs[id]), access, tree: false))
            case "tab.reorder":
                let windowID = try p.uuid("windowId")
                let result = try await run(.reorderTabs(windowID: windowID, ids: try p.uuids("ids")), expecting: try p.revision().map { .window(windowID, revision: $0) })
                return .success(try windowJSON(result.snapshot, windowID))
            case "tab.focus":
                let id = try p.uuid("id")
                let result = try await run(.selectTab(id: id))
                return .success(tabJSON(try existing(result.snapshot.tabs[id]), access, tree: false))
            case "tab.close":
                let id = try p.uuid("id")
                return try await close(.deleteTab(id: id), p, expecting: try p.revision().map { .tab(id, revision: $0) })
            case "pane.split": return .success(try await split(p, access))
            case "pane.resize": return .success(try await resize(p, access))
            case "pane.focus":
                let id = try p.uuid("id")
                let result = try await run(.selectPane(id: id))
                let tab = try existing(result.snapshot.panes[id].flatMap { result.snapshot.tabs[$0.tabID] })
                return .success(.object(["paneId": .string(id.uuidString), "tabId": .string(tab.id.uuidString), "revision": revision(tab.revision)]))
            case "pane.maximize":
                let id = try p.uuid("id"), maximized = try p.bool("maximized")
                do { try await model.automationSetMaximized(id, maximized) } catch { throw Self.map(error) }
                return .success(.object(["paneId": .string(id.uuidString), "maximized": .bool(maximized)]))
            case "pane.close": return try await close(.deletePane(id: try p.uuid("id")), p, expecting: nil)
            case "session.get": return .success(try sessionJSON(try p.uuid("id"), access))
            case "host.list": return .success(.object(["hosts": .array(hostsVisible(access, query: try p.optionalString("query")).map(hostJSON))]))
            case "host.get":
                guard let host = hosts.hosts.first(where: { $0.id == (try? p.uuid("id")) }) else { throw ControlError.notFound }
                return .success(hostJSON(host))
            case "host.create": return .success(hostJSON(try hostResult(await hosts.save(try p.hostDraft(base: nil), editing: nil))))
            case "host.update":
                guard let current = hosts.hosts.first(where: { $0.id == (try? p.uuid("id")) }) else { throw ControlError.notFound }
                var editing = current
                if let expected = try p.revision() { editing.revision = expected }
                return .success(hostJSON(try hostResult(await hosts.save(try p.hostDraft(base: current.draft), editing: editing))))
            case "host.delete":
                guard var current = hosts.hosts.first(where: { $0.id == (try? p.uuid("id")) }) else { throw ControlError.notFound }
                if let expected = try p.revision() { current.revision = expected }
                if let error = await hosts.delete(current) { throw Self.map(error) }
                return .success(.object(["id": .string(current.id.uuidString), "deleted": .bool(true)]))
            default: return .failure(.methodNotFound)
            }
        } catch let error as ControlError {
            return .failure(error)
        } catch {
            return .failure(.internalError)
        }
    }

    // MARK: - Mutations

    @MainActor private func run(
        _ command: WorkspaceCommand, expecting: ResourceExpectation? = nil, then follow: (@Sendable (WorkspaceCommandResult) -> WorkspaceCommand?)? = nil
    ) async throws -> WorkspaceCommandResult {
        do { return try await model.automationExecute(command, expecting: expecting, then: follow) } catch { throw Self.map(error) }
    }

    @MainActor private func createWindow(_ p: Params) async throws -> JSONValue {
        let name = try p.string("name"), start = try p.optionalBool("start") == true
        let result = try await run(.createWindow(name: name))
        guard let windowID = result.createdWindowID, let window = result.snapshot.windows.first(where: { $0.id == windowID }),
            let tab = result.snapshot.tabs[window.activeTabID]
        else { throw ControlError.internalError }
        if start { await model.automationStart(tab.root.paneIDs) }
        // `revision` is the window's (for window.update); the collection revision is separate.
        return .object([
            "windowId": .string(windowID.uuidString), "tabId": .string(tab.id.uuidString), "panes": .array(tab.root.paneIDs.map { paneCreated($0) }),
            "revision": revision(window.revision), "tabRevision": revision(tab.revision), "workspaceRevision": revision(model.snapshot.revision)
        ])
    }

    @MainActor private func createTab(_ p: Params, _ access: GrantAccess) async throws -> JSONValue {
        let windowID = try p.uuid("windowId")
        let title = try p.optionalString("title").map { raw -> String in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Validate before creating so a bad title never leaves a half-applied tab.
            guard !trimmed.isEmpty, trimmed.count <= 200 else { throw ControlError.invalidParams("Use a title of 1–200 characters.", fields: ["title": "1–200 characters"]) }
            return trimmed
        }
        let start = try p.optionalBool("start") == true
        // Create and title in one store transaction: a failure leaves no tab.
        let result = try await run(.createTab(windowID: windowID), then: { created in title.flatMap { title in created.createdTabID.map { .renameTab(id: $0, title: title) } } })
        guard let tabID = result.createdTabID, let tab = result.snapshot.tabs[tabID] else { throw ControlError.internalError }
        if start { await model.automationStart(tab.root.paneIDs) }
        var body = tabJSON(try existing(model.snapshot.tabs[tabID]), access, tree: true)
        if case .object(var object) = body {
            object["panes"] = .array(tab.root.paneIDs.map { paneCreated($0) })
            body = .object(object)
        }
        return body
    }

    @MainActor private func split(_ p: Params, _ access: GrantAccess) async throws -> JSONValue {
        let paneID = try p.uuid("paneId")
        let axis: SplitAxis
        switch try p.string("axis") {
        case "x": axis = .x
        case "y": axis = .y
        default: throw ControlError.invalidParams("axis must be \"x\" (left/right) or \"y\" (top/bottom).", fields: ["axis": "x or y"])
        }
        let ratio = try p.optionalDouble("ratio")
        if let ratio, !(ratio.isFinite && (0.1...0.9).contains(ratio)) { throw ControlError.invalidParams("ratio must be within 0.1–0.9.", fields: ["ratio": "0.1–0.9"]) }
        let start = try p.optionalBool("start") == true
        guard let size = model.automationTerminalSize(paneID), let tabID = model.snapshot.panes[paneID]?.tabID else { throw ControlError.notFound }
        // Same rule as the UI: a new pane must not open hidden behind a maximized one.
        guard model.maximizedPanes[tabID] == nil else {
            throw ControlError.application("INVALID_STATE", "Restore the maximized pane (pane.maximize false) before splitting this tab.")
        }
        let canvas = model.automationCanvas(tabID)
        // Split and apply the ratio in one store transaction, so a ratio that
        // violates the size rules leaves no half-made split behind. The
        // existing pane is the first child, so ratio is its share.
        let result = try await run(
            .splitPane(id: paneID, axis: axis, availableSize: size),
            then: { split in
                guard let ratio, ratio != 0.5, let newID = split.createdPaneID, let tab = split.snapshot.panes[newID].flatMap({ split.snapshot.tabs[$0.tabID] }),
                    let branch = Self.parentBranch(of: newID, in: tab.root)
                else { return nil }
                return .resizeSplit(tabID: tab.id, splitID: branch, ratio: ratio, canvas: canvas)
            })
        guard let newID = result.createdPaneID, let pane = result.snapshot.panes[newID], let tab = result.snapshot.tabs[pane.tabID],
            let branch = Self.parentBranch(of: newID, in: tab.root)
        else { throw ControlError.internalError }
        if start { await model.automationStart([newID]) }
        return .object([
            "pane": paneCreated(newID), "branchId": .string(branch.uuidString), "tab": tabJSON(try existing(model.snapshot.tabs[tab.id]), access, tree: true)
        ])
    }

    @MainActor private func resize(_ p: Params, _ access: GrantAccess) async throws -> JSONValue {
        let branchID = try p.uuid("branchId")
        let ratio = try p.double("ratio")
        guard let tab = model.snapshot.tabs.values.first(where: { Self.branchIDs($0.root).contains(branchID) }) else { throw ControlError.notFound }
        let result = try await run(
            .resizeSplit(tabID: tab.id, splitID: branchID, ratio: ratio, canvas: model.automationCanvas(tab.id)),
            expecting: try p.revision().map { .tab(tab.id, revision: $0) })
        return tabJSON(try existing(result.snapshot.tabs[tab.id]), access, tree: true)
    }

    @MainActor private func close(_ command: WorkspaceCommand, _ p: Params, expecting: ResourceExpectation?) async throws -> Result<JSONValue, ControlError> {
        let allowRunning = try p.optionalBool("allowRunning") == true, force = try p.optionalBool("force") == true
        let outcome: AutomationCloseResult
        do {
            outcome = try await model.automationClose(command, allowRunning: allowRunning, force: force, expecting: expecting)
        } catch { throw Self.map(error) }
        switch outcome {
        case .closed: return .success(.object(["closed": .bool(true), "revision": revision(model.snapshot.revision)]))
        case .confirmationRequired(let ids):
            return .failure(
                .application(
                    "CONFIRMATION_REQUIRED", "Running sessions would be terminated. Repeat with allowRunning: true (requires session.close).",
                    details: .object(["sessionIds": .array(ids.map { .string($0.uuidString) })])))
        case .closePending(let ids):
            return .failure(
                .application(
                    "CLOSE_PENDING", "Sessions are still closing. Retry later, or request force: true after two seconds.", retryable: true,
                    details: .object(["sessionIds": .array(ids.map { .string($0.uuidString) })])))
        }
    }

    // MARK: - Projection

    @MainActor private func systemInfo(_ access: GrantAccess) -> JSONValue {
        .object([
            "apiVersion": .number(1), "instanceId": .string(instanceID.uuidString),
            "appVersion": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"),
            "capabilities": .array(access.grant.capabilities.sorted().map { .string($0.rawValue) }),
            "limits": .object(["maxFrameBytes": .number(Double(ControlFramer.maximumFrame)), "maxPanes": .number(100), "maxNesting": .number(16)])
        ])
    }

    @MainActor private func visibleWindows(_ access: GrantAccess) -> [(WorkspaceSnapshot, UUID)] {
        model.snapshot.windows.filter { access.canSee(window: $0.id) }.map { (model.snapshot, $0.id) }
    }

    private func windowJSON(_ pair: (WorkspaceSnapshot, UUID)) -> JSONValue { (try? windowJSON(pair.0, pair.1)) ?? .null }

    private func windowJSON(_ snapshot: WorkspaceSnapshot, _ id: UUID) throws -> JSONValue {
        guard let window = snapshot.windows.first(where: { $0.id == id }) else { throw ControlError.notFound }
        return .object([
            "id": .string(window.id.uuidString), "name": .string(window.name), "revision": revision(window.revision),
            "tabIds": .array(window.tabIDs.map { .string($0.uuidString) }), "activeTabId": .string(window.activeTabID.uuidString),
            "active": .bool(snapshot.activeWindowID == window.id)
        ])
    }

    @MainActor private func windowDetail(_ id: UUID) throws -> JSONValue { try windowJSON(model.snapshot, id) }

    @MainActor private func tabJSON(_ tab: WorkspaceTab, _ access: GrantAccess, tree: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(tab.id.uuidString), "windowId": .string(tab.windowID.uuidString), "title": .string(tab.title),
            "revision": revision(tab.revision), "activePaneId": .string(tab.activePaneID.uuidString),
            "paneIds": .array(tab.root.paneIDs.map { .string($0.uuidString) })
        ]
        if tree { object["layout"] = layoutJSON(tab.root) }
        if let maximized = model.maximizedPanes[tab.id] { object["maximizedPaneId"] = .string(maximized.uuidString) }
        return .object(object)
    }

    @MainActor private func layoutJSON(_ layout: PaneLayout) -> JSONValue {
        switch layout {
        case .pane(let id):
            let session = model.snapshot.panes[id].flatMap { model.snapshot.sessions[$0.sessionID] }
            return .object([
                "type": .string("pane"), "id": .string(id.uuidString), "sessionId": .string(session?.id.uuidString ?? ""),
                "state": .string(liveState(id) ?? session?.state.rawValue ?? "stopped")
            ])
        case .split(let id, let axis, let ratio, let children):
            return .object([
                "type": .string("split"), "id": .string(id.uuidString), "axis": .string(axis.rawValue), "ratio": .number(ratio),
                "children": .array(children.map(layoutJSON))
            ])
        }
    }

    @MainActor private func paneCreated(_ id: UUID) -> JSONValue {
        let session = model.snapshot.panes[id].flatMap { model.snapshot.sessions[$0.sessionID] }
        return .object([
            "paneId": .string(id.uuidString), "sessionId": .string(session?.id.uuidString ?? ""), "state": .string(liveState(id) ?? session?.state.rawValue ?? "stopped")
        ])
    }

    @MainActor private func liveState(_ paneID: UUID) -> String? { model.terminals[paneID]?.sessionState.rawValue }

    @MainActor private func sessionJSON(_ id: UUID, _ access: GrantAccess) throws -> JSONValue {
        guard let session = model.snapshot.sessions[id], let pane = model.snapshot.panes.values.first(where: { $0.sessionID == id }) else {
            throw ControlError.notFound
        }
        let terminal = model.terminals[pane.id]
        var object: [String: JSONValue] = [
            "id": .string(id.uuidString), "paneId": .string(pane.id.uuidString), "state": .string(terminal?.sessionState.rawValue ?? session.state.rawValue)
        ]
        if let code = terminal?.exitCode ?? session.exitCode { object["exitCode"] = .number(Double(code)) }
        if let started = session.startedAt { object["startedAt"] = .string(ISO8601DateFormatter().string(from: started)) }
        if let message = session.failureMessage { object["failureMessage"] = .string(message) }
        // Launch details only with execute (paths/arguments) or host-read (host identity).
        switch session.launch {
        case .shell(let directory):
            object["launchKind"] = .string("shell")
            if access.allows(.sessionExecute), let directory { object["directory"] = .string(directory) }
        case .host(let hostID):
            object["launchKind"] = .string("host")
            if access.allows(.hostRead), access.hostAccess(hosts.hosts.first { $0.id == hostID }) == .allowed { object["hostId"] = .string(hostID.uuidString) }
        case .process(let executable, let arguments, let directory):
            // Login shells are recorded as resolved processes; report them as shells.
            object["launchKind"] = .string(arguments == ["-l"] ? "shell" : "process")
            if access.allows(.sessionExecute) {
                object["executable"] = .string(executable)
                object["arguments"] = .array(arguments.map(JSONValue.string))
                if let directory { object["directory"] = .string(directory) }
            }
        }
        return .object(object)
    }

    @MainActor private func hostsVisible(_ access: GrantAccess, query: String?) -> [SavedHost] {
        SavedHost.search(hosts.hosts, query: query ?? "").filter { access.hostAccess($0) == .allowed }
    }

    private func hostJSON(_ host: SavedHost) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(host.id.uuidString), "name": .string(host.name), "destination": .string(host.destination),
            "tags": .array(host.tags.map(JSONValue.string)), "revision": revision(host.revision), "connectionRevision": revision(host.connectionRevision)
        ]
        if let user = host.user { object["user"] = .string(user) }
        if let port = host.port { object["port"] = .number(Double(port)) }
        if let identity = host.identityFile { object["identityFile"] = .string(identity) }
        return .object(object)
    }

    private func hostResult(_ result: Result<SavedHost, HostLibraryError>) throws -> SavedHost {
        switch result {
        case .success(let host): return host
        case .failure(let error): throw Self.map(error)
        }
    }

    private func revision(_ value: UInt64) -> JSONValue { .number(Double(value)) }

    private func existing<T>(_ value: T?) throws -> T {
        guard let value else { throw ControlError.notFound }
        return value
    }

    private static func parentBranch(of paneID: UUID, in layout: PaneLayout) -> UUID? {
        guard case .split(let id, _, _, let children) = layout else { return nil }
        if children.contains(.pane(paneID)) { return id }
        return children.lazy.compactMap { parentBranch(of: paneID, in: $0) }.first
    }

    private static func branchIDs(_ layout: PaneLayout) -> [UUID] {
        guard case .split(let id, _, _, let children) = layout else { return [] }
        return [id] + children.flatMap(branchIDs)
    }

    // MARK: - Errors

    static func map(_ error: AutomationModelError) -> ControlError {
        switch error {
        case .unavailable: .application("INVALID_STATE", "The workspace is busy, restoring, or shutting down. Retry shortly.", retryable: true)
        case .store(.notFound): .notFound
        case .store(.conflict(let expected, let actual)):
            .application(
                "CONFLICT", "The resource changed. Read it again and retry with its current revision.",
                details: .object(["expectedRevision": .number(Double(expected)), "currentRevision": .number(Double(actual))]))
        case .store(.invalidState(let reason)): .application("INVALID_STATE", Self.safeReason(reason))
        case .store(.invalidTransition): .application("INVALID_STATE", "That change is not allowed in the resource's current state.")
        case .store(.staleLaunch), .store(.revisionExhausted): .application("INVALID_STATE", "The workspace state changed. Retry the request.", retryable: true)
        }
    }

    static func map(_ error: HostLibraryError) -> ControlError {
        switch error {
        case .invalid(let validation):
            .invalidParams("Check the host fields.", fields: Dictionary(uniqueKeysWithValues: validation.fields.map { ($0.key.rawValue, $0.value) }))
        case .notFound: .notFound
        case .conflict(let expected, let actual):
            .application(
                "CONFLICT", "The host changed. Read it again and retry with its current revision.",
                details: .object(["expectedRevision": .number(Double(expected)), "currentRevision": .number(Double(actual))]))
        case .readOnly: .application("INVALID_STATE", "Saved hosts could not be read, so changes are not saved.")
        case .io: .application("INVALID_STATE", "Saved hosts could not be written.", retryable: true)
        }
    }

    /// Domain reasons are fixed strings from the store; never client input.
    private static func safeReason(_ reason: String) -> String { reason.count <= 200 ? reason : "The request violates a layout rule." }
}

/// Typed access to request params with sanitized invalid-param errors.
struct Params {
    let object: [String: JSONValue]
    init(_ value: JSONValue?) {
        if case .object(let object)? = value { self.object = object } else { object = [:] }
    }

    private func invalid(_ key: String, _ expectation: String) -> ControlError { .invalidParams("Invalid \(key).", fields: [key: expectation]) }

    func string(_ key: String) throws -> String {
        guard case .string(let value)? = object[key] else { throw invalid(key, "string") }
        return value
    }
    func optionalString(_ key: String) throws -> String? {
        switch object[key] {
        case nil, .null?: return nil
        case .string(let value)?: return value
        default: throw invalid(key, "string")
        }
    }
    func uuid(_ key: String) throws -> UUID {
        guard let id = UUID(uuidString: try string(key)) else { throw invalid(key, "UUID") }
        return id
    }
    func uuids(_ key: String) throws -> [UUID] {
        guard case .array(let values)? = object[key], values.count <= 1000 else { throw invalid(key, "array of UUIDs") }
        return try values.map { value in
            guard case .string(let raw) = value, let id = UUID(uuidString: raw) else { throw invalid(key, "array of UUIDs") }
            return id
        }
    }
    func bool(_ key: String) throws -> Bool {
        guard case .bool(let value)? = object[key] else { throw invalid(key, "boolean") }
        return value
    }
    func optionalBool(_ key: String) throws -> Bool? {
        switch object[key] {
        case nil, .null?: return nil
        case .bool(let value)?: return value
        default: throw invalid(key, "boolean")
        }
    }
    func double(_ key: String) throws -> Double {
        guard case .number(let value)? = object[key], value.isFinite else { throw invalid(key, "number") }
        return value
    }
    func optionalDouble(_ key: String) throws -> Double? {
        switch object[key] {
        case nil, .null?: return nil
        default: return try double(key)
        }
    }
    /// `expectedRevision`, when supplied, must be a non-negative integer; any
    /// other value is rejected rather than silently ignored.
    func revision() throws -> UInt64? {
        switch object["expectedRevision"] {
        case nil, .null?: return nil
        case .number(let value)? where value >= 0 && value.rounded() == value && value < 9e15: return UInt64(value)
        default: throw invalid("expectedRevision", "non-negative integer")
        }
    }

    /// Host fields; omitted fields keep `base` values on update.
    func hostDraft(base: HostDraft?) throws -> HostDraft {
        var draft = base ?? HostDraft()
        if let name = try optionalString("name") { draft.name = name }
        if let destination = try optionalString("destination") { draft.destination = destination }
        if object.keys.contains("user") { draft.user = try optionalString("user") ?? "" }
        if object.keys.contains("port") {
            switch object["port"] {
            case .number(let value)? where value.rounded() == value && abs(value) < 1e9: draft.port = String(Int(value))
            case .null?: draft.port = ""
            default: throw invalid("port", "integer 1–65535")
            }
        }
        if object.keys.contains("identityFile") { draft.identityFile = try optionalString("identityFile") ?? "" }
        if object.keys.contains("tags") {
            guard case .array(let values)? = object["tags"] else { throw invalid("tags", "array of strings") }
            draft.tags = try values.map { value in
                guard case .string(let tag) = value, !tag.contains(",") else { throw invalid("tags", "array of strings without commas") }
                return tag
            }.joined(separator: ",")
        }
        return draft
    }
}

extension AppWorkspaceModel {
    func snapshotForAutomation() -> WorkspaceSnapshot { snapshot }
}
