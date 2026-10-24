import Darwin
import Foundation

/// The open descriptor owns the lock. Process exit releases it, including crashes.
public final class ApplicationInstanceLock {
    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    public enum Acquisition {
        case acquired(ApplicationInstanceLock)
        case alreadyRunning(pid_t?)
    }

    public static let workspaceLockName = "instance.lock"

    /// One app per workspace folder however its path is spelled (a link, `/tmp` vs `/private/tmp`, or the default
    /// folder passed as `--state-directory`): the lock lives in the folder itself, created owner-only if missing.
    public static func acquire(stateDirectory: URL) throws -> Acquisition {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try acquire(at: stateDirectory.appendingPathComponent(workspaceLockName))
    }

    public static func acquire(at url: URL) throws -> Acquisition {
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var retained = false
        defer { if !retained { close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
            throw POSIXError(.EPERM)
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            var bytes = [UInt8](repeating: 0, count: 32)
            let count = pread(fd, &bytes, bytes.count, 0)
            let pid = count > 0 ? Int32(String(decoding: bytes.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) : nil
            return .alreadyRunning(pid.flatMap { $0 > 0 ? $0 : nil })
        }
        guard fchmod(fd, 0o600) == 0, ftruncate(fd, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let bytes = Array("\(getpid())\n".utf8)
        let written = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        guard written == bytes.count else { throw POSIXError(.EIO) }
        retained = true
        return .acquired(ApplicationInstanceLock(descriptor: fd))
    }
}
