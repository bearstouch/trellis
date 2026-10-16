import Darwin
import Foundation
import TrellisCore
import TrellisPOSIX

/// DispatchIO performs reads/writes off the main thread. Each bounded read must
/// finish delivery before the next read is armed; at most 16 KiB is queued for UI.
@MainActor
final class PTYProcess: LocalSessionTransport {
    private(set) var pid: pid_t = 0
    private(set) var descriptor: Int32 = -1
    private(set) var isRunning = false
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32?) -> Void)?
    var onInputError: ((Error) -> Void)?
    static let inputQueueLimit = 1_048_576
    private(set) var pendingInputCount = 0
    private var io: DispatchIO?
    private var monitor: DispatchSourceProcess?
    private var reapFallback: DispatchSourceTimer?
    private var reapedStatus: Int32?
    private var readEnded = false
    private var ioClosed = true
    private var exitReported = false
    private var preparing = false
    private var finalDrainTimer: Timer?
    private var generation = UUID()
    private let queue = DispatchQueue(label: "dev.trellis.pty", qos: .userInitiated)
    private let processExitNotifications: Bool
    private var launchIdentity: OwnedProcessIdentity?
    private let readIdentity: (Int32) -> OwnedProcessIdentity?
    private let signalProcessGroup: (Int32, Int32) -> Void

    // The fallback must remain sufficient even when the platform notification
    // path is unavailable. Tests disable that path to verify independent reaping.
    init(
        processExitNotifications: Bool = true,
        readIdentity: @escaping (Int32) -> OwnedProcessIdentity? = PTYProcess.identity,
        signalProcessGroup: @escaping (Int32, Int32) -> Void = { _ = kill(-$0, $1) }
    ) {
        self.processExitNotifications = processExitNotifications
        self.readIdentity = readIdentity
        self.signalProcessGroup = signalProcessGroup
    }

    nonisolated static func identity(_ pid: Int32) -> OwnedProcessIdentity? {
        let value = trellis_read_process_identity(pid)
        guard value.valid != 0 else { return nil }
        return OwnedProcessIdentity(
            pid: pid, parentPID: value.parent_pid, groupID: value.group_id,
            startedSeconds: value.started_seconds, startedMicroseconds: value.started_microseconds)
    }

    func launch(_ configuration: ValidatedLocalLaunch, size: TerminalSize) async throws -> Int32 {
        guard !preparing, !isRunning, ioClosed else { throw LocalLaunchError.alreadyStarted }
        preparing = true
        defer { preparing = false }
        let child = try await Task.detached(priority: .userInitiated) {
            try Self.spawn(configuration, size: size)
        }.value
        generation = UUID()
        let current = generation
        pid = child.pid
        launchIdentity = readIdentity(child.pid)
        descriptor = child.fd
        isRunning = true
        readEnded = false
        ioClosed = false
        exitReported = false
        reapedStatus = nil
        pendingInputCount = 0
        let channel = DispatchIO(type: .stream, fileDescriptor: child.fd, queue: queue) { @Sendable [weak self] _ in
            _ = Darwin.close(child.fd)
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.ioClosed = true
                self.finishIfReady()
            }
        }
        io = channel
        channel.setLimit(lowWater: 1)
        channel.setLimit(highWater: 16_384)
        if processExitNotifications {
            let exitSource = DispatchSource.makeProcessSource(identifier: child.pid, eventMask: .exit, queue: .main)
            exitSource.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reapChild() } }
            monitor = exitSource
            exitSource.activate()
        }
        // A process-source notification can precede a successful nonblocking
        // wait, or be deferred across native modal loops. Never make the only
        // opportunity to reap our child depend on that one notification.
        let reaper = DispatchSource.makeTimerSource(queue: .main)
        reaper.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(50))
        reaper.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reapChild() } }
        reapFallback = reaper
        reaper.activate()
        readNext()
        reapChild()  // also handles a child that exited before the monitor armed
        return child.pid
    }

    // Compatibility for the isolated S001 fixtures; production uses validated launch.
    func start(executable: String, arguments: [String], environment: [String], directory: String, size: winsize) async throws {
        let pairs = environment.map { $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init) }
        let values = Dictionary(pairs.filter { $0.count == 2 }.map { ($0[0], $0[1]) }, uniquingKeysWith: { _, last in last })
        let launch = try LocalLaunchValidator().validate(LocalLaunchConfiguration(executable: executable, arguments: arguments, directory: directory, inheritedEnvironment: values))
        _ = try await self.launch(launch, size: TerminalSize(columns: Int(size.ws_col), rows: Int(size.ws_row)))
    }

    private nonisolated static func spawn(_ configuration: ValidatedLocalLaunch, size: TerminalSize) throws -> (pid: Int32, fd: Int32) {
        let arguments = ([configuration.executable] + configuration.arguments).map { strdup($0) }
        let environment = configuration.environmentArray.map { strdup($0) }
        defer { (arguments + environment).forEach { free($0) } }
        guard arguments.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else {
            throw LocalLaunchError.spawnFailed(ENOMEM)
        }
        let result = configuration.executable.withCString { executable in
            configuration.directory.withCString { directory in
                (arguments + [nil]).withUnsafeBufferPointer { argv in
                    (environment + [nil]).withUnsafeBufferPointer { envp in
                        trellis_spawn_pty(executable, argv.baseAddress, envp.baseAddress, directory, UInt16(size.columns), UInt16(size.rows))
                    }
                }
            }
        }
        guard result.error_code == 0 else { throw LocalLaunchError.spawnFailed(result.error_code) }
        return (result.pid, result.master_fd)
    }

    func send(_ data: Data) throws {
        guard isRunning, !readEnded, let io else { throw TerminalAdapterError.inputClosed }
        guard data.count <= Self.inputQueueLimit - pendingInputCount else { throw TerminalAdapterError.inputQueueFull }
        guard !data.isEmpty else { return }
        pendingInputCount += data.count
        let payload = data.withUnsafeBytes { DispatchData(bytes: $0) }
        let receipt = WriteReceipt()
        let current = generation
        io.write(offset: 0, data: payload, queue: .main) { [weak self] done, _, error in
            MainActor.assumeIsolated {
                guard let self, self.generation == current, !receipt.finished, done || error != 0 else { return }
                receipt.finished = true
                self.pendingInputCount = max(0, self.pendingInputCount - data.count)
                if error != 0 { self.onInputError?(TerminalAdapterError.inputFailed(error)) }
            }
        }
    }

    func resize(_ size: TerminalSize) {
        guard descriptor >= 0, !readEnded else { return }
        var dimensions = winsize(ws_row: UInt16(size.rows), ws_col: UInt16(size.columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(descriptor, TIOCSWINSZ, &dimensions)
    }

    func signalGroup(_ signal: Int32) {
        reapChild()
        guard isRunning, let identity = launchIdentity,
            identity.permitsSignal(current: readIdentity(pid), ownerPID: getpid())
        else { return }
        signalProcessGroup(pid, signal)
    }

    private func readNext() {
        guard !readEnded, let io else { return }
        let current = generation
        io.read(offset: 0, length: 16_384, queue: .main) { [weak self] done, data, error in
            MainActor.assumeIsolated {
                guard let self, self.generation == current, !self.readEnded else { return }
                if let data, !data.isEmpty { self.onOutput?(Data(data)) }
                if error != 0 || (done && (data?.isEmpty ?? true)) {
                    self.endReading()
                } else if done {
                    self.readNext()
                }
            }
        }
    }

    private func reapChild() {
        guard isRunning else { return }
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, WNOHANG) } while result < 0 && errno == EINTR
        if result == 0 { return }
        guard result == pid else { return }
        isRunning = false
        reapedStatus = status
        monitor?.cancel()
        monitor = nil
        reapFallback?.cancel()
        reapFallback = nil
        // A detached descendant can keep a slave open after the owner exits.
        // Allow final data to drain, then release our I/O instead of waiting forever.
        if !readEnded {
            finalDrainTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.endReading() }
            }
        }
        finishIfReady()
    }

    private func endReading() {
        guard !readEnded else { return }
        readEnded = true
        descriptor = -1
        io?.close(flags: .stop)
        io = nil
    }

    private func finishIfReady() {
        guard !exitReported, ioClosed, let status = reapedStatus else { return }
        exitReported = true
        finalDrainTimer?.invalidate()
        finalDrainTimer = nil
        pid = 0
        pendingInputCount = 0
        onExit?((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
    }

    isolated deinit {
        reapFallback?.cancel()
        finalDrainTimer?.invalidate()
        monitor?.cancel()
        io?.close(flags: .stop)
        if isRunning, pid > 0 {
            let child = pid
            // Confirm this remains our unreaped child before checking identity.
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(child, &status, WNOHANG) } while result < 0 && errno == EINTR
            if result == 0, let identity = launchIdentity, identity.permitsSignal(current: readIdentity(child), ownerPID: getpid()) {
                signalProcessGroup(child, SIGKILL)
            }
            if result == 0 {
                DispatchQueue.global().async {
                    var status: Int32 = 0
                    while waitpid(child, &status, 0) < 0 && errno == EINTR {}
                }
            }
        }
    }
}

@MainActor
private final class WriteReceipt { var finished = false }
