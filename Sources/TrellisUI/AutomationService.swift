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
            case "session.start": return try await startSession(p, access)
            case "session.restart": return try await restartSession(p, access)
            case "session.sendInput": return .success(try sendInput(p))
            case "session.readOutput": return .success(try readOutput(p))
            case "layout.validate": return .success(try layoutValidate(p, access))
            case "layout.plan": return .success(try layoutPlan(p, access))
            case "layout.apply": return try await layoutApply(p, access)
            case "layout.export": return .success(try layoutExport(p, access))
            case "theme.list": return .success(themeList())
            case "theme.get": return .success(try themeGet(p))
            case "theme.validate": return .success(try themeValidate(p))
            case "theme.import": return .success(try await themeImport(p))
            case "theme.export": return .success(try await themeExport(p))
            case "theme.delete":
                let id = try p.string("id")
                do { try await model.automationDeleteTheme(id) } catch { throw Self.map(error) }
                return .success(.object(["id": .string(id), "deleted": .bool(true), "appearance": appearanceJSON()]))
            case "appearance.get": return .success(appearanceJSON())
            case "appearance.set": return .success(try appearanceSet(p))
            case "session.execute": return .success(try execute(p))
            case "host.connect": return try await connect(p, access)
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

    // MARK: - Sessions

    /// Exact decoded bytes accepted per input or execute call.
    static let inputLimit = 65_536

    @MainActor private func startSession(_ p: Params, _ access: GrantAccess) async throws -> Result<JSONValue, ControlError> {
        let paneID = try p.uuid("paneId")
        let (launch, environment) = try launchDescriptor(p, access)
        if launch == nil { try requireHostAccess(forStoredLaunchOf: paneID, access) }
        do { try await model.automationStartSession(paneID, launch: launch, environment: environment) } catch { throw Self.map(error) }
        return launchResult(paneID, access)
    }

    @MainActor private func restartSession(_ p: Params, _ access: GrantAccess) async throws -> Result<JSONValue, ControlError> {
        let paneID = try p.uuid("paneId")
        let (launch, environment) = try launchDescriptor(p, access)
        if launch == nil { try requireHostAccess(forStoredLaunchOf: paneID, access) }
        let allowRunning = try p.optionalBool("allowRunning") == true, force = try p.optionalBool("force") == true
        let outcome: AutomationCloseResult
        do { outcome = try await model.automationRestart(paneID, allowRunning: allowRunning, force: force) } catch { throw Self.map(error) }
        switch outcome {
        case .closed: break
        case .confirmationRequired(let ids):
            return .failure(
                .application(
                    "CONFIRMATION_REQUIRED", "The session is running. Repeat with allowRunning: true (requires session.close).",
                    details: .object(["sessionIds": .array(ids.map { .string($0.uuidString) })])))
        case .closePending(let ids):
            return .failure(
                .application(
                    "CLOSE_PENDING", "The session is still closing. Retry later, or request force: true after two seconds.", retryable: true,
                    details: .object(["sessionIds": .array(ids.map { .string($0.uuidString) })])))
        }
        do { try await model.automationStartSession(paneID, launch: launch, environment: environment) } catch { throw Self.map(error) }
        return launchResult(paneID, access)
    }

    /// A failed launch is an error that still carries the failed session record.
    @MainActor private func launchResult(_ paneID: UUID, _ access: GrantAccess) -> Result<JSONValue, ControlError> {
        guard let sessionID = model.snapshot.panes[paneID]?.sessionID, let record = try? sessionJSON(sessionID, access) else { return .failure(.notFound) }
        if model.terminals[paneID]?.sessionState == .failed || model.snapshot.sessions[sessionID]?.state == .failed {
            return .failure(.application("LAUNCH_FAILED", "The session could not be started. Check the executable, directory, and environment.", details: .object(["session": record])))
        }
        return .success(.object(["session": record]))
    }

    /// Parses an optional launch descriptor. Policy already required
    /// session.execute for anything other than `{kind: "host", hostId}`.
    @MainActor private func launchDescriptor(_ p: Params, _ access: GrantAccess) throws -> (SessionLaunch?, [String: String]) {
        guard let raw = p.object["launch"], raw != .null else { return (nil, [:]) }
        guard case .object(let object) = raw else { throw ControlError.invalidParams("launch must be an object.", fields: ["launch": "object"]) }
        let launch = Params(raw)
        func absolute(_ key: String) throws -> String {
            let path = try launch.string(key)
            guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else {
                throw ControlError.invalidParams("\(key) must be an absolute path.", fields: [key: "absolute path"])
            }
            return path
        }
        var environment: [String: String] = [:]
        if let env = object["environment"], env != .null {
            guard case .object(let values) = env, values.count <= 256 else {
                throw ControlError.invalidParams("environment must be an object of strings.", fields: ["environment": "object"])
            }
            for (key, value) in values {
                guard case .string(let text) = value, !key.isEmpty, !key.contains("="), !key.contains("\0"), !text.contains("\0"),
                    key.utf8.count <= 256, text.utf8.count <= 32_768, !["TRELLIS_", "__TRELLIS_", "UTERM_", "__UTERM_"].contains(where: key.uppercased().hasPrefix)
                else { throw ControlError.invalidParams("Invalid environment entry.", fields: ["environment": "string keys and values; TRELLIS_ names are reserved"]) }
                environment[key] = text
            }
        }
        switch try launch.string("kind") {
        case "host":
            let hostID = try launch.uuid("hostId")
            switch access.hostAccess(hosts.hosts.first { $0.id == hostID }) {
            case .allowed: return (.host(hostID), [:])
            case .hidden: throw ControlError.notFound
            case .needsReapproval: throw ControlError.application("PERMISSION_DENIED", "This host's connection changed after it was approved. Reapprove it in Settings → Automation.")
            }
        case "shell":
            let directory = object["directory"] == nil || object["directory"] == .null ? nil : try absolute("directory")
            return (.shell(directory: directory), environment)
        case "process":
            guard case .array(let values)? = object["arguments"] ?? .array([]), values.count <= 256 else {
                throw ControlError.invalidParams("arguments must be an array of strings.", fields: ["arguments": "array of strings"])
            }
            let arguments = try values.map { value -> String in
                guard case .string(let argument) = value, !argument.contains("\0"), argument.utf8.count <= 65_536 else {
                    throw ControlError.invalidParams("arguments must be an array of strings.", fields: ["arguments": "array of strings"])
                }
                return argument
            }
            return (.process(executable: try absolute("executable"), arguments: arguments, directory: try absolute("directory")), environment)
        default: throw ControlError.invalidParams("launch.kind must be shell, process, or host.", fields: ["launch.kind": "shell, process, or host"])
        }
    }

    /// Starting a pane that already references a saved host still needs access to it.
    @MainActor private func requireHostAccess(forStoredLaunchOf paneID: UUID, _ access: GrantAccess) throws {
        guard let session = model.snapshot.panes[paneID].flatMap({ model.snapshot.sessions[$0.sessionID] }), case .host(let hostID) = session.launch else { return }
        switch access.hostAccess(hosts.hosts.first { $0.id == hostID }) {
        case .allowed: return
        case .hidden: throw ControlError.application("PERMISSION_DENIED", "This pane connects to a saved host this grant cannot use.")
        case .needsReapproval: throw ControlError.application("PERMISSION_DENIED", "This host's connection changed after it was approved. Reapprove it in Settings → Automation.")
        }
    }

    @MainActor private func sendInput(_ p: Params) throws -> JSONValue {
        let sessionID = try p.uuid("id")
        let text = try p.optionalString("text"), encoded = try p.optionalString("base64")
        guard (text == nil) != (encoded == nil) else {
            throw ControlError.invalidParams("Send exactly one of text or base64.", fields: ["text": "exactly one of text/base64", "base64": "exactly one of text/base64"])
        }
        // Reject oversized input before decoding it.
        if let encoded, encoded.utf8.count > (Self.inputLimit + 2) / 3 * 4 + 4 { throw Self.inputTooLarge }
        guard let data = text.map({ Data($0.utf8) }) ?? encoded.flatMap({ Data(base64Encoded: $0) }) else {
            throw ControlError.invalidParams("base64 is not valid.", fields: ["base64": "standard base64"])
        }
        guard !data.isEmpty else { throw ControlError.invalidParams("Input is empty.", fields: ["text": "non-empty"]) }
        guard data.count <= Self.inputLimit else { throw Self.inputTooLarge }
        let paste: Bool
        switch try p.optionalString("mode") ?? "literal" {
        case "literal": paste = false
        case "paste":
            // Paste must be text and cannot terminate bracketed paste early.
            guard String(data: data, encoding: .utf8) != nil, data.range(of: Data("\u{1b}[201~".utf8)) == nil else {
                throw ControlError.invalidParams("Paste input must be UTF-8 text without the bracketed-paste end marker.", fields: ["mode": "paste requires UTF-8 text"])
            }
            paste = true
        default: throw ControlError.invalidParams("mode must be literal or paste.", fields: ["mode": "literal or paste"])
        }
        try send(sessionID, data, paste: paste)
        return .object(["acceptedBytes": .number(Double(data.count)), "mode": .string(paste ? "paste" : "literal")])
    }

    @MainActor private func execute(_ p: Params) throws -> JSONValue {
        let sessionID = try p.uuid("id")
        guard try p.optionalBool("submit") == true else {
            throw ControlError.invalidParams("session.execute requires submit: true; it sends the command plus Return.", fields: ["submit": "true"])
        }
        let command = try p.string("command")
        guard !command.isEmpty, !command.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else {
            throw ControlError.invalidParams("command must be one non-empty line.", fields: ["command": "one line without CR/LF"])
        }
        let data = Data((command + "\r").utf8)
        guard data.count <= Self.inputLimit else { throw Self.inputTooLarge }
        try send(sessionID, data, paste: false)
        // Acceptance means the bytes were queued, not that the command finished.
        return .object(["acceptedBytes": .number(Double(data.count)), "submitted": .bool(true)])
    }

    @MainActor private func send(_ sessionID: UUID, _ data: Data, paste: Bool) throws {
        do {
            try model.automationSendInput(sessionID: sessionID, data: data, paste: paste)
        } catch .notFound {
            throw ControlError.notFound
        } catch .notRunning {
            throw ControlError.application("INVALID_STATE", "The session is not running.")
        } catch .queueFull {
            throw ControlError.application("LIMIT_EXCEEDED", "The terminal input queue is full. Wait and inspect the session before sending more.", retryable: true)
        } catch {
            throw ControlError.application("INVALID_STATE", "Input could not be sent to the session.")
        }
    }

    private static let inputTooLarge = ControlError.application("LIMIT_EXCEEDED", "Input is limited to 64 KiB per call.")

    @MainActor private func connect(_ p: Params, _ access: GrantAccess) async throws -> Result<JSONValue, ControlError> {
        let hostID = try p.uuid("hostId"), windowID = try p.uuid("windowId")
        guard let host = hosts.hosts.first(where: { $0.id == hostID }) else { throw ControlError.notFound }
        let paneID: UUID
        if let target = try p.optionalString("paneId") {
            // A split target must be in the authorized window, never elsewhere.
            guard let targetID = UUID(uuidString: target), let pane = model.snapshot.panes[targetID], model.snapshot.tabs[pane.tabID]?.windowID == windowID else {
                throw ControlError.notFound
            }
            let axis: SplitAxis
            switch try p.optionalString("axis") ?? "x" {
            case "x": axis = .x
            case "y": axis = .y
            default: throw ControlError.invalidParams("axis must be \"x\" or \"y\".", fields: ["axis": "x or y"])
            }
            guard model.maximizedPanes[pane.tabID] == nil else {
                throw ControlError.application("INVALID_STATE", "Restore the maximized pane before connecting in a split.")
            }
            guard let size = model.automationTerminalSize(targetID) else { throw ControlError.notFound }
            guard let created = try await run(.splitPane(id: targetID, axis: axis, availableSize: size)).createdPaneID else { throw ControlError.internalError }
            paneID = created
        } else {
            let title = host.name
            let result = try await run(.createTab(windowID: windowID), then: { result in result.createdTabID.map { .renameTab(id: $0, title: title) } })
            guard let tabID = result.createdTabID, let tab = model.snapshot.tabs[tabID] else { throw ControlError.internalError }
            paneID = tab.activePaneID
        }
        do { try await model.automationStartSession(paneID, launch: .host(hostID), environment: [:]) } catch { throw Self.map(error) }
        return launchResult(paneID, access)
    }

    // MARK: - Output

    static let defaultReadBytes = 65_536, maximumReadBytes = 262_144

    /// Screen/scrollback are plain-text display snapshots; stream returns exact
    /// raw PTY bytes from the bounded journal with an opaque cursor.
    @MainActor private func readOutput(_ p: Params) throws -> JSONValue {
        let sessionID = try p.uuid("id")
        guard let terminal = model.terminals.values.first(where: { $0.sessionID == sessionID }) else { throw ControlError.notFound }
        let maxBytes: Int
        if let requested = try p.optionalDouble("maxBytes") {
            guard requested.rounded() == requested, (1...Double(Self.maximumReadBytes)).contains(requested) else {
                throw ControlError.invalidParams("maxBytes must be 1–262144.", fields: ["maxBytes": "1–262144"])
            }
            maxBytes = Int(requested)
        } else {
            maxBytes = Self.defaultReadBytes
        }
        let captured = ISO8601DateFormatter().string(from: Date())
        switch try p.string("view") {
        case "screen", "scrollback":
            let view = try p.string("view")
            let text = view == "screen" ? terminal.screenText : ((try? terminal.adapter.read(.retainedText)) ?? "")
            // Keep the newest text within the byte limit, cut on a character boundary.
            var kept = Substring(text)
            while kept.utf8.count > maxBytes { kept = kept.dropFirst(max(1, (kept.utf8.count - maxBytes) / 4)) }
            return .object([
                "view": .string(view), "text": .string(String(kept)), "capturedAt": .string(captured), "truncated": .bool(kept.startIndex != text.startIndex),
                "historyNotice": .string(terminal.historyNotice)
            ])
        case "stream":
            var offset: UInt64?
            if let token = try p.optionalString("cursor") {
                guard let cursor = OutputCursor(token: token), cursor.instanceID == instanceID, cursor.sessionID == sessionID else {
                    throw Self.invalidCursor
                }
                offset = cursor.offset
            }
            let journal = model.outputJournal
            guard journal.contains(session: sessionID) else {
                // No output yet: an empty read whose cursor starts at offset 0.
                guard offset == nil || offset == 0 else { throw Self.invalidCursor }
                return .object([
                    "view": .string("stream"), "base64": .string(""), "nextCursor": .string(OutputCursor(instanceID: instanceID, sessionID: sessionID, offset: 0).token),
                    "truncated": .bool(false), "gap": .bool(false), "capturedAt": .string(captured)
                ])
            }
            let read: OutputJournal.Read
            do { read = try journal.read(session: sessionID, from: offset, maxBytes: maxBytes) } catch { throw Self.invalidCursor }
            return .object([
                "view": .string("stream"), "base64": .string(read.data.base64EncodedString()),
                "nextCursor": .string(OutputCursor(instanceID: instanceID, sessionID: sessionID, offset: read.next).token),
                "truncated": .bool(read.truncated), "gap": .bool(read.gap), "capturedAt": .string(captured)
            ])
        default: throw ControlError.invalidParams("view must be screen, scrollback, or stream.", fields: ["view": "screen, scrollback, or stream"])
        }
    }

    private static let invalidCursor = ControlError.application(
        "INVALID_CURSOR", "This cursor belongs to another session, a restarted session, or another app instance. Read again without a cursor.")

    // MARK: - Declarative layouts

    @MainActor private func parsedLayout(_ p: Params) throws -> LayoutDocument {
        switch LayoutJSON.parse(p.object["document"]) {
        case .success(let document): return document
        case .failure(let error):
            throw ControlError.invalidParams("The layout document is invalid.", fields: [:]).withIssues(error.issues)
        }
    }

    @MainActor private func namespace(_ p: Params) throws -> String {
        let namespace = try p.string("namespace")
        guard LayoutPlanner.isValidKey(namespace) else { throw ControlError.invalidParams("namespace must match the layout key pattern.", fields: ["namespace": "layout key"]) }
        return namespace
    }

    /// Hosts outside the grant look exactly like missing ones, and bindings to
    /// windows outside it are ignored so a plan never reveals hidden resources.
    @MainActor private func plan(_ document: LayoutDocument, namespace: String?, _ access: GrantAccess) throws -> LayoutPlan {
        var bindings: [String: LayoutBinding] = [:]
        if let namespace {
            do { bindings = try model.layoutBindings(namespace) } catch { throw Self.map(error) }
            let kinds: [LayoutResourceKind: ResourceKind] = [.window: .window, .tab: .tab, .split: .branch, .pane: .pane]
            bindings = bindings.filter { _, binding in kinds[binding.kind].flatMap { access.owningWindow($0, binding.id) }.map(access.canSee) == true }
        }
        return LayoutPlanner.plan(
            document, bindings: bindings, snapshot: model.snapshot,
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            hostExists: { id in access.hostAccess(self.hosts.hosts.first { $0.id == id }) == .allowed },
            directoryExists: { path in
                var isDirectory: ObjCBool = false; return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            })
    }

    @MainActor private func layoutValidate(_ p: Params, _ access: GrantAccess) throws -> JSONValue {
        let document: LayoutDocument
        do { document = try parsedLayout(p) } catch let error as ControlError {
            return .object(["valid": .bool(false), "errors": error.details?["issues"] ?? .array([]), "warnings": .array([])])
        }
        let result = try plan(document, namespace: nil, access)
        return .object(["valid": .bool(result.errors.isEmpty), "errors": LayoutJSON.issuesJSON(result.errors), "warnings": LayoutJSON.issuesJSON(result.warnings)])
    }

    @MainActor private func layoutPlan(_ p: Params, _ access: GrantAccess) throws -> JSONValue {
        let result = try plan(try parsedLayout(p), namespace: try namespace(p), access)
        return planJSON(result, access)
    }

    @MainActor private func planJSON(_ result: LayoutPlan, _ access: GrantAccess) -> JSONValue {
        let unmanaged = result.unmanaged.filter { id in
            access.owningWindow(.window, id).map(access.canSee) ?? access.owningWindow(.tab, id).map(access.canSee) ?? false
        }
        return .object([
            "baseRevision": revision(result.baseRevision), "applicable": .bool(result.canApply), "errors": LayoutJSON.issuesJSON(result.errors),
            "warnings": LayoutJSON.issuesJSON(result.warnings), "conflicts": LayoutJSON.issuesJSON(result.conflicts),
            "creates": .array(result.creates.map { .object(["kind": .string($0.kind.rawValue), "key": .string($0.key)]) }),
            "updates": .array(result.updates.map { .object(["kind": .string($0.kind.rawValue), "key": .string($0.key)]) }),
            "unmanaged": .array(unmanaged.map { .string($0.uuidString) })
        ])
    }

    @MainActor private func layoutApply(_ p: Params, _ access: GrantAccess) async throws -> Result<JSONValue, ControlError> {
        let document = try parsedLayout(p), namespace = try namespace(p)
        guard let expected = try p.revision() else {
            throw ControlError.invalidParams("layout.apply requires expectedRevision from layout.plan.", fields: ["expectedRevision": "plan baseRevision"])
        }
        let startNew = try p.optionalBool("startNew") == true
        let result = try plan(document, namespace: namespace, access)
        guard result.errors.isEmpty else { throw ControlError.invalidParams("The layout document is invalid.").withIssues(result.errors) }
        guard result.baseRevision == expected else {
            return .failure(
                .application(
                    "CONFLICT", "The workspace changed since the plan. Plan again and apply with the new baseRevision.",
                    details: .object(["expectedRevision": revision(expected), "currentRevision": revision(result.baseRevision)])))
        }
        guard result.canApply else {
            return .failure(.application("CONFLICT", "The layout conflicts with the current workspace.", details: .object(["conflicts": LayoutJSON.issuesJSON(result.conflicts)])))
        }
        let committed: WorkspaceCommandResult
        do { committed = try await model.automationApplyLayout(result, namespace: namespace) } catch { throw Self.map(error) }
        // Launches are independent of the committed layout: failures are reported, never rolled back.
        var launches: [JSONValue] = []
        if startNew {
            for (key, paneID) in result.createdPanes {
                var failure: ControlError?
                do { try await model.automationStartSession(paneID, launch: nil, environment: [:]) } catch { failure = Self.map(error) }
                let session = model.snapshot.panes[paneID].flatMap { model.snapshot.sessions[$0.sessionID] }
                var outcome: [String: JSONValue] = [
                    "key": .string(key), "paneId": .string(paneID.uuidString), "sessionId": .string(session?.id.uuidString ?? ""),
                    "state": .string(model.terminals[paneID]?.sessionState.rawValue ?? session?.state.rawValue ?? "stopped")
                ]
                if let message = session?.failureMessage { outcome["failureMessage"] = .string(message) }
                if let failure { outcome["error"] = .object(["code": .string(failure.appCode ?? "INTERNAL_ERROR"), "message": .string(failure.message)]) }
                launches.append(.object(outcome))
            }
        }
        return .success(
            .object([
                "revision": revision(model.snapshot.revision), "changed": .bool(committed.snapshot.revision != result.baseRevision),
                "mapping": .object(result.bindings.mapValues { .object(["kind": .string($0.kind.rawValue), "id": .string($0.id.uuidString)]) }),
                "creates": .array(result.creates.map { .object(["kind": .string($0.kind.rawValue), "key": .string($0.key)]) }),
                "launches": .array(launches)
            ]))
    }

    /// Exports visible windows with fresh keys. Launch details need execute and
    /// host references need host-read; otherwise the document is marked redacted.
    @MainActor private func layoutExport(_ p: Params, _ access: GrantAccess) throws -> JSONValue {
        let requested = try p.object["windowIds"] == nil ? nil : Set(p.uuids("windowIds"))
        let snapshot = model.snapshot
        var counter = 0, redacted = false
        func key(_ prefix: String) -> JSONValue {
            counter += 1
            return .string("\(prefix)\(counter)")
        }
        func launch(_ paneID: UUID) -> JSONValue {
            switch snapshot.panes[paneID].flatMap({ snapshot.sessions[$0.sessionID] })?.launch {
            case .host(let hostID)? where access.allows(.hostRead) && access.hostAccess(hosts.hosts.first { $0.id == hostID }) == .allowed:
                return .object(["kind": .string("host"), "hostId": .string(hostID.uuidString)])
            case .shell(let directory)? where access.allows(.sessionExecute):
                return .object(directory.map { ["kind": .string("shell"), "directory": .string($0)] } ?? ["kind": .string("shell")])
            case .process(_, let arguments, let directory)? where access.allows(.sessionExecute) && arguments == ["-l"]:
                return .object(directory.map { ["kind": .string("shell"), "directory": .string($0)] } ?? ["kind": .string("shell")])
            default:
                redacted = true
                return .object(["kind": .string("shell")])
            }
        }
        func node(_ layout: PaneLayout) -> JSONValue {
            switch layout {
            case .pane(let id):
                var object: [String: JSONValue] = ["type": .string("pane"), "key": key("p"), "launch": launch(id)]
                if let title = snapshot.panes[id]?.title { object["title"] = .string(title) }
                return .object(object)
            case .split(_, let axis, let ratio, let children):
                return .object(["type": .string("split"), "key": key("s"), "axis": .string(axis.rawValue), "ratio": .number(ratio), "children": .array(children.map(node))])
            }
        }
        let windows = snapshot.windows.filter { access.canSee(window: $0.id) && (requested?.contains($0.id) ?? true) }
        if let requested, requested.count != windows.count { throw ControlError.notFound }
        let document: JSONValue = .object([
            "version": .number(1),
            "windows": .array(
                windows.map { window in
                    .object([
                        "key": key("w"), "name": .string(window.name),
                        "tabs": .array(window.tabIDs.compactMap { snapshot.tabs[$0] }.map { tab in .object(["key": key("t"), "title": .string(tab.title), "root": node(tab.root)]) })
                    ])
                })
        ])
        return .object(["document": document, "redacted": .bool(redacted), "importable": .bool(!redacted)])
    }

    // MARK: - Themes

    @MainActor private func themeSummary(_ theme: ResolvedTheme) -> JSONValue {
        var slots: [JSONValue] = []
        if model.appearance.lightThemeID == theme.id { slots.append(.string("light")) }
        if model.appearance.darkThemeID == theme.id { slots.append(.string("dark")) }
        return .object([
            "id": .string(theme.id), "name": .string(theme.name), "appearance": .string(theme.appearance.rawValue),
            "builtIn": .bool(theme.id.hasPrefix("trellis-")), "selectedFor": .array(slots)
        ])
    }

    @MainActor private func themeList() -> JSONValue {
        .object(["themes": .array(model.allThemes.map(themeSummary)), "appearanceRevision": revision(model.appearanceRevision)])
    }

    @MainActor private func themeGet(_ p: Params) throws -> JSONValue {
        let id = try p.string("id")
        guard let theme = model.allThemes.first(where: { $0.id == id }), let data = try? theme.encoded(),
            let palette = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { throw ControlError.notFound }
        var summary: [String: JSONValue] = [:]
        if case .object(let object) = themeSummary(theme) { summary = object }
        summary["resolved"] = palette
        summary["contrastWarnings"] = .array(theme.contrastWarnings.map { .string($0.message) })
        return .object(summary)
    }

    /// Theme documents are re-serialized and checked by the same validator the UI uses.
    @MainActor private func themeData(_ p: Params) throws -> Data {
        // Raw text keeps the validator's duplicate-key and number checks intact.
        if case .string(let text)? = p.object["documentText"] {
            guard p.object["document"] == nil else { throw ControlError.invalidParams("Send document or documentText, not both.", fields: ["documentText": "exclusive"]) }
            return Data(text.utf8)
        }
        guard let document = p.object["document"], case .object = document, let data = try? JSONEncoder().encode(document) else {
            throw ControlError.invalidParams("document must be a theme JSON object.", fields: ["document": "theme object"])
        }
        return data
    }

    @MainActor private func themeValidate(_ p: Params) throws -> JSONValue {
        do {
            let document = try ThemeValidator.validate(try themeData(p))
            return .object([
                "valid": .bool(true), "id": .string(document.id), "appearance": .string(document.appearance.rawValue),
                "errors": .array([]), "warnings": .array(document.resolved().contrastWarnings.map { .string($0.message) })
            ])
        } catch let error as ThemeValidationError {
            return .object(["valid": .bool(false), "errors": .array([.object(["path": .string(error.path), "message": .string(error.reason)])]), "warnings": .array([])])
        }
    }

    @MainActor private func themeImport(_ p: Params) async throws -> JSONValue {
        let replace = try p.optionalBool("replace") == true
        let document: ThemeDocument
        do { document = try await model.automationInstallTheme(try themeData(p), replace: replace) } catch let error as AutomationThemeError { throw Self.map(error) }
        guard let theme = model.allThemes.first(where: { $0.id == document.id }) else { throw ControlError.internalError }
        return themeSummary(theme)
    }

    @MainActor private func themeExport(_ p: Params) async throws -> JSONValue {
        let id = try p.string("id"), resolved = try p.optionalBool("resolved") == true
        let data: Data
        if let builtIn = ThemeAppearance.allCases.map(ResolvedTheme.builtIn).first(where: { $0.id == id }) {
            guard let encoded = try? builtIn.encoded() else { throw ControlError.internalError }
            data = encoded
        } else {
            do { data = try await model.exportTheme(id, resolved: resolved) } catch { throw ControlError.notFound }
        }
        guard let document = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw ControlError.internalError }
        return .object(["id": .string(id), "resolved": .bool(resolved), "document": document])
    }

    @MainActor private func appearanceJSON() -> JSONValue {
        let settings = model.appearance
        return .object([
            "mode": .string(settings.chromeMode.rawValue), "lightThemeId": .string(settings.lightThemeID), "darkThemeId": .string(settings.darkThemeID),
            "effectiveThemeId": .string(model.effectiveTheme.id), "revision": revision(model.appearanceRevision)
        ])
    }

    @MainActor private func appearanceSet(_ p: Params) throws -> JSONValue {
        var mode: ChromeMode?
        if let raw = try p.optionalString("mode") {
            guard let parsed = ChromeMode(rawValue: raw) else { throw ControlError.invalidParams("mode must be system, dark, or light.", fields: ["mode": "system, dark, or light"]) }
            mode = parsed
        }
        do {
            try model.automationSetAppearance(
                mode: mode, lightThemeID: try p.optionalString("lightThemeId"), darkThemeID: try p.optionalString("darkThemeId"), expectedRevision: try p.revision())
        } catch let error as AutomationThemeError { throw Self.map(error) }
        return appearanceJSON()
    }

    static func map(_ error: AutomationThemeError) -> ControlError {
        switch error {
        case .invalid(let validation): .invalidParams("The theme is invalid: \(validation.reason)", fields: [validation.path: validation.reason])
        case .library(.reservedID): .application("INVALID_STATE", "Built-in trellis- themes cannot be replaced or deleted.")
        case .library(.duplicateID): .application("CONFLICT", "A theme with this ID exists. Repeat with replace: true to replace it.")
        case .library(.notFound): .notFound
        case .library: .application("INVALID_STATE", "The theme library could not be updated.", retryable: true)
        case .unavailable: .application("INVALID_STATE", "Themes are busy or the app is restoring. Retry shortly.", retryable: true)
        case .mismatchedSlot(let message): .invalidParams(message, fields: ["themeId": "matching light/dark slot"])
        case .notFound: .notFound
        case .conflict(let expected, let actual):
            .application(
                "CONFLICT", "Appearance changed. Read it again and retry with its current revision.",
                details: .object(["expectedRevision": .number(Double(expected)), "currentRevision": .number(Double(actual))]))
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
        // Present only after an authenticated mark; never includes command text (FR-SI04).
        if terminal?.sessionID == id, let state = model.shellStates[pane.id] {
            var shell: [String: JSONValue] = ["commandRunning": .bool(state.commandRunning)]
            if let code = state.lastExitCode { shell["lastExitStatus"] = .number(Double(code)) }
            if access.allows(.sessionExecute), let directory = state.currentDirectory { shell["currentDirectory"] = .string(directory) }
            object["shellIntegration"] = .object(shell)
        }
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
