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

/// What a remote broker reads for the Files view (FR-RW19): the names in a folder, and the bytes of a regular file the
/// user opened. Read-only; nothing here writes, follows a link into a folder or keeps what it read.
public enum BrokerRemoteBrowse {
    public struct Chunk: Equatable, Sendable {
        public let data: Data
        public let size: Int64
        public let modified: Int64
    }

    /// A normalized absolute path: no `.`, `..` or empty components, so what is asked for is what is opened.
    public static func isNormalized(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0") else { return false }
        if path == "/" { return true }
        return path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// The listings of up to `statLimit` folders, in order. Once the reply's estimated size passes `budget` the rest come
    /// back `deferred`, as does one that wouldn't fit in what is left of a frame; the first folder is always read.
    public static func list(
        _ paths: [String], entryLimit: Int = BrokerProtocol.directoryEntryLimit, budget: Int = BrokerProtocol.directoryReplyBudget, byteLimit: Int = BrokerProtocol.directoryReplyLimit
    ) -> [BrokerDirectoryListing]? {
        guard paths.count <= BrokerProtocol.statLimit, paths.allSatisfy(isNormalized) else { return nil }
        var used = 0
        return paths.enumerated().map { index, path in
            guard index == 0 || used < budget else { return BrokerDirectoryListing(path: path, state: .deferred) }
            let (listing, cutByBytes) = list(path, entryLimit: entryLimit, byteLimit: byteLimit - used)
            // Cut short only because earlier folders took the room: asked alone, it is read whole.
            if index > 0, cutByBytes { return BrokerDirectoryListing(path: path, state: .deferred) }
            used += listing.entries.reduce(64 + path.utf8.count) { $0 + cost($1) }
            return listing
        }
    }

    /// An entry's size in the reply as JSON writes it: a quote or backslash takes two bytes and a control character six,
    /// so a folder of such names is cut short like any other instead of outgrowing a frame.
    static func cost(_ entry: BrokerDirectoryEntry) -> Int {
        entry.name.utf8.reduce(32) { $0 + ($1 < 0x20 ? 6 : $1 == 0x22 || $1 == 0x5C ? 2 : 1) }
    }

    static func list(_ path: String, entryLimit: Int, byteLimit: Int) -> (listing: BrokerDirectoryListing, cutByBytes: Bool) {
        // `O_NOFOLLOW`: a folder that became a link since it was listed isn't followed.
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return (BrokerDirectoryListing(path: path, state: .unreadable), false) }
        guard let directory = fdopendir(fd) else { systemClose(fd); return (BrokerDirectoryListing(path: path, state: .unreadable), false) }
        defer { closedir(directory) }
        var entries: [BrokerDirectoryEntry] = [], used = 0, truncated = false, cutByBytes = false
        while let entry = readdir(directory) {
            // A name that isn't UTF-8 can't be sent as text or asked for again, so it is left out.
            guard let name = name(of: entry), name != ".", name != ".." else { continue }
            let item = BrokerDirectoryEntry(name: name, kind: kind(of: entry, name: name, in: fd))
            guard entries.count < entryLimit else { truncated = true; break }
            guard used + cost(item) <= byteLimit else { truncated = true; cutByBytes = true; break }
            entries.append(item)
            used += cost(item)
        }
        return (BrokerDirectoryListing(path: path, state: .ok, entries: entries, truncated: truncated), cutByBytes)
    }

    private static func name(of entry: UnsafeMutablePointer<dirent>) -> String? {
        withUnsafePointer(to: &entry.pointee.d_name) { tuple in
            tuple.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout.size(ofValue: tuple.pointee)) { bytes in
                String(bytes: UnsafeBufferPointer(start: bytes, count: strlen(UnsafeRawPointer(bytes).assumingMemoryBound(to: CChar.self))), encoding: .utf8)
            }
        }
    }

    /// The entry's own kind, from the folder when it says and `fstatat` (never following a link) when it doesn't.
    private static func kind(of entry: UnsafeMutablePointer<dirent>, name: String, in folder: Int32) -> BrokerDirectoryEntry.Kind {
        switch Int(entry.pointee.d_type) {
        case Int(DT_REG): return .file
        case Int(DT_DIR): return .directory
        case Int(DT_LNK): return .symlink
        case Int(DT_UNKNOWN): break
        default: return .other
        }
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return .other }
        switch BrokerFiles.kind(info.st_mode) {
        case .file: return .file
        case .directory: return .directory
        case .symlink: return .symlink
        case .socket, .other: return .other
        }
    }

    /// Up to `length` bytes (at most `fileChunkLimit`) of a regular file from `offset`. A link to a regular file is read,
    /// as an editor on the host would; a FIFO or device never blocks the broker: it is opened without waiting and refused.
    public static func read(_ path: String, offset: Int64, length: Int) -> Result<Chunk, BrokerRemoteFiles.Failure> {
        guard isNormalized(path), offset >= 0, length >= 0 else { return .failure(.notAllowed) }
        // Asked before it is opened: opening a device can itself do something (a tape rewinds, a watchdog starts), and
        // `O_NOCTTY` keeps a terminal swapped in since from becoming the broker's. What was opened is checked again.
        var info = stat()
        guard stat(path, &info) == 0 else { return .failure(errno == ENOENT || errno == ENOTDIR ? .notFound : .unreadable) }
        guard BrokerFiles.kind(info.st_mode) == .file else { return .failure(.notAllowed) }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { return .failure(errno == ENOENT || errno == ENOTDIR ? .notFound : .unreadable) }
        defer { systemClose(fd) }
        guard fstat(fd, &info) == 0 else { return .failure(.unreadable) }
        guard BrokerFiles.kind(info.st_mode) == .file else { return .failure(.notAllowed) }
        var buffer = [UInt8](repeating: 0, count: min(length, BrokerProtocol.fileChunkLimit))
        var count = 0
        while count < buffer.count {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + count, $0.count - count, off_t(offset) + off_t(count)) }
            if n > 0 { count += n } else if n < 0, errno == EINTR { continue } else if n < 0 { return .failure(.unreadable) } else { break }
        }
        #if canImport(Darwin)
            let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        #else
            let modified = Int64(info.st_mtim.tv_sec) * 1_000_000_000 + Int64(info.st_mtim.tv_nsec)
        #endif
        return .success(Chunk(data: Data(buffer.prefix(count)), size: Int64(info.st_size), modified: modified))
    }
}
