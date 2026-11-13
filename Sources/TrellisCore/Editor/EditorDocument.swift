import Darwin
import Foundation

/// What the editor remembers about the file it read, to notice a change on disk (FR-ED06).
public struct EditorDiskStamp: Equatable, Sendable {
    public var modified: TimeInterval
    public var size: Int64
    public init(modified: TimeInterval, size: Int64) { self.modified = modified; self.size = size }
}

public enum EditorFileError: Error, Equatable, Sendable {
    case tooLarge, binary, notUTF8, notAFile
    case unreadable(String)
    case writeFailed(String)

    /// The message shown on screen.
    public var message: String {
        switch self {
        case .tooLarge: L("It's larger than 2 MB.")
        case .binary: L("It isn't a text file.")
        case .notUTF8: L("It isn't UTF-8 text.")
        case .notAFile: L("It isn't a regular file.")
        case .unreadable(let reason): L("It can't be read: %@", reason)
        case .writeFailed(let reason): L("It can't be saved: %@", reason)
        }
    }

    /// Refusals that hand the file to the default app instead (FR-ED02).
    public var opensElsewhere: Bool { self == .tooLarge || self == .binary || self == .notUTF8 }
}

/// The file system as the editor uses it; injected so tests never touch the real one.
public struct EditorFileSystem: Sendable {
    /// The file's stamp, or nil when there is no regular file (deleted, or not a file).
    public var stamp: @Sendable (String) -> EditorDiskStamp?
    public var isRegularFile: @Sendable (String) -> Bool
    /// Reads at most `limit + 1` bytes, so an oversized file is noticed without reading all of it.
    public var read: @Sendable (_ path: String, _ limit: Int) throws -> Data
    /// Replaces the file atomically, keeping its permissions; creates it (0644 less the umask) when missing.
    public var write: @Sendable (_ data: Data, _ path: String) throws -> Void

    public init(
        stamp: @escaping @Sendable (String) -> EditorDiskStamp?, isRegularFile: @escaping @Sendable (String) -> Bool,
        read: @escaping @Sendable (String, Int) throws -> Data, write: @escaping @Sendable (Data, String) throws -> Void
    ) {
        self.stamp = stamp; self.isRegularFile = isRegularFile; self.read = read; self.write = write
    }

    public static let live = EditorFileSystem(
        stamp: { path in
            var status = stat()
            guard stat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
            let modified = TimeInterval(status.st_mtimespec.tv_sec) + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
            return EditorDiskStamp(modified: modified, size: Int64(status.st_size))
        },
        isRegularFile: { path in
            var status = stat()
            return stat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFREG
        },
        read: { path, limit in
            guard let handle = FileHandle(forReadingAtPath: path) else { throw EditorFileError.unreadable(String(cString: strerror(errno))) }
            defer { try? handle.close() }
            return try handle.read(upToCount: limit + 1) ?? Data()
        },
        write: { data, path in
            // Through a symbolic link to its target, so the link stays a link.
            let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            let folder = (target as NSString).deletingLastPathComponent
            var status = stat()
            let mode: mode_t? = stat(target, &status) == 0 ? status.st_mode & 0o7777 : nil
            let temporary = folder + "/.\((target as NSString).lastPathComponent).trellis-\(UUID().uuidString.prefix(8))"
            let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw EditorFileError.writeFailed(String(cString: strerror(errno))) }
            var failure: String?
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 { if errno == EINTR { continue }; failure = String(cString: strerror(errno)); return }
                    offset += written
                }
            }
            if failure == nil, let mode, fchmod(fd, mode) != 0 { failure = String(cString: strerror(errno)) }
            if failure == nil, fsync(fd) != 0 { failure = String(cString: strerror(errno)) }
            close(fd)
            if failure == nil, rename(temporary, target) != 0 { failure = String(cString: strerror(errno)) }
            if let failure {
                unlink(temporary)
                throw EditorFileError.writeFailed(failure)
            }
        })
}

/// A text file open in an editor tab (FR-ED02–FR-ED04). The text uses `\n` line breaks; a file whose every line break
/// is CRLF is converted back when saved, and a byte-order mark is kept.
public struct EditorDocument: Equatable, Sendable {
    public enum LineEnding: Equatable, Sendable { case lf, crlf }

    public static let maximumBytes = 2 * 1024 * 1024
    /// Larger texts are shown without highlighting, so typing stays quick.
    public static let maximumHighlightedBytes = 512 * 1024
    /// A NUL byte in this many first bytes marks a binary file.
    static let binaryProbeBytes = 8192

    public let path: String
    public var text: String
    public var lineEnding: LineEnding
    public var hasBOM: Bool
    /// Nil when the file didn't exist when last read or written.
    public var stamp: EditorDiskStamp?

    public init(path: String, text: String, lineEnding: LineEnding = .lf, hasBOM: Bool = false, stamp: EditorDiskStamp? = nil) {
        self.path = path; self.text = text; self.lineEnding = lineEnding; self.hasBOM = hasBOM; self.stamp = stamp
    }

    public var fileName: String { (path as NSString).lastPathComponent }
    public var language: ScratchpadLanguage {
        EditorLanguage.detect(fileName: fileName, firstLine: String(text.prefix(256).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""))
    }

    /// Decodes a file's bytes, refusing what the editor couldn't write back intact.
    public static func decode(_ data: Data) throws(EditorFileError) -> (text: String, lineEnding: LineEnding, hasBOM: Bool) {
        guard data.count <= maximumBytes else { throw .tooLarge }
        if data.prefix(binaryProbeBytes).contains(0) { throw .binary }
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let hasBOM = data.starts(with: bom)
        let body = hasBOM ? data.dropFirst(3) : data[...]
        guard let decoded = String(data: body, encoding: .utf8) else { throw .notUTF8 }
        // Only a file that is CRLF throughout is converted; a mixed one keeps its `\r`s as text, so nothing changes on save.
        let lf = decoded.utf8.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        let crlf = decoded.components(separatedBy: "\r\n").count - 1
        if lf > 0, lf == crlf { return (decoded.replacingOccurrences(of: "\r\n", with: "\n"), .crlf, hasBOM) }
        return (decoded, .lf, hasBOM)
    }

    public static func load(path: String, fs: EditorFileSystem = .live) throws(EditorFileError) -> EditorDocument {
        guard fs.isRegularFile(path) else { throw .notAFile }
        let stamp = fs.stamp(path)
        let data: Data
        do { data = try fs.read(path, maximumBytes) } catch let error as EditorFileError { throw error } catch { throw .unreadable(error.localizedDescription) }
        let decoded = try decode(data)
        return EditorDocument(path: path, text: decoded.text, lineEnding: decoded.lineEnding, hasBOM: decoded.hasBOM, stamp: stamp)
    }

    /// `load` as a value, for handing across tasks.
    public static func loadResult(path: String, fs: EditorFileSystem = .live) -> Result<EditorDocument, EditorFileError> {
        do throws(EditorFileError) { return .success(try load(path: path, fs: fs)) } catch { return .failure(error) }
    }

    /// The bytes `text` is saved as, in this file's line endings and BOM.
    public func encoded(_ text: String) -> Data {
        let body = lineEnding == .crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
        return (hasBOM ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(body.utf8)
    }

    /// What is on disk now compared with what was read or last saved.
    public enum DiskState: Equatable, Sendable { case unchanged, changed, deleted }

    public func diskState(fs: EditorFileSystem = .live) -> DiskState {
        guard let now = fs.stamp(path) else { return stamp == nil ? .unchanged : .deleted }
        return now == stamp ? .unchanged : .changed
    }

    public func savingResult(_ text: String, fs: EditorFileSystem = .live) -> Result<EditorDocument, EditorFileError> {
        do throws(EditorFileError) { return .success(try saving(text, fs: fs)) } catch { return .failure(error) }
    }

    /// Writes `text` and returns the document as saved; on failure the file and this value are unchanged (FR-ED04).
    public func saving(_ text: String, fs: EditorFileSystem = .live) throws(EditorFileError) -> EditorDocument {
        do { try fs.write(encoded(text), path) } catch let error as EditorFileError { throw error } catch { throw .writeFailed(error.localizedDescription) }
        var saved = self
        saved.text = text
        saved.stamp = fs.stamp(path)
        return saved
    }
}

/// Whether a terminal link opens in an editor tab (FR-ED07): only a path inside the pane's project or current folder,
/// judged after resolving symbolic links and `..`, so a link can't reach outside them.
public enum EditorLinkScope {
    public static func contains(_ path: String, roots: [String]) -> Bool {
        let resolved = canonical(path)
        return roots.contains { root in
            let base = canonical(root)
            return base != "/" && resolved.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    /// `..` removed and links resolved, through the deepest folder that exists: Foundation leaves a missing path's links
    /// unresolved, which would let `project/link-out/new.txt` pass as inside.
    static func canonical(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL.path, rest: [String] = []
        while existing != "/", realpath(existing, nil) == nil {
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let real = realpath(existing, nil) else { return existing }
        defer { free(real) }
        return ([String(cString: real)] + rest).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
    }
}
