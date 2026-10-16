import Foundation
import Darwin

public enum ThemeLibraryError: Error, Equatable, Sendable, LocalizedError {
    case reservedID, duplicateID(String), notFound, filenameMismatch, unsafeFile, io(Int32)
    public var errorDescription: String? {
        switch self {
        case .reservedID: "The trellis- namespace is reserved. Built-in themes cannot be replaced or deleted."
        case .duplicateID(let id): "A theme with ID '\(id)' already exists. Choose Replace Theme to replace it."
        case .notFound: "The theme is no longer available. Reload the theme library."
        case .filenameMismatch: "The filename must match the theme ID: <id>.theme.json."
        case .unsafeFile: "Use a regular theme file in a real Themes directory; symbolic links are not supported."
        case .io(let code): "The theme file operation failed (system error \(code))."
        }
    }
}

public struct ThemeLibraryIssue: Equatable, Sendable {
    public let filename: String
    public let message: String
}
public struct ThemeLibrarySnapshot: Equatable, Sendable {
    public var documents: [String: ThemeDocument] = [:]
    public var issues: [ThemeLibraryIssue] = []
    public init() {}
}

/// The commit operation must either succeed or leave the prior destination
/// unchanged. Injection allows meaningful pre-commit failure tests.
public protocol ThemeLibraryFiles: Sendable {
    func prepare(_ directory: URL) throws
    func filenames(in directory: URL) throws -> [String]
    func read(_ file: URL) throws -> Data
    func exists(_ file: URL) -> Bool
    func commit(_ data: Data, to file: URL, replace: Bool) throws
    func remove(_ file: URL) throws
}

public struct DiskThemeLibraryFiles: ThemeLibraryFiles {
    public init() {}
    public func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { throw ThemeLibraryError.io(errno) }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw ThemeLibraryError.unsafeFile }
    }
    public func filenames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") && $0.hasSuffix(".theme.json") }.sorted()
    }
    public func exists(_ file: URL) -> Bool {
        var info = stat()
        return lstat(file.path, &info) == 0
    }
    public func read(_ file: URL) throws -> Data {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ThemeLibraryError.io(errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ThemeLibraryError.io(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw ThemeLibraryError.unsafeFile }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= ThemeValidator.maximumBytes {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, ThemeValidator.maximumBytes + 1 - data.count)) }
            if count < 0 { if errno == EINTR { continue }; throw ThemeLibraryError.io(errno) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    public func commit(_ data: Data, to file: URL, replace: Bool) throws {
        let directory = file.deletingLastPathComponent()
        try prepare(directory)
        let temporary = directory.appendingPathComponent(".theme-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ThemeLibraryError.io(errno) }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw ThemeLibraryError.io(errno) }
                guard count > 0 else { throw ThemeLibraryError.io(EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw ThemeLibraryError.io(errno) }
        // link is an atomic no-replace publish; rename is atomic replacement.
        let result = replace ? rename(temporary.path, file.path) : link(temporary.path, file.path)
        guard result == 0 else {
            if errno == EEXIST { throw ThemeLibraryError.duplicateID(file.deletingPathExtension().deletingPathExtension().lastPathComponent) }
            throw ThemeLibraryError.io(errno)
        }
        // No throwable work after the commit point: a reported failure must
        // never hide a successful replacement from the in-memory catalog.
        let parent = open(directory.path, O_RDONLY | O_CLOEXEC)
        if parent >= 0 { _ = fsync(parent); close(parent) }
    }
    public func remove(_ file: URL) throws {
        guard unlink(file.path) == 0 else { throw ThemeLibraryError.io(errno) }
    }
}

public actor ThemeLibrary {
    public nonisolated let directory: URL
    private let files: any ThemeLibraryFiles
    private var current = ThemeLibrarySnapshot()
    public init(directory: URL, files: any ThemeLibraryFiles = DiskThemeLibraryFiles()) {
        self.directory = directory; self.files = files
    }
    public func snapshot() -> ThemeLibrarySnapshot { current }
    public func ensureDirectory() throws -> URL { try files.prepare(directory); return directory }
    @discardableResult public func reload() -> ThemeLibrarySnapshot {
        do {
            try files.prepare(directory)
            let names = try files.filenames(in: directory)
            var next = current.documents
            var issues: [ThemeLibraryIssue] = []
            for name in names {
                do {
                    let document = try ThemeValidator.validate(files.read(directory.appendingPathComponent(name)))
                    guard !document.hasReservedID else { throw ThemeLibraryError.reservedID }
                    guard name == document.id + ".theme.json" else { throw ThemeLibraryError.filenameMismatch }
                    next[document.id] = document
                } catch { issues.append(ThemeLibraryIssue(filename: name, message: error.localizedDescription)) }
            }
            let present = Set(names)
            next = next.filter { present.contains($0.key + ".theme.json") }
            current.documents = next; current.issues = issues
        } catch {
            current.issues = [ThemeLibraryIssue(filename: "Themes", message: error.localizedDescription)]
        }
        return current
    }
    @discardableResult public func install(_ data: Data, replace: Bool = false) throws -> ThemeLibrarySnapshot {
        let document = try ThemeValidator.validate(data)
        guard !document.hasReservedID else { throw ThemeLibraryError.reservedID }
        let destination = directory.appendingPathComponent(document.id + ".theme.json")
        try files.prepare(directory)
        if !replace, current.documents[document.id] != nil || files.exists(destination) { throw ThemeLibraryError.duplicateID(document.id) }
        try files.commit(document.encoded(), to: destination, replace: replace)
        current.documents[document.id] = document
        current.issues.removeAll { $0.filename == destination.lastPathComponent }
        return current
    }
    @discardableResult public func delete(_ id: String) throws -> ThemeLibrarySnapshot {
        guard !id.hasPrefix("trellis-") else { throw ThemeLibraryError.reservedID }
        guard current.documents[id] != nil else { throw ThemeLibraryError.notFound }
        try files.prepare(directory)
        try files.remove(directory.appendingPathComponent(id + ".theme.json"))
        current.documents.removeValue(forKey: id)
        current.issues.removeAll { $0.filename == id + ".theme.json" }
        return current
    }
    public func export(_ id: String, resolved: Bool = false) throws -> Data {
        for appearance in ThemeAppearance.allCases {
            let builtIn = ResolvedTheme.builtIn(appearance)
            if id == builtIn.id { return try builtIn.encoded() }
        }
        guard let document = current.documents[id] else { throw ThemeLibraryError.notFound }
        return try document.encoded(resolved: resolved)
    }
}
