import Foundation
import TrellisControl
import TrellisCore

/// `session.*` (methods.md#sessions). Input and output rules are protocol 1's: exact byte limits, paste framing, signed output
/// cursors and FR-RW15 host checks for remote workspace sessions.
extension AutomationServiceV2 {
    /// Exact decoded bytes accepted per input or execute call.
    static let inputLimit = 65_536
    static let defaultReadBytes = 65_536

    @MainActor func performSessions(_ call: CallV2) async throws -> JSONValue {
        let p = call.params
        switch call.spec.name {
        case "session.get":
            let id = try p.uuid("id")
            return ConventionsV2.resource("session", try session(call, id))
        case "session.start":
            let paneID = try p.uuid("paneId")
            let launch = try launchDescriptor(p, paneID: paneID, call)
            if launch == nil { try requireStoredLaunchAccess(paneID, call) }
            try requireStopped(paneID)
            try await readyRemoteLink(for: launch?.launch ?? storedLaunch(paneID), call)
            do { try await model.automationStartSession(paneID, launch: launch?.launch, environment: launch?.environment ?? [:]) } catch { throw Self.map(error) }
            return try await launchResult(call, paneID)
        case "session.restart":
            let paneID = try p.uuid("paneId")
            let launch = try launchDescriptor(p, paneID: paneID, call)
            if launch == nil { try requireStoredLaunchAccess(paneID, call) }
            let allowRunning = try p.optionalBool("allowRunning") == true, force = try p.optionalBool("force") == true
            // A running remote session can only be stopped through its host's link; the new one needs it too.
            if let session = model.snapshot.panes[paneID]?.sessionID, model.terminals[paneID]?.isRunning == true { try requireLinkUp(session) }
            try await readyRemoteLink(for: launch?.launch ?? storedLaunch(paneID), call)
            let outcome: AutomationCloseResult
            do { outcome = try await model.automationRestart(paneID, allowRunning: allowRunning, force: force) } catch { throw Self.map(error) }
            if let failure = Self.closeFailure(outcome) { throw failure }
            do { try await model.automationStartSession(paneID, launch: launch?.launch, environment: launch?.environment ?? [:]) } catch { throw Self.map(error) }
            return try await launchResult(call, paneID)
        case "session.stop":
            let id = try p.uuid("id")
            try requireRemoteHostAccess(id, call)
            guard let pane = model.snapshot.panes.values.first(where: { $0.sessionID == id }), let terminal = model.terminals[pane.id] else { throw Self.notFound }
            guard terminal.sessionID == id, terminal.isRunning else { throw Self.invalidState("The session is not running.", state: terminal.sessionID == id ? terminal.sessionState.rawValue : "exited") }
            try requireLinkUp(id)
            guard await model.endRunningSession(terminal, paneID: pane.id, force: try p.optionalBool("force") == true) else {
                throw ControlError.api(.closePending, "The session is still closing. Retry, or repeat with force: true after two seconds.", details: .object(["sessionIds": .array([ConventionsV2.idJSON(id)])]))
            }
            return ConventionsV2.resource("session", try session(call, id), workspaceRevision: model.snapshot.revision)
        case "session.sendInput": return try sendInput(call)
        case "session.execute":
            let id = try p.uuid("id")
            try requireRemoteHostAccess(id, call)
            let command = try p.string("command")
            guard !command.isEmpty, !command.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else {
                throw ControlError.invalidParams("command must be one non-empty line.", fields: ["command": "one line without CR or LF"])
            }
            let data = Data((command + "\r").utf8)
            guard data.count <= Self.inputLimit else { throw Self.inputTooLarge }
            guard let wait = try p.optionalObject("wait") else {
                try send(id, data, paste: false)
                // Submitted means the bytes were queued, not that the command finished (that is `wait`).
                return .object(["submitted": .bool(true), "acceptedBytes": ConventionsV2.number(data.count)])
            }
            return try await executeAndWait(id, data, timeoutMs: try wait.optionalInteger("timeoutMs") ?? 30_000)
        case "session.readOutput": return try readOutput(call)
        default: throw ControlError.methodNotFound
        }
    }

    /// session.execute with `wait`: the command is typed at the shell's prompt and followed to its finish mark (FR-SI02).
    /// The wait is registered before the bytes go, so a quick command's marks are never missed; the socket answers the call
    /// out of order (`waitsIf`), so nothing else on the connection waits behind it.
    @MainActor private func executeAndWait(_ sessionID: UUID, _ data: Data, timeoutMs: Int64) async throws -> JSONValue {
        guard let pane = model.snapshot.panes.values.first(where: { $0.sessionID == sessionID }) else { throw Self.notFound }
        // A remote workspace whose link is down answers REMOTE_DISCONNECTED first, as for any input.
        try requireLinkUp(sessionID)
        if let refusal = model.commandWaitRefusal(paneID: pane.id, sessionID: sessionID) {
            switch refusal {
            case "noIntegration":
                throw Self.invalidState("Waiting needs shell integration (FR-SI02) in this pane, so Trellis knows when the command finishes. Send it without wait.", state: refusal)
            case "busy":
                throw Self.invalidState("The shell is running a command, so the next one to finish might not be this one. Retry at its prompt.", state: refusal, retryable: true)
            default: throw Self.invalidState("The session is not running.", state: model.snapshot.sessions[sessionID]?.state.rawValue ?? "exited")
            }
        }
        let wait = model.beginCommandWait(paneID: pane.id, sessionID: sessionID)
        do { try send(sessionID, data, paste: false) } catch {
            model.endCommandWait(wait, paneID: pane.id)
            throw error
        }
        var object: [String: JSONValue] = ["submitted": .bool(true), "acceptedBytes": ConventionsV2.number(data.count)]
        switch await model.awaitCommand(wait, paneID: pane.id, timeout: .milliseconds(timeoutMs)) {
        case .finished(let code, let duration):
            object["timedOut"] = .bool(false)
            if let code { object["exitCode"] = ConventionsV2.number(code) }
            object["durationMs"] = ConventionsV2.number(Int64((duration * 1_000).rounded()))
        case .sessionEnded:
            object["timedOut"] = .bool(false)
            object["sessionEnded"] = .bool(true)
        case .timedOut: object["timedOut"] = .bool(true)
        }
        return .object(object)
    }

    @MainActor func session(_ call: CallV2, _ id: UUID) throws -> JSONValue {
        guard let pane = model.snapshot.panes.values.first(where: { $0.sessionID == id }) else { throw Self.notFound }
        let projection = projection(call, spaces: spaceOf(pane: pane.id))
        guard let session = projection.snapshot.sessions[id], projection.canSee(.pane, pane.id) else { throw Self.notFound }
        return projection.session(session, paneID: pane.id)
    }

    /// A failed launch is an error that still carries the failed session record.
    @MainActor private func launchResult(_ call: CallV2, _ paneID: UUID) async throws -> JSONValue {
        // The launch outcome reaches the store asynchronously; let it land so the record has its start time.
        await model.waitForUpdates()
        guard let sessionID = model.snapshot.panes[paneID]?.sessionID else { throw Self.notFound }
        let record = try session(call, sessionID)
        if model.terminals[paneID]?.sessionState == .failed || model.snapshot.sessions[sessionID]?.state == .failed {
            throw ControlError.api(.launchFailed, "The session could not be started. Check the executable, directory and environment.", details: .object(["session": record]))
        }
        return ConventionsV2.resource("session", record, workspaceRevision: model.snapshot.revision)
    }

    @MainActor private func requireStopped(_ paneID: UUID) throws {
        guard let pane = model.snapshot.panes[paneID] else { throw Self.notFound }
        let state = model.terminals[paneID].map { $0.sessionID == pane.sessionID ? $0.sessionState : .stopped } ?? model.snapshot.sessions[pane.sessionID]?.state
        guard state == .stopped else { throw Self.invalidState("Only a stopped pane can start; use session.restart.", state: state?.rawValue) }
    }

    /// Without `launch` the pane's saved launch runs. An agent needs agent.control and the agent in the grant's agent
    /// scope; a saved host or a remote workspace's host must be in host scope.
    @MainActor private func requireStoredLaunchAccess(_ paneID: UUID, _ call: CallV2) throws {
        guard let session = model.snapshot.panes[paneID].flatMap({ model.snapshot.sessions[$0.sessionID] }) else { return }
        try requireLaunchAccess(session.launch, call)
    }

    /// What starting a saved launch needs beyond session.start; also checked before `start: true` creates panes (a
    /// duplicated agent or ssh tab, a new pane in a remote workspace), so starting on create bypasses nothing.
    @MainActor func requireLaunchAccess(_ launch: SessionLaunch, _ call: CallV2) throws {
        if case .agent(let agent) = launch {
            guard call.access.grant.holds(.agentControl) else {
                throw ControlError.api(
                    .permissionDenied, "Starting an agent pane needs agent.control.", details: .object(["missing": .array([.string(CapabilityV2.agentControl.rawValue)])]))
            }
            guard call.access.canUse(agent: agent.agentID) else { throw ControlError.api(.permissionDenied, "This pane runs an agent outside this grant's agent scope.") }
        }
        let hostID: UUID
        switch launch {
        case .host(let id), .remoteShell(let id, _): hostID = id
        case .agent(let agent):
            guard let id = agent.hostID else { return }
            hostID = id
        case .shell, .process: return
        }
        try requireHost(hostID, call, "This pane connects to a saved host this grant cannot use.")
    }

    @MainActor func requireHost(_ hostID: UUID, _ call: CallV2, _ message: String) throws {
        switch call.access.hostAccess(hosts.hosts.first { $0.id == hostID }) {
        case .allowed: return
        case .hidden: throw ControlError.api(.permissionDenied, message)
        case .needsReapproval: throw ControlError.api(.permissionDenied, "This host's connection changed after it was approved. Reapprove it in Settings → Automation.")
        }
    }

    /// The launch to configure first, and its environment. The catalog already checked the shape, the session.execute
    /// rule and the ssh host's scope; this checks values. A shell in a remote workspace runs on its host (FR-RW10).
    @MainActor private func launchDescriptor(_ p: ParamsV2, paneID: UUID, _ call: CallV2) throws -> (launch: SessionLaunch, environment: [String: String])? {
        guard let launch = try p.optionalObject("launch") else { return nil }
        guard let tab = model.snapshot.panes[paneID].flatMap({ model.snapshot.tabs[$0.tabID] }) else { throw Self.notFound }
        let remoteHost = model.snapshot.spaces.first { $0.id == tab.spaceID }?.remoteHostID
        func absolute(_ key: String) throws -> String? {
            guard let path = try launch.optionalString(key) else { return nil }
            guard path.hasPrefix("/"), !path.contains("\0") else { throw ControlError.invalidParams("launch.\(key) must be an absolute path.", fields: ["launch." + key: "absolute path"]) }
            return path
        }
        var environment: [String: String] = [:]
        if case .object(let values)? = launch["environment"] {
            for (key, value) in values {
                guard case .string(let text) = value, !key.isEmpty, !key.contains("="), !key.contains("\0"), !text.contains("\0"), key.utf8.count <= 256, text.utf8.count <= 32_768,
                    !["TRELLIS_", "__TRELLIS_", "UTERM_", "__UTERM_"].contains(where: key.uppercased().hasPrefix)
                else { throw ControlError.invalidParams("Invalid environment entry.", fields: ["launch.environment": "string keys and values; TRELLIS_ names are reserved"]) }
                environment[key] = text
            }
        }
        let kind = try launch.string("kind")
        // A remote workspace runs only remote shells on its host; nothing local or ssh can start in it.
        if let remoteHost {
            guard kind == "shell" else { throw Self.invalidState("A remote workspace pane runs a shell on its host; launch.kind must be shell.", state: "remote") }
            try requireHost(remoteHost, call, "This pane runs on a saved host this grant cannot use.")
        }
        switch kind {
        case "shell":
            let directory = try absolute("directory")
            return (remoteHost.map { .remoteShell(hostID: $0, directory: directory) } ?? .shell(directory: directory), environment)
        case "process":
            let arguments = try launch.optionalStrings("arguments") ?? []
            guard arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 65_536 }) else {
                throw ControlError.invalidParams("launch.arguments must be strings without NUL.", fields: ["launch.arguments": "array of strings"])
            }
            guard let executable = try absolute("executable"), let directory = try absolute("directory") else { throw ControlError.invalidParams }
            return (.process(executable: executable, arguments: arguments, directory: directory), environment)
        default: return (.host(try launch.uuid("hostId")), [:])
        }
    }

    // MARK: Input

    private static let inputTooLarge = ControlError.api(.limitExceeded, "Input is limited to 64 KiB per call.", retryable: false)

    @MainActor private func sendInput(_ call: CallV2) throws -> JSONValue {
        let p = call.params
        let id = try p.uuid("id")
        try requireRemoteHostAccess(id, call)
        let text = try p.optionalString("text"), encoded = try p.optionalString("base64")
        // Oversized input is refused before it is decoded.
        if let encoded, encoded.utf8.count > (Self.inputLimit + 2) / 3 * 4 + 4 { throw Self.inputTooLarge }
        guard let data = text.map({ Data($0.utf8) }) ?? encoded.flatMap({ Data(base64Encoded: $0) }) else {
            throw ControlError.invalidParams("base64 is not valid.", fields: ["base64": "standard base64"])
        }
        guard !data.isEmpty else { throw ControlError.invalidParams("Input is empty.", fields: [text == nil ? "base64" : "text": "non-empty"]) }
        guard data.count <= Self.inputLimit else { throw Self.inputTooLarge }
        let paste = try p.optionalString("mode") == "paste"
        // Paste is text and can't end bracketed paste early.
        if paste, String(data: data, encoding: .utf8) == nil || data.range(of: Data("\u{1b}[201~".utf8)) != nil {
            throw ControlError.invalidParams("Paste input must be UTF-8 text without the bracketed-paste end marker.", fields: ["mode": "paste requires UTF-8 text"])
        }
        try send(id, data, paste: paste)
        return .object(["acceptedBytes": ConventionsV2.number(data.count), "mode": .string(paste ? "paste" : "literal")])
    }

    /// FR-RW15: acting on a remote workspace session (input, execute, stop, restart, reading its output) needs access to
    /// its host, as connecting to it does. Its record (session.get, pane.get, workspace.get) stays readable by space
    /// scope, with the host's ID shown only to grants that can read the host.
    @MainActor func requireRemoteHostAccess(_ sessionID: UUID, _ call: CallV2) throws {
        guard let hostID = model.snapshot.sessions[sessionID]?.launch.remoteHostID else { return }
        try requireHost(hostID, call, "This session runs on a saved host this grant cannot use.")
    }

    /// A running remote workspace session is reached only through its host's link; while it is down nothing is queued.
    @MainActor func requireLinkUp(_ sessionID: UUID) throws {
        guard let session = model.snapshot.sessions[sessionID], session.state == .running, let host = session.launch.remoteHostID, model.remoteLinks[host] != .connected else { return }
        throw ControlError.api(.remoteDisconnected, "The session's host is not connected. The session keeps running there; retry after it reconnects.", retryable: true, details: linkDetails(host))
    }

    @MainActor func storedLaunch(_ paneID: UUID) -> SessionLaunch? { model.snapshot.panes[paneID].flatMap { model.snapshot.sessions[$0.sessionID]?.launch } }

    @MainActor func send(_ sessionID: UUID, _ data: Data, paste: Bool) throws {
        // FR-RW15: input is never queued for a host that isn't connected; the session keeps running there.
        try requireLinkUp(sessionID)
        do {
            try model.automationSendInput(sessionID: sessionID, data: data, paste: paste)
        } catch .notFound {
            throw Self.notFound
        } catch .notRunning {
            throw Self.invalidState("The session is not running.", state: model.snapshot.sessions[sessionID]?.state.rawValue)
        } catch .queueFull {
            throw ControlError.api(.limitExceeded, "The terminal input queue is full. Wait and inspect the session before sending more.")
        } catch {
            throw Self.invalidState("Input could not be sent to the session.")
        }
    }

    // MARK: Output

    /// Screen and scrollback are plain-text snapshots; stream returns exact raw PTY bytes from the bounded journal with a
    /// cursor bound to this session and app instance.
    @MainActor private func readOutput(_ call: CallV2) throws -> JSONValue {
        let p = call.params
        let sessionID = try p.uuid("id")
        guard let terminal = model.terminals.values.first(where: { $0.sessionID == sessionID }) else { throw Self.notFound }
        try requireRemoteHostAccess(sessionID, call)
        let maxBytes = try p.optionalInteger("maxBytes").map(Int.init) ?? Self.defaultReadBytes
        let captured = JSONValue.string(ConventionsV2.timestamp(Date()))
        let view = try p.string("view")
        let invalidCursor = ControlError.api(.invalidCursor, "This cursor belongs to another session, a restarted session, or another app instance. Read again without a cursor.")
        guard view == "stream" else {
            guard try p.optionalString("cursor") == nil else { throw ControlError.invalidParams("Only the stream view takes a cursor.", fields: ["cursor": "stream view only"]) }
            let text = view == "screen" ? terminal.screenText : ((try? terminal.adapter.read(.retainedText)) ?? "")
            // Keep the newest text within the byte limit, cut on a character boundary.
            var kept = Substring(text)
            while kept.utf8.count > maxBytes { kept = kept.dropFirst(max(1, (kept.utf8.count - maxBytes) / 4)) }
            return .object([
                "view": .string(view), "text": .string(String(kept)), "capturedAt": captured, "truncated": .bool(kept.startIndex != text.startIndex),
                "historyNotice": .string(terminal.historyNotice)
            ])
        }
        var offset: UInt64?
        if let token = try p.optionalString("cursor") {
            guard let cursor = OutputCursor(token: token), cursor.instanceID == instanceID, cursor.sessionID == sessionID else { throw invalidCursor }
            offset = cursor.offset
        }
        let journal = model.outputJournal
        guard journal.contains(session: sessionID) else {
            // No output yet: an empty read whose cursor starts at offset 0.
            guard offset == nil || offset == 0 else { throw invalidCursor }
            return .object([
                "view": .string("stream"), "base64": .string(""), "nextCursor": .string(OutputCursor(instanceID: instanceID, sessionID: sessionID, offset: 0).token),
                "truncated": .bool(false), "gap": .bool(false), "capturedAt": captured
            ])
        }
        let read: OutputJournal.Read
        do { read = try journal.read(session: sessionID, from: offset, maxBytes: maxBytes) } catch { throw invalidCursor }
        return .object([
            "view": .string("stream"), "base64": .string(read.data.base64EncodedString()),
            "nextCursor": .string(OutputCursor(instanceID: instanceID, sessionID: sessionID, offset: read.next).token), "truncated": .bool(read.truncated),
            "gap": .bool(read.gap), "capturedAt": captured
        ])
    }
}
