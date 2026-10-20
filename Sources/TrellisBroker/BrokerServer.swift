import Darwin
import Foundation
import TrellisPOSIX

/// The resident `trellis-broker` (FR-R03): owns the PTYs of sessions that outlive the app, keeps a bounded
/// replay of their output and serves one authenticated app at a time over an owner-only AF_UNIX socket.
/// All state is confined to `queue`; nothing here logs terminal output, input or environment values.
public final class BrokerServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var socketPath: String
        /// The only executable allowed to connect (the app), symlink-resolved.
        public var clientPath: String
        public var idleExit: TimeInterval
        public init(socketPath: String, clientPath: String, idleExit: TimeInterval) {
            self.socketPath = socketPath; self.clientPath = clientPath; self.idleExit = idleExit
        }
    }

    /// Reads pause while this much output waits for a slow client, and resume below a quarter of it.
    static let backpressureLimit = 1_048_576
    static let inputLimit = 1_048_576

    private final class Session: @unchecked Sendable {
        let id: UUID
        let pid: Int32
        let identity: BrokerProcessIdentity?
        let descriptor: Int32
        let nonce: String?
        var io: DispatchIO?
        var exitSource: DispatchSourceProcess?
        var drainTimer: DispatchWorkItem?
        var waitStatus: Int32?
        var readEnded = false
        var readArmed = false
        var finished = false
        var attached = true
        var pendingInput = 0
        var promptActive = false
        var promptCheckScheduled = false
        init(id: UUID, pid: Int32, identity: BrokerProcessIdentity?, descriptor: Int32, nonce: String?) {
            self.id = id; self.pid = pid; self.identity = identity; self.descriptor = descriptor; self.nonce = nonce
        }
        var record: BrokerSessionRecord { BrokerSessionRecord(sessionID: id, processID: pid, running: waitStatus == nil, waitStatus: waitStatus) }
    }

    private final class Client: @unchecked Sendable {
        let io: DispatchIO
        var decoder = BrokerFrameDecoder()
        var greeted = false
        var pending = 0
        var closing = false
        init(io: DispatchIO) { self.io = io }
    }

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "com.bearstouch.trellis.broker", qos: .userInitiated)
    private let now: @Sendable () -> Date
    private let ownPID = getpid()
    private var core: BrokerCore
    private var listenFD: Int32 = -1
    private var listener: DispatchSourceRead?
    private var client: Client?
    private var sessions: [UUID: Session] = [:]
    private var rings: [UUID: OutputRing] = [:]
    private var paused = false
    private var stopping = false
    private var timers: [DispatchSourceTimer] = []
    private var signalSources: [DispatchSourceSignal] = []

    public init(configuration: Configuration, now: @escaping @Sendable () -> Date = Date.init) {
        self.configuration = configuration
        self.now = now
        core = BrokerCore(idleExit: configuration.idleExit, now: now())
    }

    /// Binds the socket inside its owner-only directory and starts serving.
    public func start() throws {
        let path = configuration.socketPath
        guard BrokerFiles.isOwnerOnlyDirectory((path as NSString).deletingLastPathComponent), var address = BrokerFiles.address(path) else { throw POSIXError(.EACCES) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        BrokerFiles.configure(fd)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        listener = source
        source.resume()
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in self?.stopEverything() }
            source.resume()
            signalSources.append(source)
        }
        // The process-exit source can be missed or deferred; a periodic wait keeps reaping independent of it.
        timers.append(repeating(.milliseconds(250)) { $0.reapAll() })
        timers.append(repeating(.seconds(1)) { $0.checkIdle() })
    }

    private func repeating(_ interval: DispatchTimeInterval, _ work: @escaping @Sendable (BrokerServer) -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in if let self { work(self) } }
        timer.resume()
        return timer
    }

    // MARK: Client

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        BrokerFiles.configure(fd)
        guard BrokerFiles.peerRuns(fd, executable: configuration.clientPath) else { close(fd); return }
        guard !stopping, core.acceptClient() else {
            let refusal = (try? BrokerFrame.control(BrokerEnvelope(requestID: nil, message: .refused(reason: "BROKER_BUSY"))))?.encoded ?? Data()
            _ = refusal.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            close(fd)
            return
        }
        let io = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in close(fd) }
        io.setLimit(lowWater: 1)
        let connection = Client(io: io)
        client = connection
        readClient(connection)
    }

    private func readClient(_ connection: Client) {
        connection.io.read(offset: 0, length: 65_536, queue: queue) { [weak self] done, data, error in
            guard let self, self.client === connection else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try connection.decoder.append(Data(data)) {
                        self.handle(frame, from: connection)
                        guard self.client === connection else { return }
                    }
                } catch {
                    self.dropClient()
                    return
                }
            }
            if error != 0 || (done && (data?.isEmpty ?? true)) { self.dropClient() } else if done { self.readClient(connection) }
        }
    }

    private func dropClient() {
        guard let connection = client else { return }
        client = nil
        connection.io.close(flags: .stop)
        core.clientDisconnected()
        for session in sessions.values { session.attached = false }
        setPaused(false)
    }

    private func enqueue(_ frames: [BrokerFrame]) {
        guard let connection = client, !connection.closing else { return }
        for frame in frames {
            let data = frame.encoded
            connection.pending += data.count
            let payload = data.withUnsafeBytes { DispatchData(bytes: $0) }
            connection.io.write(offset: 0, data: payload, queue: queue) { [weak self] done, _, error in
                guard let self, self.client === connection, done || error != 0 else { return }
                connection.pending -= data.count
                if error != 0 { self.dropClient(); return }
                if connection.closing, connection.pending <= 0 { self.dropClient(); return }
                if self.paused, connection.pending < Self.backpressureLimit / 4 { self.setPaused(false) }
            }
        }
        if connection.pending > Self.backpressureLimit { setPaused(true) }
    }

    private func reply(_ requestID: UInt64?, _ message: BrokerMessage) {
        guard let frame = try? BrokerFrame.control(BrokerEnvelope(requestID: requestID, message: message)) else { return }
        enqueue([frame])
    }

    private func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        if !value { for session in sessions.values where !session.readArmed { readPTY(session) } }
    }

    private func handle(_ frame: BrokerFrame, from connection: Client) {
        if frame.kind == .stopAll { stopEverything(); return }
        guard connection.greeted else {
            guard let envelope = frame.envelope, case .hello(let version) = envelope.message else { dropClient(); return }
            let answer = BrokerCore.hello(version, brokerPID: ownPID)
            reply(envelope.requestID, answer)
            if case .welcome = answer { connection.greeted = true } else { connection.closing = true }
            return
        }
        switch frame.kind {
        case .input:
            guard let (id, bytes) = frame.stream, let session = sessions[id] else { return }
            write(bytes, to: session)
        case .control:
            guard let envelope = frame.envelope else { dropClient(); return }
            respond(to: envelope)
        default: dropClient()
        }
    }

    private func respond(to envelope: BrokerEnvelope) {
        let id = envelope.requestID
        switch envelope.message {
        case .spawn(let request):
            reply(id, spawn(request))
        case .list:
            reply(id, .sessions(sessions.values.map(\.record).sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }))
        case .attach(let sessionID, let columns, let rows):
            guard let session = sessions[sessionID] else { reply(id, .failed(code: "NOT_FOUND", errno: 0)); return }
            resize(session, columns: columns, rows: rows)
            let ring = rings[sessionID] ?? OutputRing()
            let replay = ring.replay
            if !replay.isEmpty { enqueue(BrokerFrame.stream(.replay, sessionID: sessionID, bytes: replay)) }
            session.attached = true
            reply(id, .attached(BrokerAttachment(record: session.record, nonce: session.nonce, passwordPrompt: session.promptActive, truncated: ring.truncated)))
            // Full-screen programs redraw for the newly attached view.
            if session.waitStatus == nil, !session.readEnded {
                let group = tcgetpgrp(session.descriptor)
                if group > 0 { kill(-group, SIGWINCH) }
            }
        case .resize(let sessionID, let columns, let rows):
            if let session = sessions[sessionID] { resize(session, columns: columns, rows: rows) }
        case .signal(let sessionID, let number):
            reap(sessions[sessionID])
            guard BrokerCore.permitsSignal(number), let session = sessions[sessionID], session.waitStatus == nil, let identity = session.identity,
                identity.permitsSignal(current: Self.identity(session.pid), ownerPID: ownPID)
            else { reply(id, .failed(code: "SIGNAL_REFUSED", errno: 0)); return }
            kill(-session.pid, number)
            reply(id, .ok)
        case .release(let sessionID):
            guard let session = sessions[sessionID] else { reply(id, .ok); return }
            guard session.finished else { reply(id, .failed(code: "SESSION_RUNNING", errno: 0)); return }
            sessions.removeValue(forKey: sessionID)
            rings.removeValue(forKey: sessionID)
            reply(id, .ok)
        case .detach:
            for session in sessions.values { session.attached = false }
            reply(id, .ok)
        default:
            reply(id, .failed(code: "UNSUPPORTED", errno: 0))
        }
    }

    // MARK: Sessions

    static func identity(_ pid: Int32) -> BrokerProcessIdentity? {
        let value = trellis_read_process_identity(pid)
        guard value.valid != 0 else { return nil }
        return BrokerProcessIdentity(
            pid: pid, parentPID: value.parent_pid, groupID: value.group_id, startedSeconds: value.started_seconds, startedMicroseconds: value.started_microseconds)
    }

    private func spawn(_ request: BrokerSpawnRequest) -> BrokerMessage {
        guard !stopping, sessions[request.sessionID] == nil, !request.arguments.isEmpty, request.columns > 0, request.rows > 0, request.executable.hasPrefix("/"),
            request.directory.hasPrefix("/")
        else { return .failed(code: "INVALID_REQUEST", errno: EINVAL) }
        let arguments = request.arguments.map { strdup($0) }
        let environment = request.environment.map { strdup($0) }
        defer {
            arguments.forEach { free($0) }
            // Environment values may carry nonces; clear the C copies before freeing them.
            for value in environment { if let value { memset(value, 0, strlen(value)) }; free(value) }
        }
        guard arguments.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else { return .failed(code: "SPAWN_FAILED", errno: ENOMEM) }
        let result = request.executable.withCString { executable in
            request.directory.withCString { directory in
                (arguments + [nil]).withUnsafeBufferPointer { argv in
                    (environment + [nil]).withUnsafeBufferPointer { envp in
                        trellis_spawn_pty(executable, argv.baseAddress, envp.baseAddress, directory, request.columns, request.rows)
                    }
                }
            }
        }
        guard result.error_code == 0 else { return .failed(code: "SPAWN_FAILED", errno: result.error_code) }
        let prefix = BrokerProtocol.nonceVariable + "="
        let nonce = request.environment.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        let session = Session(id: request.sessionID, pid: result.pid, identity: Self.identity(result.pid), descriptor: result.master_fd, nonce: nonce)
        let fd = result.master_fd
        let io = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in close(fd) }
        io.setLimit(lowWater: 1)
        io.setLimit(highWater: BrokerProtocol.chunkLimit)
        session.io = io
        let exit = DispatchSource.makeProcessSource(identifier: result.pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self, weak session] in self?.reap(session) }
        session.exitSource = exit
        exit.resume()
        sessions[session.id] = session
        rings[session.id] = OutputRing()
        readPTY(session)
        reap(session)
        return .spawned(sessionID: session.id, processID: session.pid)
    }

    private func readPTY(_ session: Session) {
        guard !session.readEnded, !paused, !session.readArmed, let io = session.io else { return }
        session.readArmed = true
        io.read(offset: 0, length: BrokerProtocol.chunkLimit, queue: queue) { [weak self] done, data, error in
            guard let self, !session.readEnded else { return }
            if let data, !data.isEmpty { self.output(Data(data), from: session) }
            if error != 0 || (done && (data?.isEmpty ?? true)) {
                session.readArmed = false
                self.endReading(session)
            } else if done {
                session.readArmed = false
                self.readPTY(session)
            }
        }
    }

    private func output(_ data: Data, from session: Session) {
        rings[session.id]?.append(data)
        OutputBudget.enforce(&rings)
        if session.attached, client?.greeted == true { enqueue(BrokerFrame.stream(.output, sessionID: session.id, bytes: data)) }
        schedulePromptCheck(session)
    }

    private func write(_ bytes: Data, to session: Session) {
        guard session.waitStatus == nil, !session.readEnded, let io = session.io, !bytes.isEmpty, session.pendingInput + bytes.count <= Self.inputLimit else { return }
        session.pendingInput += bytes.count
        let payload = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        io.write(offset: 0, data: payload, queue: queue) { done, _, error in
            if done || error != 0 { session.pendingInput -= bytes.count }
        }
        schedulePromptCheck(session)
    }

    private func resize(_ session: Session, columns: UInt16, rows: UInt16) {
        guard columns > 0, rows > 0, !session.readEnded else { return }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(session.descriptor, TIOCSWINSZ, &size)
    }

    /// Echo off with canonical input on is a readpassphrase-style prompt, as in `PTYProcess`; coalesced to 100 ms.
    private func schedulePromptCheck(_ session: Session) {
        guard !session.promptCheckScheduled, !session.readEnded else { return }
        session.promptCheckScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self else { return }
            session.promptCheckScheduled = false
            guard !session.readEnded else { return }
            var modes = termios()
            let active = tcgetattr(session.descriptor, &modes) == 0 && modes.c_lflag & tcflag_t(ECHO) == 0 && modes.c_lflag & tcflag_t(ICANON) != 0
            guard active != session.promptActive else { return }
            session.promptActive = active
            if session.attached { self.reply(nil, .prompt(sessionID: session.id, active: active)) }
        }
    }

    private func reapAll() { for session in sessions.values where session.waitStatus == nil { reap(session) } }

    private func reap(_ session: Session?) {
        guard let session, session.waitStatus == nil else { return }
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(session.pid, &status, WNOHANG) } while result < 0 && errno == EINTR
        guard result == session.pid else { return }
        session.waitStatus = status
        session.exitSource?.cancel()
        session.exitSource = nil
        // A detached descendant can hold the PTY open; drain briefly, then let go.
        if !session.readEnded {
            let drain = DispatchWorkItem { [weak self] in self?.endReading(session) }
            session.drainTimer = drain
            queue.asyncAfter(deadline: .now() + .seconds(2), execute: drain)
        }
        finishIfReady(session)
    }

    private func endReading(_ session: Session) {
        guard !session.readEnded else { return }
        session.readEnded = true
        session.io?.close(flags: .stop)
        session.io = nil
        finishIfReady(session)
    }

    private func finishIfReady(_ session: Session) {
        guard !session.finished, session.readEnded, let status = session.waitStatus else { return }
        session.finished = true
        session.drainTimer?.cancel()
        session.drainTimer = nil
        if session.attached, client?.greeted == true { reply(nil, .exited(sessionID: session.id, waitStatus: status)) }
    }

    // MARK: Lifetime

    private func checkIdle() {
        core.update(runningSessions: sessions.values.filter { $0.waitStatus == nil }.count, now: now())
        if core.shouldExit(now: now()) { exitNow() }
    }

    /// SIGTERM or a `stopAll` frame: hang up every session we still own, then exit.
    private func stopEverything() {
        guard !stopping else { return }
        stopping = true
        for session in sessions.values where session.waitStatus == nil {
            if let identity = session.identity, identity.permitsSignal(current: Self.identity(session.pid), ownerPID: ownPID) { kill(-session.pid, SIGHUP) }
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in self?.exitNow() }
    }

    private func exitNow() {
        let path = configuration.socketPath
        if BrokerFiles.isOwnedSocket(path) {
            unlink(path)
            rmdir((path as NSString).deletingLastPathComponent)
        }
        exit(0)
    }

    /// `trellis-broker --socket <path> --client <app> [--idle-exit <seconds>]`.
    public static func main(arguments: [String]) -> Int32 {
        var limit = rlimit(rlim_cur: 0, rlim_max: 0)
        setrlimit(RLIMIT_CORE, &limit)
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard let socket = value("--socket"), let client = value("--client").flatMap(BrokerFiles.realPath) else { return 64 }
        let idle = value("--idle-exit").flatMap(TimeInterval.init).map { min(max($0, 1), 3600) } ?? 30
        let server = BrokerServer(configuration: Configuration(socketPath: socket, clientPath: client, idleExit: idle))
        do { try server.start() } catch { return 70 }
        withExtendedLifetime(server) { dispatchMain() }
    }
}
