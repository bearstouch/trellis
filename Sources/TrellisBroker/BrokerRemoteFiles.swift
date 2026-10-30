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

/// The only files a remote broker reads for the app (FR-RW11, FR-RW12): the task file, and the
/// manifests task detection reads. Never a symlink, never another user's file, never more than `remoteFileLimit`.
public enum BrokerRemoteFiles {
    public static let taskFiles: Set<String> = ["launch.json"]
    public static let manifests: Set<String> = ["package.json", "GNUmakefile", "makefile", "Makefile", "CMakeLists.txt", "pyproject.toml", "setup.cfg", "tox.ini", "Cargo.toml"]

    public enum Failure: String, Error, Sendable { case notAllowed = "NOT_ALLOWED", notFound = "NOT_FOUND", tooLarge = "TOO_LARGE", unreadable = "UNREADABLE" }

    /// A normalized absolute path (no `.`, `..` or empty components) whose name is allow-listed.
    public static func isAllowed(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard components.count >= 2, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        let name = String(components.last!), folder = components[components.endIndex - 2]
        return folder == ".trellis" ? taskFiles.contains(name) : manifests.contains(name)
    }

    public static func read(_ path: String, limit: Int, uid: uid_t = geteuid()) -> Result<Data, Failure> {
        guard isAllowed(path) else { return .failure(.notAllowed) }
        let limit = min(max(limit, 0), BrokerProtocol.remoteFileLimit)
        // A `.trellis` folder that is a symlink, or isn't ours, could point anywhere.
        // The `.trellis` folder is opened without following a symlink and the file is opened inside it, so the folder
        // can't be swapped for a link between the check and the open.
        let folder = BrokerFiles.parent(path)
        var folderFD: Int32 = -1
        if BrokerFiles.lastComponent(folder) == ".trellis" {
            folderFD = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard folderFD >= 0 else { return .failure(errno == ENOENT ? .notFound : .notAllowed) }
            var info = stat()
            guard fstat(folderFD, &info) == 0, BrokerFiles.kind(info.st_mode) == .directory, info.st_uid == uid else { close(folderFD); return .failure(.notAllowed) }
        }
        defer { if folderFD >= 0 { close(folderFD) } }
        let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        let fd = folderFD >= 0 ? openat(folderFD, BrokerFiles.lastComponent(path), flags) : open(path, flags)
        guard fd >= 0 else { return .failure(errno == ENOENT ? .notFound : (errno == ELOOP ? .notAllowed : .unreadable)) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failure(.unreadable) }
        guard BrokerFiles.kind(info.st_mode) == .file, info.st_uid == uid else { return .failure(.notAllowed) }
        guard Int64(info.st_size) <= Int64(limit) else { return .failure(.tooLarge) }
        var buffer = [UInt8](repeating: 0, count: limit + 1)
        var count = 0
        while count < buffer.count {
            let n = buffer.withUnsafeMutableBytes { Glue.read(fd, $0.baseAddress! + count, $0.count - count) }
            if n > 0 { count += n } else if n < 0, errno == EINTR { continue } else if n < 0 { return .failure(.unreadable) } else { break }
        }
        // The file grew after `fstat`.
        guard count <= limit else { return .failure(.tooLarge) }
        return .success(Data(buffer.prefix(count)))
    }

    /// `lstat` facts for up to `statLimit` absolute paths.
    public static func describe(_ paths: [String], uid: uid_t = geteuid()) -> [BrokerPathInfo]? {
        guard paths.count <= BrokerProtocol.statLimit, paths.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.contains("\0") }) else { return nil }
        return paths.map { path in
            guard let entry = BrokerFiles.entry(path) else { return BrokerPathInfo(path: path, kind: .missing, owned: false, size: 0, realPath: nil) }
            let kind: BrokerPathInfo.Kind =
                switch entry.kind {
                case .file: .file
                case .directory: .directory
                case .symlink: .symlink
                case .socket, .other: .other
                }
            return BrokerPathInfo(path: path, kind: kind, owned: entry.uid == uid, size: entry.size, realPath: BrokerFiles.realPath(path))
        }
    }
}

/// `read` is shadowed inside types that define their own; this keeps the system call reachable.
enum Glue {
    static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
            Darwin.read(fd, buffer, count)
        #elseif canImport(Glibc)
            Glibc.read(fd, buffer, count)
        #else
            Musl.read(fd, buffer, count)
        #endif
    }

    static func close(_ fd: Int32) { systemClose(fd) }
}
