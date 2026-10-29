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

/// The broker's decisions, apart from its sockets and PTYs so they are unit-tested with an injected clock.
public struct BrokerCore: Sendable {
    /// Only the signals the app's close policy sends: hangup, graceful termination and explicit force.
    public static let allowedSignals: Set<Int32> = [SIGHUP, SIGTERM, SIGKILL]
    public let idleExit: TimeInterval
    public private(set) var clientConnected = false
    private var idleSince: Date?

    public init(idleExit: TimeInterval, now: Date) {
        self.idleExit = idleExit
        idleSince = now
    }

    /// One client at a time; a second connection is refused while the first is open.
    public mutating func acceptClient() -> Bool {
        guard !clientConnected else { return false }
        clientConnected = true
        return true
    }

    public mutating func clientDisconnected() { clientConnected = false }

    /// `protocolVersion` is the lowest version the client speaks and `maximumVersion` the highest (absent from v1
    /// clients). The broker answers with the highest version both speak. A v1 broker compares `protocolVersion` only,
    /// so a newer client that still speaks v1 keeps working with it.
    public static func negotiate(_ protocolVersion: Int, maximumVersion: Int?) -> Int? {
        let version = min(max(maximumVersion ?? protocolVersion, protocolVersion), BrokerProtocol.version)
        return version >= max(protocolVersion, BrokerProtocol.minimumVersion) ? version : nil
    }

    public static func hello(_ protocolVersion: Int, maximumVersion: Int? = nil, brokerPID: Int32, info: BrokerHostInfo? = nil) -> BrokerMessage {
        guard let version = negotiate(protocolVersion, maximumVersion: maximumVersion) else { return .refused(reason: "PROTOCOL_VERSION_MISMATCH") }
        return .welcome(protocolVersion: version, brokerPID: brokerPID, info: version >= 2 ? info : nil)
    }

    public static func permitsSignal(_ signal: Int32) -> Bool { allowedSignals.contains(signal) }

    /// Variables only Trellis sets (`LocalLaunchValidator` uses the same rule); a request never supplies them.
    public static func isControlKey(_ key: String) -> Bool {
        let name = key.uppercased()
        return name.hasPrefix("TRELLIS_") || name.hasPrefix("__TRELLIS_") || name.hasPrefix("UTERM_") || name.hasPrefix("__UTERM_")
    }

    /// Idle means nothing running and no client; the clock restarts whenever that stops being true.
    public mutating func update(runningSessions: Int, now: Date) {
        if runningSessions > 0 || clientConnected { idleSince = nil } else if idleSince == nil { idleSince = now }
    }

    public func shouldExit(now: Date) -> Bool {
        guard let idleSince else { return false }
        return now.timeIntervalSince(idleSince) >= idleExit
    }
}

/// The process identity a signal is checked against, read through `trellis_read_process_identity`.
public struct BrokerProcessIdentity: Equatable, Sendable {
    public let pid: Int32, parentPID: Int32, groupID: Int32, startedSeconds: UInt64, startedMicroseconds: UInt64
    public init(pid: Int32, parentPID: Int32, groupID: Int32, startedSeconds: UInt64, startedMicroseconds: UInt64) {
        self.pid = pid; self.parentPID = parentPID; self.groupID = groupID; self.startedSeconds = startedSeconds; self.startedMicroseconds = startedMicroseconds
    }
    /// Same rule as the app's `OwnedProcessIdentity`: our own unreaped group leader, never a reused PID.
    public func permitsSignal(current: Self?, ownerPID: Int32) -> Bool {
        pid > 0 && parentPID == ownerPID && groupID == pid && current == self
    }
}

/// Socket and file checks shared by the broker and the app. Nothing here follows symlinks.
public enum BrokerFiles {
    /// `sockaddr_un.sun_path` holds 104 bytes including the terminator.
    public static let socketPathLimit = 103

    public enum Kind: Equatable, Sendable { case file, directory, symlink, socket, other }

    /// The entry itself, never a symlink's target.
    public static func entry(_ path: String) -> (kind: Kind, uid: uid_t, mode: mode_t, size: Int64)? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (kind(info.st_mode), info.st_uid, info.st_mode, Int64(info.st_size))
    }

    static func kind(_ mode: mode_t) -> Kind {
        switch mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): .file
        case mode_t(S_IFDIR): .directory
        case mode_t(S_IFLNK): .symlink
        case mode_t(S_IFSOCK): .socket
        default: .other
        }
    }

    public static func isOwnerOnlyDirectory(_ path: String, uid: uid_t = geteuid()) -> Bool {
        guard let entry = entry(path) else { return false }
        return entry.kind == .directory && entry.uid == uid && entry.mode & 0o077 == 0
    }

    public static func isOwnedSocket(_ path: String, uid: uid_t = geteuid()) -> Bool {
        guard let entry = entry(path), entry.kind == .socket, entry.uid == uid else { return false }
        return isOwnerOnlyDirectory(parent(path), uid: uid)
    }

    /// The containing directory of an absolute path, without Foundation's path APIs (absent from FoundationEssentials).
    public static func parent(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return "." }
        return slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
    }

    public static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    public static func hex(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var text: [UInt8] = []
        for byte in bytes { text.append(digits[Int(byte >> 4)]); text.append(digits[Int(byte & 0xf)]) }
        return String(decoding: text, as: UTF8.self)
    }

    public static func randomHex(_ count: Int) -> String? {
        var bytes = [UInt8](repeating: 0, count: count)
        guard trellis_random_bytes(&bytes, count) == 0 else { return nil }
        return hex(bytes)
    }

    public static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= socketPathLimit else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// The symlink-resolved path, or nil when it doesn't exist.
    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(decoding: UnsafeRawBufferPointer(start: resolved, count: strlen(resolved)), as: UTF8.self)
    }

    /// A live process's resolved executable path.
    public static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = trellis_executable_path(pid, &buffer, buffer.count)
        guard length > 0 else { return nil }
        return realPath(String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    /// The connected peer's pid when it runs as `uid`; nil otherwise.
    public static func peerPID(_ fd: Int32, uid: uid_t = geteuid()) -> pid_t? {
        var peerUID: uid_t = 0, pid: pid_t = 0
        guard trellis_peer_credentials(fd, &peerUID, &pid) == 0, peerUID == uid, pid > 0 else { return nil }
        return pid
    }

    /// True when the peer is our user running exactly `executable` (resolved).
    public static func peerRuns(_ fd: Int32, executable: String) -> Bool {
        guard let path = peerExecutable(fd), let expected = realPath(executable) else { return false }
        return path == expected
    }

    /// The resolved executable of a peer running as our user.
    public static func peerExecutable(_ fd: Int32) -> String? { peerPID(fd).flatMap { executablePath(pid: $0) } }

    /// A connected, close-on-exec socket to `path`, or nil.
    public static func connect(_ path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = trellis_unix_socket()
        guard fd >= 0 else { return nil }
        guard preventSigPipe(fd) else { close(fd); return nil }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { systemConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { close(fd); return nil }
        return fd
    }

    /// Writes everything or fails; for small control writes on blocking descriptors.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = systemWrite(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { return false }
            }
            return true
        }
    }

    public static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = preventSigPipe(fd)
    }

    /// Must run before the socket can be disconnected: Darwin refuses `setsockopt` on a socket whose peer already
    /// closed, and a write to it would then raise SIGPIPE in the app (or the test runner) instead of failing.
    public static func preventSigPipe(_ fd: Int32) -> Bool { trellis_prevent_sigpipe(fd) == 0 }

    /// Reads a small owner-only regular file without following symlinks.
    public static func readOwnerFile(_ path: String, limit: Int = 4096) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_size <= limit else { return nil }
        var buffer = [UInt8](repeating: 0, count: limit + 1)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0, count <= limit else { return nil }
        return Data(buffer.prefix(count))
    }

    /// Owner-only atomic replace in the target's directory.
    public static func writeOwnerFile(_ data: Data, to path: String) -> Bool {
        let temporary = parent(path) + "/.broker.\(UUID().uuidString).tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == data.count, synced, rename(temporary, path) == 0 else { unlink(temporary); return false }
        return true
    }
}

// Module-qualified names differ between Darwin, Glibc and Musl; these keep call sites that shadow them portable.
private func systemConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 { connect(fd, address, length) }
func systemWrite(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int { write(fd, bytes, count) }
func systemClose(_ fd: Int32) { _ = close(fd) }
