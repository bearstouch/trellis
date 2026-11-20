import Darwin
import Foundation

/// This Mac's side of a copy (FR-FB10–FR-FB14): reads without following links, writes to a temporary name in the target
/// folder (owner-only while written) and moves it into place whole, as the helper does on a host (FR-RW20).
public struct LocalTransferEndpoint: TransferSource, TransferDestination {
    public init() {}

    public var movesReplace: Bool { true }
    public var makesLinks: Bool { true }

    static func failure(_ code: Int32) -> FileTransferFailure {
        switch code {
        case ENOENT: .missing
        case EEXIST, ENOTEMPTY: .exists
        case ENOSPC, EDQUOT, EFBIG: .noSpace
        case EXDEV: .crossDevice
        case EACCES, EPERM, EROFS: .unwritable
        default: .notAllowed
        }
    }

    static func join(_ folder: String, _ name: String) -> String { folder == "/" ? "/" + name : folder + "/" + name }

    static func item(_ path: String) -> TransferItem? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let kind: TransferItemKind =
            switch info.st_mode & S_IFMT {
            case S_IFREG: .file
            case S_IFDIR: .directory
            case S_IFLNK: .symlink
            default: .other
            }
        let target = kind == .symlink ? try? FileManager.default.destinationOfSymbolicLink(atPath: path) : nil
        return TransferItem(path: path, kind: kind, size: Int64(info.st_size), mode: Int(info.st_mode & 0o777), linkTarget: target)
    }

    // MARK: Source

    public func describe(_ paths: [String]) async throws(FileTransferFailure) -> [TransferItem] { paths.compactMap(Self.item) }

    public func children(of folder: String) async throws(FileTransferFailure) -> [TransferItem] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { throw .unreadable }
        return names.sorted().compactMap { Self.item(Self.join(folder, $0)) }
    }

    public func read(_ path: String, offset: Int64, length: Int) async throws(FileTransferFailure) -> TransferChunk {
        // A FIFO or device swapped in since it was listed never blocks: opened without waiting and refused.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ENOENT ? .missing : .unreadable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw .notAllowed }
        var buffer = [UInt8](repeating: 0, count: max(0, length))
        var count = 0
        while count < buffer.count {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + count, $0.count - count, off_t(offset) + off_t(count)) }
            if n > 0 { count += n } else if n < 0, errno == EINTR { continue } else if n < 0 { throw .unreadable } else { break }
        }
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return TransferChunk(data: Data(buffer.prefix(count)), size: Int64(info.st_size), modified: modified)
    }

    // MARK: Destination

    public func existing(in folder: String) async throws(FileTransferFailure) -> [String: TransferItemKind] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { throw .unwritable }
        return Dictionary(names.compactMap { name in Self.item(Self.join(folder, name)).map { (name, $0.kind) } }, uniquingKeysWith: { first, _ in first })
    }

    public func makeDirectory(_ path: String, mode: Int) async throws(FileTransferFailure) {
        guard mkdir(path, mode_t(mode & 0o777) | 0o700) == 0 else { throw Self.failure(errno) }
    }

    public func begin(in folder: String) async throws(FileTransferFailure) -> String {
        for _ in 0..<4 {
            let temp = ".trellis-upload-" + (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            let fd = open(Self.join(folder, temp), O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd >= 0 { close(fd); return temp }
            guard errno == EEXIST else { throw Self.failure(errno) }
        }
        throw .unwritable
    }

    private func openTemp(_ temp: String, in folder: String) throws(FileTransferFailure) -> Int32 {
        let fd = open(Self.join(folder, temp), O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure(errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { close(fd); throw .notAllowed }
        return fd
    }

    public func write(_ temp: String, in folder: String, offset: Int64, data: Data) async throws(FileTransferFailure) {
        let fd = try openTemp(temp, in: folder)
        defer { close(fd) }
        var written = 0
        while written < data.count {
            let n = data.withUnsafeBytes { pwrite(fd, $0.baseAddress! + written, $0.count - written, off_t(offset) + off_t(written)) }
            if n > 0 { written += n } else if n < 0, errno == EINTR { continue } else { throw Self.failure(n < 0 ? errno : EIO) }
        }
    }

    public func copyLocalFile(_ source: String, into temp: String, in folder: String) async throws(FileTransferFailure) -> Int64? {
        // Data and extended attributes (tags, quarantine), as Finder copies them; the mode is set when it is finished.
        guard copyfile(source, Self.join(folder, temp), nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_XATTR | COPYFILE_NOFOLLOW_SRC)) == 0 else {
            throw errno == ENOENT ? .missing : Self.failure(errno)
        }
        var info = stat()
        guard lstat(Self.join(folder, temp), &info) == 0 else { throw .unwritable }
        return Int64(info.st_size)
    }

    public func finish(_ temp: String, in folder: String, name: String, mode: Int, size: Int64, replace: Bool) async throws(FileTransferFailure) {
        let fd = try openTemp(temp, in: folder)
        var info = stat()
        let complete = fstat(fd, &info) == 0 && Int64(info.st_size) == size
        let settled = complete && fsync(fd) == 0 && fchmod(fd, mode_t(mode & 0o777)) == 0
        let code = errno
        close(fd)
        guard complete else { throw .changed }
        guard settled else { throw Self.failure(code) }
        try Self.rename(Self.join(folder, temp), to: Self.join(folder, name), replace: replace)
    }

    /// Replaces a file or link, never a folder; without `replace`, refuses a taken name atomically.
    static func rename(_ from: String, to: String, replace: Bool) throws(FileTransferFailure) {
        if replace {
            if item(to)?.kind == .directory { throw .notAllowed }
            guard Darwin.rename(from, to) == 0 else { throw failure(errno) }
            return
        }
        guard renamex_np(from, to, UInt32(RENAME_EXCL)) != 0 else { return }
        let code = errno
        guard [ENOTSUP, EINVAL].contains(code) else { throw failure(code) }
        // A file system that can't refuse atomically.
        guard item(to) == nil else { throw .exists }
        guard Darwin.rename(from, to) == 0 else { throw failure(errno) }
    }

    public func abort(_ temp: String, in folder: String) async {
        guard temp.hasPrefix(".trellis-upload-") else { return }
        unlink(Self.join(folder, temp))
    }

    public func move(_ path: String, to target: String, replace: Bool) async throws(FileTransferFailure) {
        do throws(FileTransferFailure) {
            try Self.rename(path, to: target, replace: replace)
        } catch .crossDevice {
            try Self.moveAcrossVolumes(path, to: target, replace: replace)
        }
    }

    /// Another volume: copied whole under a temporary name beside the target, then moved over it in one step, and only
    /// then is the original removed. A failure at any point leaves both the original and what the target held.
    static func moveAcrossVolumes(_ path: String, to target: String, replace: Bool) throws(FileTransferFailure) {
        let folder = (target as NSString).deletingLastPathComponent
        let temp = join(folder.isEmpty ? "/" : folder, ".trellis-upload-" + (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined())
        do { try FileManager.default.copyItem(atPath: path, toPath: temp) } catch {
            try? FileManager.default.removeItem(atPath: temp)
            throw item(path) == nil ? .missing : .unwritable
        }
        do throws(FileTransferFailure) { try rename(temp, to: target, replace: replace) } catch {
            try? FileManager.default.removeItem(atPath: temp)
            throw error
        }
        // The copy is in place; an original that can't be removed is left, so nothing is lost.
        try? FileManager.default.removeItem(atPath: path)
    }

    private func item(_ path: String) -> TransferItem? { Self.item(path) }

    public func makeLink(_ path: String, target: String, replace: Bool) async throws(FileTransferFailure) {
        if replace, let existing = item(path), existing.kind != .directory { unlink(path) }
        guard symlink(target, path) == 0 else { throw Self.failure(errno) }
    }

    public func removeEmptyFolder(_ path: String) async { rmdir(path) }
}
