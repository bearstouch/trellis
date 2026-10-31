import Darwin
import Foundation
import TrellisBroker
import TrellisCore

/// One remote workspace session, owned by the helper on its host (FR-RW04, FR-RW06): spawned with `spawnLogin`, or
/// adopted with `attach`. Losing the link is not an exit: the session keeps running there, input is refused (never
/// queued) until `resume` re-attaches on a new connection from the exact output position this view shows (FR-RW08).
@MainActor
public final class RemoteSessionTransport: TerminalProcessTransport, BrokerSessionSink {
    public let sessionID: UUID
    public let hostID: UUID
    public private(set) var connection: BrokerConnection
    public var onOutput: ((Data) -> Void)?
    public var onExit: ((Int32?) -> Void)?
    public var onInputError: ((Error) -> Void)?
    public var onPasswordPromptChanged: ((Bool) -> Void)?
    /// The link went down or came back; the pane says so.
    public var onLinkChanged: ((Bool) -> Void)?
    /// A close was asked for while the link was down; the model sends it once the host is reachable again.
    public var onSignalWhileDisconnected: ((Int32) -> Void)?
    public private(set) var isRunning = false
    public private(set) var passwordPromptActive = false
    public private(set) var linkLost = false
    public var survivesQuit: Bool { true }
    /// The output position this view has shown: the offset of its last attach plus live output since.
    public private(set) var received: UInt64 = 0
    private var kept = false
    private var used = false
    private var delivering = true
    private var held: [Data] = []
    private var heldStart = 0
    private var heldBytes = 0
    /// Held output went past the cap: its oldest part was dropped, so delivery starts with a reset.
    private var heldTruncated = false
    private var heldExit: Int32??
    private var exitReported = false
    private var awaitingStart = false
    /// Live output that arrived while an attach was answered: it follows the attach's offset.
    private var arrivedWhileAttaching: UInt64 = 0
    private var resuming = false
    private var ended = false
    private var replay = Data()

    public init(sessionID: UUID, hostID: UUID, connection: BrokerConnection) {
        self.sessionID = sessionID; self.hostID = hostID; self.connection = connection
    }

    /// Remote sessions start with `launchRemote`; a local launch description never runs on a host.
    public func launch(_ configuration: ValidatedLocalLaunch, size: TerminalSize) async throws -> Int32 { throw LocalLaunchError.invalidExecutable }

    public func launchRemote(_ request: BrokerLoginRequest) async throws -> Int32 {
        guard !used else { throw LocalLaunchError.alreadyStarted }
        used = true
        connection.register(self, sessionID: sessionID)
        awaitingStart = true
        defer { awaitingStart = false }
        let reply: BrokerMessage
        do { reply = try await connection.request(.spawnLogin(request)) } catch {
            connection.unregister(sessionID: sessionID)
            throw LocalLaunchError.spawnFailed(EIO)
        }
        guard case .spawned(_, let pid) = reply, pid > 0 else {
            connection.unregister(sessionID: sessionID)
            if case .failed(_, let code) = reply, code != 0 { throw LocalLaunchError.spawnFailed(code) }
            throw LocalLaunchError.spawnFailed(EIO)
        }
        isRunning = !ended
        return pid
    }

    /// Adopts a session the helper kept (FR-RW09): its replay, with output after it held until `beginDelivery`.
    public func attach(size: TerminalSize) async -> (BrokerAttachment, Data)? {
        guard !used else { return nil }
        used = true
        delivering = false
        guard let attachment = await requestAttach(size: size, since: nil) else { return nil }
        isRunning = attachment.record.running && !ended
        defer { replay = Data() }
        return (attachment, replay)
    }

    /// Re-attaches on a new connection after the link came back. The missed output is delivered once: exactly, when
    /// the host still holds it, otherwise after a reset with the most recent output (FR-RW08).
    /// `timeout` covers the attach and the replay the broker sends before answering it.
    public func resume(on next: BrokerConnection, size: TerminalSize, timeout: Duration = .seconds(5)) async -> Bool {
        // Only a live session resumes: one that ended, or was closed while the link was down, is never attached again.
        guard used, isRunning, !resuming, linkLost || !connection.isOpen else { return true }
        resuming = true
        defer { resuming = false }
        connection.unregister(sessionID: sessionID)
        connection = next
        replay = Data()
        let prompt = passwordPromptActive
        // Live output can arrive before this continues; it is held so it follows the missed output.
        delivering = false
        guard let attachment = await requestAttach(size: size, since: received, timeout: timeout) else { beginDelivery(); return false }
        let missed = replay
        replay = Data()
        linkLost = false
        onLinkChanged?(true)
        // A truncated replay already starts with a reset.
        if !missed.isEmpty { onOutput?(attachment.resumed == true || attachment.truncated ? missed : Self.reset + missed) }
        if passwordPromptActive != prompt { onPasswordPromptChanged?(passwordPromptActive) }
        beginDelivery()
        if !attachment.record.running, !ended {
            ended = true; isRunning = false
            connection.post(.release(sessionID: sessionID))
            reportExit(attachment.record.exitCode)
        }
        return true
    }

    /// Re-attaches a host's sessions on `next` a few at a time: each attach is its own round trip, answered by request ID,
    /// so twelve panes are back after three round trips instead of twelve. The broker answers in order, each reply after its
    /// replay (up to 4 MiB), so the batch is capped and each attach's timeout covers the replays queued ahead of it, as one
    /// attach alone had before. Results are in the order given.
    public static let resumeBatch = 4
    public static func resume(_ sessions: [(RemoteSessionTransport, TerminalSize)], on next: BrokerConnection) async -> [Bool] {
        var results: [Bool] = []
        for start in stride(from: 0, to: sessions.count, by: resumeBatch) {
            let batch = sessions[start..<min(start + resumeBatch, sessions.count)]
            let timeout = Duration.seconds(5) * batch.count
            // All of a batch are sent before any is awaited; each task stays on the main actor, like a single resume.
            let resuming = batch.map { transport, size in Task { await transport.resume(on: next, size: size, timeout: timeout) } }
            for task in resuming { results.append(await task.value) }
        }
        return results
    }

    /// Without the exact tail, the screen is cleared before the most recent output so nothing is shown twice.
    static let reset = Data("\u{1b}c".utf8)

    private func requestAttach(size: TerminalSize, since: UInt64?, timeout: Duration = .seconds(5)) async -> BrokerAttachment? {
        connection.register(self, sessionID: sessionID)
        awaitingStart = true
        arrivedWhileAttaching = 0
        defer { awaitingStart = false }
        let request = BrokerMessage.attach(sessionID: sessionID, columns: UInt16(size.columns), rows: UInt16(size.rows), since: since)
        guard case .attached(let attachment)? = try? await connection.request(request, timeout: timeout) else {
            connection.unregister(sessionID: sessionID)
            return nil
        }
        if let offset = attachment.offset { received = offset &+ arrivedWhileAttaching }
        passwordPromptActive = attachment.passwordPrompt
        return attachment
    }

    public func send(_ data: Data) throws {
        guard isRunning, !linkLost, connection.isOpen else { throw TerminalAdapterError.inputClosed }
        guard !data.isEmpty else { return }
        do { try connection.sendInput(data, sessionID: sessionID) } catch BrokerClientError.queueFull { throw TerminalAdapterError.inputQueueFull } catch {
            throw TerminalAdapterError.inputClosed
        }
    }

    public func resize(_ size: TerminalSize) {
        guard isRunning, !linkLost else { return }
        connection.post(.resize(sessionID: sessionID, columns: UInt16(size.columns), rows: UInt16(size.rows)))
    }

    /// The helper checks the process is still its own before signalling. Without a link the close is recorded for later
    /// and the pane is let go now, so closing never waits on the network.
    public func signalGroup(_ signal: Int32) {
        guard isRunning, !kept else { return }
        guard !linkLost, connection.isOpen else {
            onSignalWhileDisconnected?(signal)
            isRunning = false
            reportExit(nil)
            return
        }
        connection.post(.signal(sessionID: sessionID, signal: signal))
    }

    public func setKeepAlive(_ on: Bool) { kept = on }

    public func beginDelivery() {
        guard !delivering else { return }
        delivering = true
        let output = held[heldStart...], truncated = heldTruncated
        held = []; heldStart = 0; heldBytes = 0; heldTruncated = false
        if truncated { onOutput?(Self.reset) }
        for data in output { onOutput?(data) }
        if let code = heldExit { heldExit = nil; reportExit(code) }
    }

    public func brokerOutput(_ data: Data) {
        received &+= UInt64(data.count)
        if awaitingStart { arrivedWhileAttaching &+= UInt64(data.count) }
        guard delivering else {
            // Every byte stays counted as shown, so beyond the cap the oldest held output goes and the screen is reset
            // before the most recent, as for a truncated replay (FR-RW08); dropping the newest would lose it for good.
            held.append(data); heldBytes += data.count
            while heldBytes > OutputRing.sessionLimit, heldStart < held.count - 1 {
                heldBytes -= held[heldStart].count; held[heldStart] = Data(); heldStart += 1; heldTruncated = true
            }
            if heldStart > 1024, heldStart * 2 > held.count { held.removeFirst(heldStart); heldStart = 0 }
            return
        }
        onOutput?(data)
    }

    public func brokerReplay(_ data: Data) {
        guard replay.count + data.count <= OutputRing.sessionLimit + 4096 else { return }
        replay.append(data)
    }

    public func brokerExited(waitStatus: Int32) {
        guard isRunning || awaitingStart, !ended else { return }
        ended = true; isRunning = false
        connection.post(.release(sessionID: sessionID))
        let code = BrokerSessionRecord.exitCode(waitStatus)
        if delivering { reportExit(code) } else { heldExit = .some(code) }
    }

    public func brokerPrompt(_ active: Bool) {
        guard active != passwordPromptActive else { return }
        passwordPromptActive = active
        if delivering { onPasswordPromptChanged?(active) }
    }

    public func brokerInputRejected() {
        if delivering { onInputError?(TerminalAdapterError.inputQueueFull) }
    }

    /// The link went down: the session keeps running on the host (FR-RW06), so this is never an exit.
    public func brokerDisconnected() {
        guard isRunning, !linkLost else { return }
        linkLost = true
        onLinkChanged?(false)
    }

    private func reportExit(_ code: Int32?) {
        guard !exitReported else { return }
        exitReported = true
        onExit?(code)
    }
}
