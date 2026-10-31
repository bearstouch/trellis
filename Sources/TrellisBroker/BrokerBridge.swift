#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import Dispatch
#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// `trellis-broker bridge`, run by ssh on a remote host (FR-RW03): finds or starts this Mac's remote broker, prints the
/// sync line, then copies ssh's stdin to the broker socket and the socket to stdout until either side closes.
/// Blocking copies through one 64 KiB buffer per direction keep the broker's backpressure intact.
public enum BrokerBridge {
    public static let runDirectoryName = "run"

    public struct Layout: Equatable, Sendable {
        /// `~/.trellis/remote`: every installed helper version lives in a subdirectory.
        public var installRoot: String
        /// `~/.trellis/run/<client-id>`: discovery file and lock.
        public var runDirectory: String
        public init(home: String, clientID: String, installRoot: String? = nil) {
            let base = (home == "/" ? "" : home) + "/.trellis"
            self.installRoot = installRoot ?? base + "/remote"
            runDirectory = base + "/" + BrokerBridge.runDirectoryName + "/" + clientID
        }
        public var discoveryPath: String { runDirectory + "/" + BrokerProtocol.discoveryName }
    }

    public static func isValidClientID(_ value: String) -> Bool { value.utf8.count == 32 && value.utf8.allSatisfy(isLowerHex) }
    public static func isValidSyncToken(_ value: String) -> Bool { (16...64).contains(value.utf8.count) && value.utf8.allSatisfy(isLowerHex) }
    private static func isLowerHex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (97...102).contains(byte) }

    /// `trellis-broker bridge --client-id <hex32> --sync <hex> [--install-root <dir>] [--idle-exit <seconds>]`.
    public static func main(arguments: [String]) -> Int32 {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard let clientID = value("--client-id"), isValidClientID(clientID), let sync = value("--sync"), isValidSyncToken(sync) else {
            return fail("invalid arguments", code: 64)
        }
        let idle = value("--idle-exit").flatMap(Int.init).map { min(max($0, 1), 3600) } ?? 30
        let account = BrokerHost.account()
        let layout = Layout(home: account.home, clientID: clientID, installRoot: value("--install-root"))
        guard let me = BrokerFiles.executablePath(pid: getpid()), let root = prepareInstallRoot(layout.installRoot), me.hasPrefix(root + "/") else {
            return fail("the helper must run from \(layout.installRoot), inside an owner-only (chmod 700) ~/.trellis", code: 69)
        }
        let fd: Int32
        switch connect(layout: layout, root: root, helper: me, clientID: clientID, idle: idle) {
        case .success(let socket): fd = socket
        case .failure(let message): return fail(message, code: 69)
        }
        // ssh may hand over non-blocking stdio; the copies below rely on blocking reads and writes.
        for descriptor: Int32 in [0, 1] { _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK) }
        guard BrokerFiles.writeAll(1, Data(("\n" + BrokerProtocol.syncPrefix + sync + "\n").utf8)) else { return 74 }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            copy(from: 0, to: fd); done.signal()
        }
        DispatchQueue.global().async {
            copy(from: fd, to: 1); done.signal()
        }
        done.wait()
        return 0
    }

    enum Connection { case success(Int32), failure(String) }

    /// Under the run directory's lock, so two bridges never start two brokers for one client.
    static func connect(layout: Layout, root: String, helper: String, clientID: String, idle: Int) -> Connection {
        guard ensureOwnerOnlyDirectory(BrokerFiles.parent(BrokerFiles.parent(layout.runDirectory))), ensureOwnerOnlyDirectory(BrokerFiles.parent(layout.runDirectory)),
            ensureOwnerOnlyDirectory(layout.runDirectory)
        else { return .failure("cannot create \(layout.runDirectory)") }
        let lock = open(layout.runDirectory + "/lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { return .failure("cannot lock \(layout.runDirectory)") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { return .failure("cannot lock \(layout.runDirectory)") }
        if let fd = existing(layout: layout, root: root) { return .success(fd) }
        let environment = ProcessInfo.processInfo.environment.filter { !BrokerCore.isControlKey($0.key) }.map { "\($0.key)=\($0.value)" }.sorted()
        let socket: String
        do {
            socket = try BrokerLauncher.spawnDetached(helper, runtimeRoot: runtimeRoot(), environment: environment) { socket in
                [helper, "remote-broker", "--socket", socket, "--client-id", clientID, "--install-root", root, "--idle-exit", String(idle)]
            }
        } catch { return .failure("cannot start the remote broker") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(BrokerDiscovery(protocolVersion: BrokerProtocol.version, socketPath: socket, executable: helper)),
            BrokerFiles.writeOwnerFile(data, to: layout.discoveryPath), let fd = BrokerFiles.connect(socket)
        else { return .failure("cannot reach the remote broker") }
        guard BrokerFiles.peerExecutable(fd) == helper else { close(fd); return .failure("the remote broker is not trusted") }
        return .success(fd)
    }

    /// The recorded broker when it is alive and runs a helper installed under `root` (any version, FR-RW14).
    static func existing(layout: Layout, root: String) -> Int32? {
        guard let data = BrokerFiles.readOwnerFile(layout.discoveryPath), let discovery = try? JSONDecoder().decode(BrokerDiscovery.self, from: data),
            let executable = discovery.executable, executable.hasPrefix(root + "/"), BrokerFiles.isOwnedSocket(discovery.socketPath),
            let fd = BrokerFiles.connect(discovery.socketPath)
        else { return nil }
        guard BrokerFiles.peerExecutable(fd) == executable else { close(fd); return nil }
        return fd
    }

    /// The resolved install root; it must be an owner-only directory of ours.
    static func prepareInstallRoot(_ path: String) -> String? {
        guard ensureOwnerOnlyDirectory(BrokerFiles.parent(path)), ensureOwnerOnlyDirectory(path) else { return nil }
        return BrokerFiles.realPath(path)
    }

    /// Creates the directory 0700 when missing. An existing one must already be an owner-only directory of ours (never
    /// a symlink): permissions the user chose are never changed.
    static func ensureOwnerOnlyDirectory(_ path: String) -> Bool {
        if BrokerFiles.entry(path) == nil, mkdir(path, 0o700) != 0, errno != EEXIST { return false }
        return BrokerFiles.isOwnerOnlyDirectory(path)
    }

    /// `$TMPDIR` when it is an absolute directory short enough for a socket path, otherwise `/tmp`.
    static func runtimeRoot() -> String {
        if let directory = ProcessInfo.processInfo.environment["TMPDIR"], directory.hasPrefix("/"), directory.utf8.count <= 64,
            BrokerFiles.entry(directory)?.kind == .directory
        {
            return directory
        }
        return "/tmp"
    }

    static func copy(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: BrokerProtocol.chunkLimit)
        while true {
            let count = buffer.withUnsafeMutableBytes { Glue.read(source, $0.baseAddress!, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0, BrokerFiles.writeAll(destination, Data(buffer.prefix(count))) else { return }
        }
    }

    /// Shown in the app's connection console (ssh's stderr); never contains terminal data.
    static func fail(_ message: String, code: Int32) -> Int32 {
        BrokerFiles.writeAll(2, Data("trellis-broker: \(message)\n".utf8))
        return code
    }
}
