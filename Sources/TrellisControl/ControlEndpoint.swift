import Darwin
import Foundation

/// Token-free discovery document published in the Application Support directory.
public struct ControlDiscovery: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1
    public let protocolVersion: Int
    public let instanceID: UUID
    public let socketPath: String
}

public enum ControlEndpointError: Error, Equatable, Sendable {
    case unsafeDirectory
    case unsafeSocket
    case pathTooLong
    /// A live instance already answers on the published socket.
    case anotherInstanceRunning
    case io(Int32)
}

/// Owner-only runtime directory, socket path, and discovery file handling.
/// Nothing here follows symlinks or touches files owned by another user.
public struct ControlEndpoint: Sendable {
    /// `sockaddr_un.sun_path` holds 104 bytes including the terminator.
    public static let socketPathLimit = 103
    public let discoveryURL: URL
    public let runtimeRoot: URL
    public let uid: uid_t

    public init(stateDirectory: URL, runtimeRoot: URL = FileManager.default.temporaryDirectory, uid: uid_t = geteuid()) {
        discoveryURL = stateDirectory.appendingPathComponent("control.json")
        self.runtimeRoot = runtimeRoot
        self.uid = uid
    }

    /// Directory must be a real directory owned by `uid` with no group/other access.
    public static func verifyOwnerOnlyDirectory(_ path: String, uid: uid_t) throws(ControlEndpointError) {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw .io(errno) }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == uid, info.st_mode & 0o077 == 0 else { throw .unsafeDirectory }
    }

    /// Endpoint must be a socket owned by `uid`, never a symlink or other file.
    public static func verifySocket(_ path: String, uid: uid_t) throws(ControlEndpointError) {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw .io(errno) }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == uid else { throw .unsafeSocket }
        try verifyOwnerOnlyDirectory((path as NSString).deletingLastPathComponent, uid: uid)
    }

    /// Clears a stale previous instance (only after proving nothing answers) and
    /// creates a fresh randomized owner-only directory for the new socket.
    public func prepare() throws(ControlEndpointError) -> (directory: String, socketPath: String) {
        if let previous = readDiscovery() {
            if Self.isLive(previous.socketPath) { throw .anotherInstanceRunning }
            removeStale(previous)
        }
        var bytes = [UInt8](repeating: 0, count: 6)
        arc4random_buf(&bytes, bytes.count)
        let directory = runtimeRoot.appendingPathComponent("trellis-" + bytes.map { String(format: "%02x", $0) }.joined()).path
        guard mkdir(directory, 0o700) == 0 else { throw .io(errno) }
        try Self.verifyOwnerOnlyDirectory(directory, uid: uid)
        let socketPath = directory + "/s"
        guard socketPath.utf8.count <= Self.socketPathLimit else {
            rmdir(directory)
            throw .pathTooLong
        }
        return (directory, socketPath)
    }

    public func publish(_ discovery: ControlDiscovery) throws(ControlEndpointError) {
        let directory = discoveryURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { throw .io(EIO) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(discovery) else { throw .io(EINVAL) }
        let temporary = directory.appendingPathComponent(".control.\(UUID().uuidString).tmp").path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw .io(errno) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == data.count, synced, rename(temporary, discoveryURL.path) == 0 else {
            let failure = errno
            unlink(temporary)
            throw .io(failure)
        }
    }

    /// Removes this instance's discovery file and runtime directory only.
    public func remove(_ discovery: ControlDiscovery) {
        if readDiscovery()?.instanceID == discovery.instanceID { unlink(discoveryURL.path) }
        removeRuntime(socketPath: discovery.socketPath)
    }

    public func readDiscovery() -> ControlDiscovery? {
        let fd = open(discoveryURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == uid, info.st_size <= 4096 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4097)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return try? JSONDecoder().decode(ControlDiscovery.self, from: Data(buffer.prefix(count)))
    }

    private func removeStale(_ previous: ControlDiscovery) {
        unlink(discoveryURL.path)
        removeRuntime(socketPath: previous.socketPath)
    }

    private func removeRuntime(socketPath: String) {
        // Only an owner-only directory of ours holding our socket is cleaned up.
        guard (try? Self.verifySocket(socketPath, uid: uid)) != nil else { return }
        unlink(socketPath)
        rmdir((socketPath as NSString).deletingLastPathComponent)
    }

    /// True when something accepts a connection at `path`.
    static func isLive(_ path: String) -> Bool {
        guard (try? verifySocket(path, uid: geteuid())) != nil else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard var address = unixAddress(path) else { return false }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
    }

    static func unixAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= socketPathLimit else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }
}
