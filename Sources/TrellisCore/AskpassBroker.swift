import Darwin
import Foundation
import TrellisAskpass

/// Answers `trellis-askpass` for ssh sessions of hosts with a saved password (FR-H08).
/// One owner-only AF_UNIX socket per app run; each session registers a random nonce
/// that is consumed by its first request, answered or not.
public final class AskpassBroker: @unchecked Sendable {
    public struct Registration: Sendable, Equatable {
        public let nonce: String
        public let socketPath: String
        /// Environment for the ssh process; contains no secret.
        public func environment(helper: String) -> [String: String] {
            ["SSH_ASKPASS": helper, "SSH_ASKPASS_REQUIRE": "force", AskpassProtocol.socketVariable: socketPath, AskpassProtocol.nonceVariable: nonce]
        }
    }

    private struct Entry {
        /// The pid of the session's spawned ssh, read when a request arrives.
        let parent: @Sendable () async -> Int32?
        let answer: @Sendable () async -> Data?
    }

    public static let helperName = AskpassProtocol.helperName
    public let helperPath: String
    private let uid = getuid()
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var listenFD: Int32 = -1
    private var directory: String?
    /// Test seam: the peer's executable and parent pid.
    var peerProcess: @Sendable (pid_t) -> (path: String, parent: pid_t)? = AskpassBroker.process

    public init(helperPath: String) { self.helperPath = (helperPath as NSString).resolvingSymlinksInPath }

    deinit { stop() }

    /// Starts the listener on first use. `answer` runs at most once.
    public func register(parent: @escaping @Sendable () async -> Int32?, answer: @escaping @Sendable () async -> Data?) -> Registration? {
        lock.withLock {
            guard let path = startLocked() else { return nil }
            let nonce = AskpassProtocol.makeNonce()
            entries[nonce] = Entry(parent: parent, answer: answer)
            return Registration(nonce: nonce, socketPath: path)
        }
    }

    public func unregister(_ registration: Registration) { _ = lock.withLock { entries.removeValue(forKey: registration.nonce) } }

    var registeredCount: Int { lock.withLock { entries.count } }

    public func stop() {
        let (fd, folder) = lock.withLock { () -> (Int32, String?) in
            defer { listenFD = -1; directory = nil; entries = [:] }
            return (listenFD, directory)
        }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        if let folder { unlink(folder + "/s"); rmdir(folder) }
    }

    private func startLocked() -> String? {
        if listenFD >= 0, let directory { return directory + "/s" }
        // The per-user temporary directory keeps the path short enough for sun_path.
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("trellis-askpass-\(AskpassProtocol.makeNonce().prefix(16))")
        guard mkdir(folder, 0o700) == 0 else { return nil }
        let path = folder + "/s"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard fd >= 0, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            if fd >= 0 { close(fd) }
            rmdir(folder)
            return nil
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes); raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd); unlink(path); rmdir(folder)
            return nil
        }
        listenFD = fd; directory = folder
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "Trellis askpass accept"
        thread.start()
        return path
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            let thread = Thread { [weak self] in
                self?.serve(client)
                close(client)
            }
            thread.name = "Trellis askpass connection"
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var peerUID: uid_t = 0, peerGID: gid_t = 0, peerPID: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == uid,
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &length) == 0, peerPID > 0
        else { return }
        var request = Data()
        var byte: UInt8 = 0
        while request.count < AskpassProtocol.requestLimit, request.last != 0x0A {
            let count = read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { break }
            request.append(byte)
        }
        // One-shot: a matching nonce is consumed before any check, so a refused or racing
        // request can never be retried into an answer.
        guard let nonce = AskpassProtocol.nonce(from: request), let entry = lock.withLock({ entries.removeValue(forKey: nonce) }) else {
            reply(fd, Data([AskpassProtocol.interactive]))
            return
        }
        let checkPeer = peerProcess
        let helperPath = helperPath, peer = peerPID
        var answer =
            Self.wait {
                guard let process = checkPeer(peer), process.path == helperPath, let parent = await entry.parent(), process.parent == parent else { return nil }
                return await entry.answer()
            } ?? Data()
        defer { answer.resetBytes(in: 0..<answer.count) }
        reply(fd, answer.isEmpty ? Data([AskpassProtocol.interactive]) : Data([AskpassProtocol.password]) + answer)
    }

    private func reply(_ fd: Int32, _ data: Data) {
        var data = data
        defer { data.resetBytes(in: 0..<data.count) }
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    static func process(_ pid: pid_t) -> (path: String, parent: pid_t)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
        return ((path as NSString).resolvingSymlinksInPath, pid_t(info.pbi_ppid))
    }

    /// Bridges a connection thread to async work, like `ControlServer`.
    private static func wait<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Task.detached {
            box.value = await work()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }
}
