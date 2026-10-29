import Darwin
import Foundation
import TrellisBroker
import TrellisCore
import TrellisPOSIX

/// One ssh connection to a saved host's remote helper (FR-RW02, FR-RW03): `/usr/bin/ssh -T -e none [options] -- dest
/// <bootstrap>`, with ssh's stdin and stdout on a socket pair and its terminal on a PTY shown as `console`, so host-key,
/// password, passphrase and one-time-code prompts stay ssh's own. The bootstrap reports the platform, installs the
/// helper when allowed, then becomes `trellis-broker bridge`; from the sync line on, the socket carries the broker protocol.
@MainActor
public final class RemoteHostLink {
    public struct Request: Sendable {
        public var sshExecutable: String
        /// `SavedHost.sshOptions`.
        public var options: [String]
        public var destination: String
        public var environment: [String: String]
        public var clientID: String
        /// Automatic attempts never prompt (`BatchMode=yes`): a credential is never retried on its own.
        public var batch: Bool
        public init(sshExecutable: String, options: [String], destination: String, environment: [String: String], clientID: String, batch: Bool = false) {
            self.sshExecutable = sshExecutable; self.options = options; self.destination = destination; self.environment = environment
            self.clientID = clientID; self.batch = batch
        }
    }

    public enum Purpose: Sendable { case check, install, remove, bridge }
    public enum InstallPolicy: Sendable { case never, ask, always }

    public enum Failure: Error, Equatable, Sendable {
        case spawn(Int32)
        /// ssh ended before the helper answered; the console shows why.
        case exited(Int32?)
        case unsupported(String)
        case noChecksumTool
        /// This build has no helper for the host, or its file changed since it was bundled.
        case artifactUnavailable(String)
        case declined
        case remote(String)
        case incompatible
        case cancelled
        /// The connection went quiet or closed after it was established.
        case lost
    }

    public enum State: Equatable, Sendable { case idle, connecting, installing, connected, closed, failed(Failure) }

    public let request: Request
    public let catalog: RemoteArtifactCatalog
    /// ssh's own terminal. Shown when ssh writes to it, so prompts are answered where ssh asks them.
    public let console: NativeTerminal
    public private(set) var state = State.idle { didSet { if state != oldValue { onStateChanged?(state) } } }
    public private(set) var probe: RemoteProbe?
    public private(set) var connection: BrokerConnection?
    public private(set) var processID: Int32?
    public var onStateChanged: ((State) -> Void)?
    /// ssh wrote to its terminal: a prompt, a host-key warning or an error.
    public var onConsoleOutput: (() -> Void)?
    /// Asked before an install under `.ask` (FR-RW02); false or nil declines.
    public var confirmInstall: ((RemoteProbe, RemoteArtifact) async -> Bool)?
    public var heartbeatInterval: Duration = .seconds(15)
    /// Added to the request's environment at spawn: the askpass variables for a saved password (FR-H08).
    public var environmentOverrides: [String: String] = [:]

    private let nonce = RemoteClientIdentity.randomHex()
    private var channel: LinkChannel?
    private var heartbeat: Task<Void, Never>?

    public init(request: Request, catalog: RemoteArtifactCatalog) {
        self.request = request
        self.catalog = catalog
        console = NativeTerminal()
        console.onOutput = { [weak self] in self?.onConsoleOutput?() }
        console.onExit = { [weak self] code in self?.sshExited(code) }
    }

    /// The ssh argv: options precede `--`, so the destination is never parsed as one; no host-trust bypass is added.
    public var arguments: [String] {
        [request.sshExecutable, "-T", "-e", "none"] + (request.batch ? ["-o", "BatchMode=yes"] : []) + request.options
            + ["--", request.destination, RemoteBootstrap.command(nonce: nonce, clientID: request.clientID)]
    }

    /// One connection for `purpose`. `.bridge` leaves the link connected; the others end it. Returns the probe.
    public func run(_ purpose: Purpose, install policy: InstallPolicy) async -> Result<RemoteProbe, Failure> {
        guard state == .idle else { return .failure(.cancelled) }
        state = .connecting
        var result = await establish(purpose, policy: policy)
        // close() during the last await: never report (or stay) connected after the caller closed the link.
        if state == .closed { result = .failure(.cancelled) }
        switch result {
        case .success where purpose == .bridge: state = .connected
        case .success: finish(.closed)
        case .failure(let failure): finish(.failed(failure))
        }
        return result
    }

    private func establish(_ purpose: Purpose, policy: InstallPolicy) async -> Result<RemoteProbe, Failure> {
        let spawned = Self.spawn(arguments, environment: request.environment.merging(environmentOverrides) { $1 })
        guard spawned.error_code == 0 else { return .failure(.spawn(spawned.error_code)) }
        processID = spawned.pid
        _ = BrokerFiles.preventSigPipe(spawned.data_fd)
        let channel = LinkChannel(fd: spawned.data_fd, nonce: nonce)
        self.channel = channel
        let pty = PTYProcess()
        pty.prepareAttach(pid: spawned.pid, descriptor: spawned.console_fd)
        console.adopt(BrokerAdoption(sessionID: console.sessionID, processID: spawned.pid, exitCode: nil, nonce: nil, replay: Data(), transport: pty))

        guard case .probe(let probe) = await channel.reply() else { return .failure(failure(ended: true)) }
        self.probe = probe
        if purpose == .check { await channel.send(RemoteBootstrap.quitLine); return .success(probe) }
        if purpose == .remove {
            await channel.send(RemoteBootstrap.removeLine)
            guard case .removed = await channel.reply() else { return .failure(failure(ended: false)) }
            await channel.send(RemoteBootstrap.quitLine)
            return .success(probe)
        }
        guard let platform = probe.platform else { await channel.send(RemoteBootstrap.quitLine); return .failure(.unsupported(probe.displayName)) }
        guard let artifact = catalog.artifacts[platform] else { await channel.send(RemoteBootstrap.quitLine); return .failure(.artifactUnavailable(probe.displayName)) }
        if purpose == .install || !probe.installed.contains(artifact.directory) {
            guard probe.checksumTool != nil else { await channel.send(RemoteBootstrap.quitLine); return .failure(.noChecksumTool) }
            let allowed: Bool
            switch policy {
            case .never: allowed = false
            case .always: allowed = true
            case .ask: allowed = await confirmInstall?(probe, artifact) ?? false
            }
            guard allowed, state == .connecting else { await channel.send(RemoteBootstrap.quitLine); return .failure(.declined) }
            guard let payload = await Task.detached(priority: .userInitiated, operation: { RemoteArtifactCatalog.payload(artifact) }).value else {
                await channel.send(RemoteBootstrap.quitLine)
                return .failure(.artifactUnavailable(probe.displayName))
            }
            state = .installing
            // Nothing more is sent until the host acknowledges, so the upload can never swallow a later command.
            await channel.send(RemoteBootstrap.installLine(artifact), payload)
            guard case .installed(artifact.digest) = await channel.reply() else { return .failure(failure(ended: false)) }
            self.probe?.installed.insert(artifact.directory)
            state = .connecting
        }
        guard purpose == .bridge else { await channel.send(RemoteBootstrap.quitLine); return .success(self.probe ?? probe) }
        await channel.send(RemoteBootstrap.bridgeLine(digest: artifact.digest))
        guard await channel.awaitSync() else { return .failure(failure(ended: false)) }
        let fd = channel.takeDescriptor()
        guard fd >= 0 else { return .failure(failure(ended: true)) }
        BrokerFiles.configure(fd)
        let connection = BrokerConnection(fd: fd)
        self.connection = connection
        connection.onClose = { [weak self] in self?.connectionClosed() }
        do { try await connection.hello(minimumVersion: 2, clientID: request.clientID) } catch { return .failure(.incompatible) }
        startHeartbeat()
        return .success(self.probe ?? probe)
    }

    private func failure(ended: Bool) -> Failure {
        if case .failed(let failure) = state { return failure }
        if let message = channel?.lastError { return .remote(message) }
        return ended || console.exitCode != nil ? .exited(console.exitCode) : .lost
    }

    /// Ends the connection: ssh is asked to stop (SIGHUP, as for a pane), never anything on the host.
    public func close() { finish(.closed) }

    private func finish(_ final: State) {
        heartbeat?.cancel()
        heartbeat = nil
        channel?.cancel()
        channel = nil
        connection?.onClose = nil
        connection?.close()
        if console.isRunning { console.stop() }
        if case .failed = state {} else if state != .closed { state = final }
    }

    private func sshExited(_ code: Int32?) {
        channel?.cancel()
        if state == .connected { finish(.failed(.lost)) }
    }

    private func connectionClosed() {
        guard state == .connected else { return }
        finish(.failed(.lost))
    }

    /// A ping every interval; one unanswered within 10 s ends the link (FR-RW07 detects the loss).
    private func startHeartbeat() {
        heartbeat = Task { [weak self] in
            var sequence: UInt64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.heartbeatInterval ?? .seconds(15))
                guard let self, !Task.isCancelled, let connection = self.connection else { return }
                sequence &+= 1
                guard case .pong(sequence)? = try? await connection.request(.ping(sequence), timeout: .seconds(10)) else {
                    self.finish(.failed(.lost))
                    return
                }
            }
        }
    }

    private static func spawn(_ argv: [String], environment: [String: String]) -> trellis_link_result {
        let arguments = argv.map { strdup($0) }
        let variables = environment.keys.sorted().map { strdup("\($0)=\(environment[$0]!)") }
        defer { (arguments + variables).forEach { free($0) } }
        return argv[0].withCString { executable in
            (arguments + [nil]).withUnsafeBufferPointer { argv in
                (variables + [nil]).withUnsafeBufferPointer { envp in trellis_spawn_link(executable, argv.baseAddress, envp.baseAddress) }
            }
        }
    }

    isolated deinit {
        heartbeat?.cancel()
        channel?.cancel()
    }
}

/// The bootstrap's line protocol on the link socket, before the broker protocol starts. Blocking reads one byte at a time
/// (a few KiB in all), so nothing past the sync line is consumed; every call runs off the main actor and can be cancelled.
final class LinkChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    private var cancelled = false
    private let nonce: String
    private(set) var lastError: String?

    init(fd: Int32, nonce: String) { self.fd = fd; self.nonce = nonce }

    /// Wakes a blocked read or write at once. The descriptor is closed only in deinit, after every I/O task that holds
    /// this channel has returned: closing it here could let a concurrent read or upload hit a reused descriptor number.
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    /// Hands the socket to the broker connection; the channel no longer owns it. -1 once cancelled.
    func takeDescriptor() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let taken = cancelled ? -1 : fd
        if !cancelled { fd = -1 }
        return taken
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    private var descriptor: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return cancelled || fd < 0 ? nil : fd
    }

    /// The next reply addressed to this connection; login-script output is skipped up to `noiseLimit`.
    func reply() async -> RemoteBootstrap.Reply? {
        await Task.detached(priority: .userInitiated) { [self] in
            var skipped = 0
            while let line = readLine(), skipped <= RemoteBootstrap.noiseLimit {
                if let reply = RemoteBootstrap.reply(line[...], nonce: nonce) {
                    if case .error(let code) = reply { lastError = code }
                    return reply
                }
                skipped += line.utf8.count + 1
            }
            return nil
        }.value
    }

    /// The bridge's sync line; everything after it is the broker protocol.
    func awaitSync() async -> Bool {
        await Task.detached(priority: .userInitiated) { [self] in
            let marker = Array(("\n" + BrokerProtocol.syncPrefix + nonce + "\n").utf8)
            var tail: [UInt8] = [], line: [UInt8] = []
            for _ in 0..<(RemoteBootstrap.noiseLimit + marker.count) {
                guard let byte = readByte() else { return false }
                tail.append(byte)
                if tail.count > marker.count { tail.removeFirst() }
                if tail == marker { return true }
                guard byte == 0x0a else {
                    if line.count < 4096 { line.append(byte) }
                    continue
                }
                // A reply line here is the bootstrap failing before it could exec the bridge. The whole line is kept:
                // an error reply is longer than the sync marker.
                if case .error(let code)? = RemoteBootstrap.reply(Substring(String(decoding: line, as: UTF8.self)), nonce: nonce) {
                    lastError = code
                    return false
                }
                line.removeAll(keepingCapacity: true)
            }
            return false
        }.value
    }

    func send(_ text: String, _ payload: Data = Data()) async {
        await Task.detached(priority: .userInitiated) { [self] in
            guard let fd = descriptor else { return }
            _ = BrokerFiles.writeAll(fd, Data(text.utf8) + payload)
        }.value
    }

    private func readLine() -> String? {
        var bytes: [UInt8] = []
        while let byte = readByte() {
            if byte == 0x0a { return String(decoding: bytes, as: UTF8.self) }
            if bytes.count < 4096 { bytes.append(byte) }
        }
        return nil
    }

    private func readByte() -> UInt8? {
        while true {
            guard let fd = descriptor else { return nil }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 250)
            if ready < 0, errno != EINTR { return nil }
            guard ready > 0 else { continue }
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            if count == 1 { return byte }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            return nil
        }
    }
}
