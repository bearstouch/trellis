import Darwin
import Foundation
import TrellisBroker
import TrellisCore

/// A running session the broker held while the app was closed, ready for a stopped pane (FR-R03).
@MainActor
public struct BrokerAdoption {
    public let sessionID: UUID
    /// Set while the session runs; nil once it ended.
    public let processID: Int32?
    public let exitCode: Int32?
    /// The session's shell-integration nonce, kept only in broker memory.
    public let nonce: String?
    /// Retained output, at most `OutputRing.sessionLimit` plus a mode prefix.
    public let replay: Data
    public let transport: (any TerminalProcessTransport)?
    public init(sessionID: UUID, processID: Int32?, exitCode: Int32?, nonce: String?, replay: Data, transport: (any TerminalProcessTransport)?) {
        self.sessionID = sessionID; self.processID = processID; self.exitCode = exitCode; self.nonce = nonce; self.replay = replay; self.transport = transport
    }
}

public struct BrokerSessionSummary: Equatable, Sendable {
    public let sessionID: UUID
    public let running: Bool
    public let exitCode: Int32?
    public init(sessionID: UUID, running: Bool, exitCode: Int32?) { self.sessionID = sessionID; self.running = running; self.exitCode = exitCode }
}

public enum BrokerListing: Equatable, Sendable {
    case sessions([BrokerSessionSummary])
    /// A broker of another protocol version runs for this state directory; it can only be stopped.
    case incompatible
}

/// The app's view of its session broker; tests inject a fake and nil keeps every session local.
@MainActor
public protocol SessionBrokerClient: AnyObject {
    /// Connects to this state directory's broker, starting one if needed.
    func prepare() async -> Bool
    /// A transport for a new session that survives quit; nil unless `prepare` succeeded.
    func makeTransport(sessionID: UUID) -> (any TerminalProcessTransport)?
    /// Sessions of an already-running broker; nil when none runs. Never starts one.
    func existingSessions() async -> BrokerListing?
    func adopt(sessionID: UUID, size: TerminalSize) async -> BrokerAdoption?
    /// Forgets an ended session.
    func release(sessionID: UUID)
    /// Hangs up sessions no pane claims (the broker checks it still owns each process).
    func hangUp(sessionIDs: [UUID])
    func stopIncompatibleBroker() async
    /// Stops forwarding output and disconnects; kept sessions continue.
    func detach() async
}

/// One session held by the broker. Signals are checked against the process identity inside the
/// broker, which owns it; while kept alive none is sent at all.
@MainActor
public final class BrokerSessionTransport: TerminalProcessTransport, BrokerSessionSink {
    public let sessionID: UUID
    private let connection: BrokerConnection
    public var onOutput: ((Data) -> Void)?
    public var onExit: ((Int32?) -> Void)?
    public var onInputError: ((Error) -> Void)?
    public var onPasswordPromptChanged: ((Bool) -> Void)?
    public private(set) var isRunning = false
    public private(set) var passwordPromptActive = false
    public var survivesQuit: Bool { true }
    private var kept = false
    private var used = false
    private var delivering: Bool
    private var held: [Data] = []
    private var heldBytes = 0
    private var heldExit: Int32??
    private var exitReported = false
    private var replay = Data()

    init(sessionID: UUID, connection: BrokerConnection, delivering: Bool) {
        self.sessionID = sessionID; self.connection = connection; self.delivering = delivering
    }

    public func launch(_ configuration: ValidatedLocalLaunch, size: TerminalSize) async throws -> Int32 {
        guard !used else { throw LocalLaunchError.alreadyStarted }
        used = true
        connection.register(self, sessionID: sessionID)
        let request = BrokerSpawnRequest(
            sessionID: sessionID, executable: configuration.executable, arguments: [configuration.executable] + configuration.arguments,
            environment: configuration.environmentArray, directory: configuration.directory, columns: UInt16(size.columns), rows: UInt16(size.rows))
        let reply: BrokerMessage
        do { reply = try await connection.request(.spawn(request)) } catch {
            connection.unregister(sessionID: sessionID)
            throw LocalLaunchError.spawnFailed(EIO)
        }
        guard case .spawned(_, let pid) = reply, pid > 0 else {
            connection.unregister(sessionID: sessionID)
            if case .failed(_, let code) = reply, code != 0 { throw LocalLaunchError.spawnFailed(code) }
            throw LocalLaunchError.spawnFailed(EIO)
        }
        isRunning = true
        return pid
    }

    /// Requests the session's replay; output and exit after it are held until `beginDelivery`.
    func attach(size: TerminalSize) async -> (BrokerAttachment, Data)? {
        guard !used else { return nil }
        used = true
        connection.register(self, sessionID: sessionID)
        guard case .attached(let attachment)? = try? await connection.request(.attach(sessionID: sessionID, columns: UInt16(size.columns), rows: UInt16(size.rows))) else {
            connection.unregister(sessionID: sessionID)
            return nil
        }
        isRunning = attachment.record.running
        passwordPromptActive = attachment.passwordPrompt
        defer { replay = Data() }
        return (attachment, replay)
    }

    public func send(_ data: Data) throws {
        guard isRunning, connection.isOpen else { throw TerminalAdapterError.inputClosed }
        guard !data.isEmpty else { return }
        do { try connection.sendInput(data, sessionID: sessionID) } catch BrokerClientError.queueFull { throw TerminalAdapterError.inputQueueFull } catch {
            throw TerminalAdapterError.inputClosed
        }
    }

    public func resize(_ size: TerminalSize) {
        guard isRunning else { return }
        connection.post(.resize(sessionID: sessionID, columns: UInt16(size.columns), rows: UInt16(size.rows)))
    }

    public func signalGroup(_ signal: Int32) {
        guard isRunning, !kept else { return }
        connection.post(.signal(sessionID: sessionID, signal: signal))
    }

    public func setKeepAlive(_ on: Bool) { kept = on }

    public func beginDelivery() {
        guard !delivering else { return }
        delivering = true
        let output = held
        held = []; heldBytes = 0
        for data in output { onOutput?(data) }
        if let code = heldExit { heldExit = nil; reportExit(code) }
    }

    public func brokerOutput(_ data: Data) {
        guard delivering else {
            // Bounded like the broker's own ring; an adoption is attached within moments.
            guard heldBytes + data.count <= OutputRing.sessionLimit else { return }
            held.append(data); heldBytes += data.count
            return
        }
        onOutput?(data)
    }

    public func brokerReplay(_ data: Data) {
        guard replay.count + data.count <= OutputRing.sessionLimit + 4096 else { return }
        replay.append(data)
    }

    public func brokerExited(waitStatus: Int32) {
        guard isRunning else { return }
        isRunning = false
        connection.post(.release(sessionID: sessionID))
        let code = BrokerSessionRecord.exitCode(waitStatus)
        if delivering { reportExit(code) } else { heldExit = .some(code) }
    }

    public func brokerPrompt(_ active: Bool) {
        guard active != passwordPromptActive else { return }
        passwordPromptActive = active
        if delivering { onPasswordPromptChanged?(active) }
    }

    /// The broker went away (a crash ends its sessions). A kept session is left to the next launch.
    public func brokerDisconnected() {
        guard isRunning, !kept else { return }
        isRunning = false
        if delivering { reportExit(nil) } else { heldExit = .some(nil) }
    }

    private func reportExit(_ code: Int32?) {
        guard !exitReported else { return }
        exitReported = true
        onExit?(code)
    }
}

/// Talks to the broker of one state directory, through `BrokerLauncher` discovery.
@MainActor
public final class BrokerSessionClient: SessionBrokerClient {
    public static let helperName = BrokerProtocol.helperName
    private let launcher: BrokerLauncher
    private var connection: BrokerConnection?
    private var preparing: Task<Bool, Never>?

    public init(launcher: BrokerLauncher) { self.launcher = launcher }

    /// `clientPath` is this app's executable, which the broker accepts as its only client.
    public convenience init(stateDirectory: URL, helperPath: String, clientPath: String) {
        self.init(launcher: BrokerLauncher(stateDirectory: stateDirectory, helperPath: helperPath, clientPath: clientPath))
    }

    public static func currentExecutable() -> String? { BrokerLauncher.currentExecutable() }

    private var open: BrokerConnection? { connection?.isOpen == true ? connection : nil }

    private enum Found { case none, connected(BrokerConnection), incompatible }

    private func connectExisting() async -> Found {
        if let open { return .connected(open) }
        guard let discovery = launcher.discovery() else { return .none }
        var attempt: Result<BrokerConnection, BrokerClientError> = .failure(.unavailable)
        // A refused connect is retried briefly before the record is dropped, so a live broker is never orphaned by a hiccup.
        for retry in 0..<3 {
            if retry > 0 { try? await Task.sleep(for: .milliseconds(50)) }
            do throws(BrokerClientError) { attempt = .success(try BrokerConnection.connect(socketPath: discovery.socketPath, brokerExecutable: launcher.helperPath)) } catch {
                attempt = .failure(error)
            }
            if case .failure(.unavailable) = attempt { continue }
            break
        }
        let connection: BrokerConnection
        switch attempt {
        case .success(let connected): connection = connected
        case .failure(let error):
            // Nothing answers: the broker exited. An answering but unexpected peer is left alone.
            if error == .unavailable { launcher.removeDiscovery() }
            return .none
        }
        do { try await connection.hello() } catch {
            return (error as? BrokerClientError) == .incompatible ? .incompatible : .none
        }
        adopt(connection)
        return .connected(connection)
    }

    private func adopt(_ connection: BrokerConnection) {
        self.connection = connection
        connection.onClose = { [weak self, weak connection] in
            guard let self, self.connection === connection else { return }
            self.connection = nil
        }
    }

    public func prepare() async -> Bool {
        if open != nil { return true }
        if let preparing { return await preparing.value }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            if case .connected = await self.connectExisting() { return true }
            let launcher = self.launcher
            guard let socketPath = try? await Task.detached(operation: { () throws(BrokerClientError) -> String in try launcher.spawn() }).value else { return false }
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline {
                if let connection = try? BrokerConnection.connect(socketPath: socketPath, brokerExecutable: launcher.helperPath) {
                    guard (try? await connection.hello()) != nil else { return false }
                    launcher.publish(socketPath: socketPath)
                    self.adopt(connection)
                    return true
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        preparing = task
        defer { preparing = nil }
        return await task.value
    }

    public func makeTransport(sessionID: UUID) -> (any TerminalProcessTransport)? {
        guard let open else { return nil }
        return BrokerSessionTransport(sessionID: sessionID, connection: open, delivering: true)
    }

    public func existingSessions() async -> BrokerListing? {
        switch await connectExisting() {
        case .none: return nil
        case .incompatible: return .incompatible
        case .connected(let connection):
            guard case .sessions(let records)? = try? await connection.request(.list) else { return nil }
            return .sessions(records.map { BrokerSessionSummary(sessionID: $0.sessionID, running: $0.running, exitCode: $0.exitCode) })
        }
    }

    public func adopt(sessionID: UUID, size: TerminalSize) async -> BrokerAdoption? {
        guard let open else { return nil }
        let transport = BrokerSessionTransport(sessionID: sessionID, connection: open, delivering: false)
        guard let (attachment, replay) = await transport.attach(size: size) else { return nil }
        let running = attachment.record.running
        return BrokerAdoption(
            sessionID: sessionID, processID: running ? attachment.record.processID : nil, exitCode: attachment.record.exitCode,
            nonce: attachment.nonce, replay: replay, transport: running ? transport : nil)
    }

    public func release(sessionID: UUID) { open?.post(.release(sessionID: sessionID)) }

    public func hangUp(sessionIDs: [UUID]) {
        for id in sessionIDs { open?.post(.signal(sessionID: id, signal: SIGHUP)) }
    }

    public func stopIncompatibleBroker() async {
        guard let discovery = launcher.discovery(), let connection = try? BrokerConnection.connect(socketPath: discovery.socketPath, brokerExecutable: launcher.helperPath)
        else { return }
        connection.sendStopAll()
        try? await Task.sleep(for: .milliseconds(200))
        connection.close()
        launcher.removeDiscovery()
    }

    public func detach() async {
        guard let open else { return }
        _ = try? await open.request(.detach, timeout: .seconds(1))
        open.close()
    }
}
