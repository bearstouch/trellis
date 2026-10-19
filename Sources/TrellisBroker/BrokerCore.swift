import Darwin
import Foundation

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

    public static func hello(_ protocolVersion: Int, brokerPID: Int32) -> BrokerMessage {
        protocolVersion == BrokerProtocol.version
            ? .welcome(protocolVersion: BrokerProtocol.version, brokerPID: brokerPID)
            : .refused(reason: "PROTOCOL_VERSION_MISMATCH")
    }

    public static func permitsSignal(_ signal: Int32) -> Bool { allowedSignals.contains(signal) }

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

    public static func isOwnerOnlyDirectory(_ path: String, uid: uid_t = geteuid()) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR && info.st_uid == uid && info.st_mode & 0o077 == 0
    }

    public static func isOwnedSocket(_ path: String, uid: uid_t = geteuid()) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == uid else { return false }
        return isOwnerOnlyDirectory((path as NSString).deletingLastPathComponent, uid: uid)
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
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return realPath(String(decoding: buffer.prefix(Int(length)), as: UTF8.self))
    }

    /// The connected peer's pid when it runs as `uid`; nil otherwise.
    public static func peerPID(_ fd: Int32, uid: uid_t = geteuid()) -> pid_t? {
        var peerUID: uid_t = 0, peerGID: gid_t = 0, pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == uid, getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    /// True when the peer is our user running exactly `executable` (resolved).
    public static func peerRuns(_ fd: Int32, executable: String) -> Bool {
        guard let pid = peerPID(fd), let path = executablePath(pid: pid), let expected = realPath(executable) else { return false }
        return path == expected
    }

    public static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = preventSigPipe(fd)
    }

    /// Must run before the socket can be disconnected: Darwin refuses `setsockopt` on a socket whose peer already
    /// closed, and a write to it would then raise SIGPIPE in the app (or the test runner) instead of failing.
    public static func preventSigPipe(_ fd: Int32) -> Bool {
        var one: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

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
        let directory = (path as NSString).deletingLastPathComponent
        let temporary = directory + "/.broker.\(UUID().uuidString).tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == data.count, synced, rename(temporary, path) == 0 else { unlink(temporary); return false }
        return true
    }
}
