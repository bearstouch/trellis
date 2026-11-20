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

/// What a remote broker writes for files dropped on the Files view (FR-RW20). Every request opens its folder without
/// following a link at its last component and works relative to it, so neither the folder nor the file is written through
/// a link. A file is written to a temporary name of the broker's user and moved into place whole.
public enum BrokerRemoteWrite {
    public enum Failure: String, Error, Sendable {
        case notAllowed = "NOT_ALLOWED", notFound = "NOT_FOUND", exists = "EXISTS", changed = "CHANGED", unwritable = "UNWRITABLE", noSpace = "NO_SPACE"
        case crossDevice = "CROSS_DEVICE"
    }

    /// One path component: not empty, `.` or `..`, no `/` or NUL, at most 255 bytes.
    public static func isName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// An upload's temporary name: the prefix and 16 lowercase hex digits, so a request can't name any other file.
    public static func isTemp(_ name: String) -> Bool {
        guard name.hasPrefix(BrokerProtocol.uploadTempPrefix) else { return false }
        let rest = name.utf8.dropFirst(BrokerProtocol.uploadTempPrefix.utf8.count)
        return rest.count == 16 && rest.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    static func failure(_ code: Int32) -> Failure {
        switch code {
        case ENOENT: .notFound
        case EEXIST, ENOTEMPTY: .exists
        case ENOSPC, EDQUOT, EFBIG: .noSpace
        case EXDEV: .crossDevice
        case ELOOP, ENOTDIR, EISDIR, EINVAL: .notAllowed
        default: .unwritable
        }
    }

    static func openFolder(_ path: String) -> Result<Int32, Failure> {
        guard BrokerRemoteBrowse.isNormalized(path) else { return .failure(.notAllowed) }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        return fd >= 0 ? .success(fd) : .failure(failure(errno))
    }

    static func withFolder<T>(_ path: String, _ body: (Int32) -> Result<T, Failure>) -> Result<T, Failure> {
        switch openFolder(path) {
        case .success(let fd):
            defer { systemClose(fd) }
            return body(fd)
        case .failure(let failure): return .failure(failure)
        }
    }

    /// Opens an upload's temporary file for writing: a regular file of `uid` with one link, never a link or a FIFO.
    static func openTemp(_ folder: Int32, _ temp: String, uid: uid_t) -> Result<(fd: Int32, size: Int64), Failure> {
        let fd = openat(folder, temp, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { return .failure(errno == ENOENT ? .notFound : .notAllowed) }
        var info = stat()
        guard fstat(fd, &info) == 0, BrokerFiles.kind(info.st_mode) == .file, info.st_uid == uid, info.st_nlink == 1 else { systemClose(fd); return .failure(.notAllowed) }
        return .success((fd, Int64(info.st_size)))
    }

    /// Creates an empty temporary file, mode 0600, in `directory`. `sweep` first removes this user's temporary files there
    /// older than a day, left by a broker that ended mid-upload.
    public static func begin(directory: String, sweep: Bool = false, uid: uid_t = geteuid(), now: Int64 = Int64(time(nil))) -> Result<String, Failure> {
        withFolder(directory) { folder in
            if sweep { sweepStale(folder, uid: uid, now: now) }
            for _ in 0..<4 {
                guard let hex = BrokerFiles.randomHex(8) else { return .failure(.unwritable) }
                let temp = BrokerProtocol.uploadTempPrefix + hex
                let fd = openat(folder, temp, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
                if fd >= 0 { systemClose(fd); return .success(temp) }
                guard errno == EEXIST else { return .failure(failure(errno)) }
            }
            return .failure(.unwritable)
        }
    }

    public static func write(directory: String, temp: String, offset: Int64, data: Data, uid: uid_t = geteuid()) -> Result<Void, Failure> {
        guard isTemp(temp), offset >= 0, data.count <= BrokerProtocol.fileChunkLimit else { return .failure(.notAllowed) }
        return withFolder(directory) { folder in
            switch openTemp(folder, temp, uid: uid) {
            case .failure(let failure): return .failure(failure)
            case .success(let file):
                defer { systemClose(file.fd) }
                var written = 0
                while written < data.count {
                    let n = data.withUnsafeBytes { pwrite(file.fd, $0.baseAddress! + written, $0.count - written, off_t(offset) + off_t(written)) }
                    if n > 0 { written += n } else if n < 0, errno == EINTR { continue } else { return .failure(failure(n < 0 ? errno : EIO)) }
                }
                return .success(())
            }
        }
    }

    /// Moves a complete temporary file to `name`. Without `replace` a taken name is `EXISTS` and the temporary file stays
    /// for another name; with it, a file or link of that name is replaced (never written through) and a folder never is.
    public static func finish(directory: String, temp: String, name: String, mode: Int, size: Int64, replace: Bool, uid: uid_t = geteuid()) -> Result<Void, Failure> {
        guard isTemp(temp), isName(name), !isTemp(name) else { return .failure(.notAllowed) }
        return withFolder(directory) { folder in
            switch openTemp(folder, temp, uid: uid) {
            case .failure(let failure): return .failure(failure)
            case .success(let file):
                defer { systemClose(file.fd) }
                guard file.size == size else { return .failure(.changed) }
                guard fsync(file.fd) == 0 else { return .failure(failure(errno)) }
                // Permission bits only: never setuid, setgid or sticky from another machine.
                guard fchmod(file.fd, mode_t(mode & 0o777)) == 0 else { return .failure(failure(errno)) }
            }
            if replace {
                var info = stat()
                if fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0, BrokerFiles.kind(info.st_mode) == .directory { return .failure(.notAllowed) }
                return renameat(folder, temp, folder, name) == 0 ? .success(()) : .failure(failure(errno))
            }
            let code = renameNoReplace(folder, temp, folder, name, linkable: true)
            return code == 0 ? .success(()) : .failure(failure(code))
        }
    }

    /// Removes an upload's temporary file if it is still this user's regular file.
    public static func abort(directory: String, temp: String, uid: uid_t = geteuid()) {
        guard isTemp(temp) else { return }
        _ = withFolder(directory) { folder -> Result<Void, Failure> in
            var info = stat()
            if fstatat(folder, temp, &info, AT_SYMLINK_NOFOLLOW) == 0, BrokerFiles.kind(info.st_mode) == .file, info.st_uid == uid { unlinkat(folder, temp, 0) }
            return .success(())
        }
    }

    public static func makeDirectory(_ path: String, mode: Int) -> Result<Void, Failure> {
        guard BrokerRemoteBrowse.isNormalized(path), path != "/" else { return .failure(.notAllowed) }
        let name = BrokerFiles.lastComponent(path)
        guard isName(name), !isTemp(name) else { return .failure(.notAllowed) }
        return withFolder(BrokerFiles.parent(path)) { folder in
            // The owner can always write into what it made, so the rest of the copy can follow.
            mkdirat(folder, name, mode_t(mode & 0o777) | 0o700) == 0 ? .success(()) : .failure(failure(errno))
        }
    }

    /// Moves an entry (a link moves as a link) to a name that is free; never into itself.
    public static func rename(from: String, to: String) -> Result<Void, Failure> {
        guard BrokerRemoteBrowse.isNormalized(from), BrokerRemoteBrowse.isNormalized(to), from != "/", to != "/", to != from, !to.hasPrefix(from + "/") else {
            return .failure(.notAllowed)
        }
        let source = BrokerFiles.lastComponent(from), target = BrokerFiles.lastComponent(to)
        guard isName(target), !isTemp(target) else { return .failure(.notAllowed) }
        return withFolder(BrokerFiles.parent(from)) { sourceFolder in
            withFolder(BrokerFiles.parent(to)) { targetFolder in
                let code = renameNoReplace(sourceFolder, source, targetFolder, target, linkable: false)
                return code == 0 ? .success(()) : .failure(failure(code))
            }
        }
    }

    /// 0 or an errno. Atomic where the system offers it; else a hard link (files only), else a check and a rename.
    static func renameNoReplace(_ fromFolder: Int32, _ from: String, _ toFolder: Int32, _ to: String, linkable: Bool) -> Int32 {
        let code = trellis_rename_noreplace(fromFolder, from, toFolder, to)
        guard [ENOSYS, EINVAL, ENOTSUP, EOPNOTSUPP].contains(code) else { return code }
        if linkable {
            if linkat(fromFolder, from, toFolder, to, 0) == 0 { unlinkat(fromFolder, from, 0); return 0 }
            if errno == EEXIST { return EEXIST }
        }
        var info = stat()
        if fstatat(toFolder, to, &info, AT_SYMLINK_NOFOLLOW) == 0 { return EEXIST }
        return renameat(fromFolder, from, toFolder, to) == 0 ? 0 : errno
    }

    static func sweepStale(_ folder: Int32, uid: uid_t, now: Int64) {
        let copy = dup(folder)
        guard copy >= 0 else { return }
        guard let listing = fdopendir(copy) else { systemClose(copy); return }
        var stale: [String] = []
        while let entry = readdir(listing) {
            guard let name = BrokerRemoteBrowse.name(of: entry), isTemp(name) else { continue }
            var info = stat()
            guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0, BrokerFiles.kind(info.st_mode) == .file, info.st_uid == uid else { continue }
            #if canImport(Darwin)
                let modified = Int64(info.st_mtimespec.tv_sec)
            #else
                let modified = Int64(info.st_mtim.tv_sec)
            #endif
            if now - modified > BrokerProtocol.uploadTempStaleAge { stale.append(name) }
        }
        closedir(listing)
        for name in stale { unlinkat(folder, name, 0) }
    }
}
