#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif
import TrellisPOSIX

/// Finds or starts the broker for one state directory: its socket lives in a fresh owner-only
/// directory under the per-user temporary folder, recorded in `<state>/broker.json`.
public struct BrokerLauncher: Sendable {
    public let stateDirectory: URL
    /// The bundled `trellis-broker`.
    public let helperPath: String
    /// This app's executable; the broker accepts only it as a client.
    public let clientPath: String
    public let runtimeRoot: URL
    public let idleExit: Int

    public init(stateDirectory: URL, helperPath: String, clientPath: String, runtimeRoot: URL = FileManager.default.temporaryDirectory, idleExit: Int = 30) {
        self.stateDirectory = stateDirectory; self.helperPath = helperPath; self.clientPath = clientPath; self.runtimeRoot = runtimeRoot; self.idleExit = idleExit
    }

    public var discoveryPath: String { stateDirectory.appendingPathComponent(BrokerProtocol.discoveryName).path }

    public static func currentExecutable() -> String? { BrokerFiles.executablePath(pid: getpid()) }

    public func discovery() -> BrokerDiscovery? {
        BrokerFiles.readOwnerFile(discoveryPath).flatMap { try? JSONDecoder().decode(BrokerDiscovery.self, from: $0) }
    }

    public func publish(socketPath: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(BrokerDiscovery(protocolVersion: BrokerProtocol.version, socketPath: socketPath)) else { return }
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = BrokerFiles.writeOwnerFile(data, to: discoveryPath)
    }

    public func removeDiscovery() { unlink(discoveryPath) }

    /// Starts a detached broker and waits up to two seconds for its socket; returns the socket path.
    public func spawn() throws(BrokerClientError) -> String {
        // An empty environment: nothing of the app's environment reaches the broker.
        try Self.spawnDetached(helperPath, runtimeRoot: runtimeRoot.path, environment: []) { socket in
            [helperPath, "--socket", socket, "--client", clientPath, "--idle-exit", String(idleExit)]
        }
    }

    /// Creates a fresh owner-only directory under `runtimeRoot`, starts `helper` detached with the arguments for its
    /// socket path, and waits up to two seconds for the socket. Shared with the remote bridge.
    public static func spawnDetached(_ helper: String, runtimeRoot: String, environment: [String], arguments: (String) -> [String]) throws(BrokerClientError) -> String {
        guard let suffix = BrokerFiles.randomHex(6) else { throw .unavailable }
        let directory = (runtimeRoot.hasSuffix("/") ? String(runtimeRoot.dropLast()) : runtimeRoot) + "/trellis-broker-" + suffix
        guard mkdir(directory, 0o700) == 0, BrokerFiles.isOwnerOnlyDirectory(directory) else { throw .unavailable }
        let socketPath = directory + "/s"
        guard socketPath.utf8.count <= BrokerFiles.socketPathLimit else { rmdir(directory); throw .unavailable }
        let argv = arguments(socketPath).map { strdup($0) }
        let envp = environment.map { strdup($0) }
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        let failure = helper.withCString { helper in
            (argv + [nil]).withUnsafeBufferPointer { argv in
                (envp + [nil]).withUnsafeBufferPointer { envp in
                    trellis_spawn_detached(helper, argv.baseAddress, envp.baseAddress)
                }
            }
        }
        guard failure == 0 else { rmdir(directory); throw .unavailable }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if BrokerFiles.isOwnedSocket(socketPath) { return socketPath }
            usleep(20_000)
        }
        throw .timedOut
    }
}
