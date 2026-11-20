import Foundation
import TrellisBroker
import TrellisCore

/// The helper's limits the views name.
enum BrokerLimits {
    static let directoryEntries = BrokerProtocol.directoryEntryLimit
}

/// A file read from a remote workspace's host, with what the helper said about it when the last chunk was read.
public struct RemoteFileContents: Equatable, Sendable {
    public let data: Data
    public let stamp: EditorDiskStamp
    public init(data: Data, stamp: EditorDiskStamp) { self.data = data; self.stamp = stamp }
}

public enum RemoteFileFailure: Error, Equatable, Sendable {
    case missing, notAFile, tooLarge, unreadable
    /// The link is down, or the helper didn't answer.
    case disconnected

    var editorError: EditorFileError {
        switch self {
        case .missing: .unreadable(L("The file is no longer there."))
        case .notAFile: .notAFile
        case .tooLarge: .tooLarge
        case .unreadable: .unreadable(L("The host refused to read it."))
        case .disconnected: .unreadable(L("The host isn't connected."))
        }
    }
}

/// A connected host's files as the Files view and read-only editor tabs use them (FR-FB09, FR-ED16): folders listed and
/// files read through the Trellis helper there, never written. Injected by tests.
public protocol RemoteFileAccess: FileTreeSource {
    /// The account's home folder on the host.
    var home: String { get }
    /// False when the host's helper predates folder listings; nothing is asked of it then.
    var browses: Bool { get }
    /// The project (the nearest folder with `.trellis` or `.git`) holding `directory`, else `directory`, with links resolved.
    func projectRoot(containing directory: String) async -> String
    /// A regular file's bytes, refused above `limit`.
    func read(_ path: String, limit: Int) async -> Result<RemoteFileContents, RemoteFileFailure>
}

extension RemoteFileAccess {
    public func text(at path: String) async -> String? {
        guard case .success(let contents) = await read(path, limit: 256 * 1024) else { return nil }
        return String(data: contents.data, encoding: .utf8)
    }
}

/// The helper's side of ``RemoteFileAccess``, over a host's connected link.
struct BrokerFileAccess: RemoteFileAccess {
    let connection: BrokerConnection
    let home: String
    let browses: Bool
    /// A listing or a read of a slow folder may take longer than a control request.
    static let timeout = Duration.seconds(20)
    /// Path bytes per request, as for `stat`: escaped as JSON, still well inside a frame.
    static let requestBytes = 65_536

    @MainActor init?(connection: BrokerConnection) {
        guard let home = connection.hostInfo?.home else { return nil }
        self.connection = connection
        self.home = home
        browses = connection.protocolVersion >= BrokerProtocol.browseVersion
    }

    @MainActor func projectRoot(containing directory: String) async -> String {
        let facts = RemoteFacts(connection: connection), home = home
        let found = await facts.evaluate { ProjectLocator.taskRoot(containing: directory, home: home, exists: $0.exists) } ?? directory
        return await facts.entry(found)?.realPath ?? found
    }

    @MainActor func contents(of directories: [String]) async -> [String: FolderListing] {
        guard browses else { return [:] }
        var listed: [String: FolderListing] = [:]
        var waiting = Array(Set(directories)).sorted(), batchLimit = BrokerProtocol.statLimit
        while !waiting.isEmpty {
            var batch: [String] = [], bytes = 0
            for path in waiting where batch.count < batchLimit {
                if !batch.isEmpty, bytes + path.utf8.count > Self.requestBytes { break }
                batch.append(path); bytes += path.utf8.count
            }
            switch try? await connection.request(.listDirectories(paths: batch), timeout: Self.timeout) {
            case .directories(let listings)?:
                var answered = Set<String>()
                for listing in listings where listing.state != .deferred {
                    answered.insert(listing.path)
                    listed[listing.path] = listing.state == .ok ? .entries(listing.entries.map { Self.entry($0, in: listing.path) }, truncated: listing.truncated) : .unreadable
                }
                // A helper that answered nothing would be asked forever.
                guard !answered.isEmpty else { return listed }
                waiting.removeAll { answered.contains($0) }
            // The answer outgrew a frame: fewer folders at a time, and one that doesn't fit alone can't be shown.
            case .failed("TOO_LARGE", _)? where batch.count > 1: batchLimit = batch.count / 2
            case .failed("TOO_LARGE", _)?: waiting.removeFirst()
            // The link went down, or the request was refused: what is left stays unread.
            default: return listed
            }
        }
        return listed
    }

    static func entry(_ entry: BrokerDirectoryEntry, in folder: String) -> FileEntry {
        FileEntry(path: (folder == "/" ? "" : folder) + "/" + entry.name, isDirectory: entry.kind == .directory, isSymbolicLink: entry.kind == .symlink)
    }

    @MainActor func read(_ path: String, limit: Int) async -> Result<RemoteFileContents, RemoteFileFailure> {
        guard browses else { return .failure(.disconnected) }
        // A file that changes while it is read is read again from its start, once.
        for _ in 0..<2 {
            var data = Data(), described: (size: Int64, modified: Int64)?, changed = false
            while !changed {
                switch try? await connection.request(.readFileChunk(path: path, offset: Int64(data.count), length: BrokerProtocol.fileChunkLimit), timeout: Self.timeout) {
                case .fileChunk(let chunk, let size, let modified)?:
                    guard size <= Int64(limit) else { return .failure(.tooLarge) }
                    if let described, described != (size, modified) { changed = true; continue }
                    described = (size, modified)
                    data.append(chunk)
                    guard data.count <= limit else { return .failure(.tooLarge) }
                    if chunk.isEmpty || Int64(data.count) >= size {
                        return .success(RemoteFileContents(data: data, stamp: EditorDiskStamp(modified: TimeInterval(modified) / 1_000_000_000, size: size)))
                    }
                case .failed("NOT_FOUND", _)?: return .failure(.missing)
                case .failed("NOT_ALLOWED", _)?: return .failure(.notAFile)
                case .failed("TOO_LARGE", _)?: return .failure(.tooLarge)
                case .failed?: return .failure(.unreadable)
                default: return .failure(.disconnected)
                }
            }
        }
        return .failure(.unreadable)
    }
}

/// Remembers each folder it listed, so the letters of one search walk the host's tree once (FR-FB09). Dropped with the
/// search: Reload, another root or a cleared field reads the host again.
actor CachedTreeSource: FileTreeSource {
    private let inner: any FileTreeSource
    private var known: [String: FolderListing] = [:]
    init(_ inner: any FileTreeSource) { self.inner = inner }

    func contents(of directories: [String]) async -> [String: FolderListing] {
        let missing = directories.filter { known[$0] == nil }
        if !missing.isEmpty {
            // Only what was read is kept: a folder the link dropped is asked for again.
            for (path, listing) in await inner.contents(of: missing) { known[path] = listing }
        }
        return Dictionary(directories.compactMap { path in known[path].map { (path, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    func text(at path: String) async -> String? { await inner.text(at: path) }
}
