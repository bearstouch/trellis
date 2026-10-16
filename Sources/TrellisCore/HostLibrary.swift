import Darwin
import Foundation

public enum HostLibraryError: Error, Equatable, Sendable {
    case invalid(HostValidationError)
    case notFound
    /// The host changed since the editor loaded it.
    case conflict(expected: UInt64, actual: UInt64)
    /// The stored file is unreadable or newer; it is preserved, not overwritten.
    case readOnly
    case io(Int32)
}

/// Persistence boundary for host metadata, replaceable in tests.
public protocol HostStorage: Sendable {
    func read() throws -> Data?
    /// Publishes `data` atomically, keeping the previous valid file as a backup.
    func write(_ data: Data) throws
    /// Moves an unreadable file aside so a fresh library can be saved.
    func preserveUnreadable() throws
}

/// `hosts.json` beside the workspace: owner-only, atomic same-directory rename.
public struct HostFileStorage: HostStorage {
    public let directory: URL
    public var url: URL { directory.appendingPathComponent("hosts.json") }
    public var backupURL: URL { directory.appendingPathComponent("hosts.backup.json") }
    public init(directory: URL) { self.directory = directory }

    public func read() throws -> Data? { try Self.read(url) }

    public func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let previous = try Self.read(url), (try? HostLibraryCodec.decode(previous)) != nil { try publish(previous, to: backupURL) }
        try publish(data, to: url)
    }

    /// Renames rather than copies, so oversized, unreadable, or symlinked files are kept too.
    public func preserveUnreadable() throws {
        let aside = directory.appendingPathComponent("hosts.unreadable.\(UUID().uuidString).json")
        guard rename(url.path, aside.path) == 0 || errno == ENOENT else { throw HostLibraryError.io(errno) }
    }

    private static func read(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return nil }; throw HostLibraryError.io(errno) }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= HostLibraryCodec.byteLimit else { throw HostLibraryError.readOnly }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { return result }
            if count < 0 { if errno == EINTR { continue }; throw HostLibraryError.io(errno) }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= HostLibraryCodec.byteLimit else { throw HostLibraryError.readOnly }
        }
    }

    private func publish(_ data: Data, to target: URL) throws {
        let temporary = directory.appendingPathComponent(".hosts.\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HostLibraryError.io(errno) }
        var openDescriptor = true
        defer { if openDescriptor { _ = close(fd) }; _ = unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw HostLibraryError.io(errno) }
                guard count > 0 else { throw HostLibraryError.io(EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw HostLibraryError.io(errno) }
        guard close(fd) == 0 else { openDescriptor = false; throw HostLibraryError.io(errno) }
        openDescriptor = false
        guard rename(temporary.path, target.path) == 0 else { throw HostLibraryError.io(errno) }
        let folder = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard folder >= 0 else { throw HostLibraryError.io(errno) }
        defer { _ = close(folder) }
        _ = fsync(folder)
    }
}

public enum HostLibraryCodec {
    public static let currentVersion = 1
    static let byteLimit = 1_048_576
    private struct Header: Decodable { var schemaVersion: Int }
    private struct Document: Codable {
        var schemaVersion: Int
        var revision: UInt64
        var hosts: [SavedHost]
    }

    public static func encode(_ hosts: [SavedHost], revision: UInt64) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Document(schemaVersion: currentVersion, revision: revision, hosts: hosts))
    }

    /// Re-validates every stored record, so a hand-edited file cannot smuggle an
    /// option-like destination into a later ssh launch.
    public static func decode(_ data: Data) throws -> (hosts: [SavedHost], revision: UInt64) {
        guard data.count <= byteLimit, let header = try? JSONDecoder().decode(Header.self, from: data),
            header.schemaVersion == currentVersion,
            let document = try? JSONDecoder().decode(Document.self, from: data),
            Set(document.hosts.map(\.id)).count == document.hosts.count,
            // Host revisions come from the library counter; a higher one would let a later
            // edit reuse a revision and defeat stale-editor conflict checks.
            document.hosts.allSatisfy({ $0.revision <= document.revision && $0.connectionRevision <= $0.revision }),
            document.hosts.allSatisfy({ host in
                guard let valid = try? host.draft.validated(isRegularFile: { _ in true }) else { return false }
                return SavedHost(id: host.id, draft: valid, revision: host.revision, connectionRevision: host.connectionRevision) == host
            })
        else { throw HostLibraryError.readOnly }
        return (document.hosts, document.revision)
    }
}

/// Single writer for saved hosts. Every mutation validates first and persists
/// before it becomes visible, so a failed write leaves the previous library.
public actor HostLibrary {
    public private(set) var hosts: [SavedHost] = []
    public private(set) var revision: UInt64 = 0
    /// Set when the stored file cannot be used; mutations are refused until reset.
    public private(set) var loadFailed = false
    private let storage: HostStorage
    private let makeID: @Sendable () -> UUID
    private let isRegularFile: @Sendable (String) -> Bool

    public init(
        storage: HostStorage, makeID: @escaping @Sendable () -> UUID = { UUID() },
        isRegularFile: @escaping @Sendable (String) -> Bool = { path in
            var info = stat()
            return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
        }
    ) {
        self.storage = storage; self.makeID = makeID; self.isRegularFile = isRegularFile
    }

    @discardableResult
    public func load() -> Bool {
        do {
            guard let data = try storage.read() else { loadFailed = false; return true }
            (hosts, revision) = try HostLibraryCodec.decode(data)
            hosts.sort(by: Self.displayOrder)
            loadFailed = false
        } catch {
            hosts = []; revision = 0; loadFailed = true
        }
        return !loadFailed
    }

    /// Explicit recovery: keep the unreadable file beside the library, then start empty.
    public func resetUnreadable() throws {
        try storage.preserveUnreadable()
        try persist([], revision: 0)
        hosts = []; revision = 0; loadFailed = false
    }

    public func search(_ query: String) -> [SavedHost] { SavedHost.search(hosts, query: query) }

    public func create(_ draft: HostDraft) throws(HostLibraryError) -> SavedHost {
        try createAll([draft])[0]
    }

    /// Validates every draft before a single commit.
    public func createAll(_ drafts: [HostDraft]) throws(HostLibraryError) -> [SavedHost] {
        var created: [SavedHost] = []
        for draft in drafts { created.append(SavedHost(id: makeID(), draft: try validate(draft), revision: revision + 1)) }
        guard !created.isEmpty else { return [] }
        try commit(hosts + created)
        return created
    }

    /// A planned import: new hosts with pre-assigned IDs, and explicit replacements
    /// of existing hosts (chosen by the user's collision policy, never by name alone).
    public struct ImportChanges: Sendable {
        public var creates: [(id: UUID, draft: HostDraft)] = []
        public var replacements: [(id: UUID, draft: HostDraft, expectedRevision: UInt64)] = []
        public init() {}
    }

    /// What an import changed, for `revertImport`.
    public struct ImportUndo: Sendable {
        let replaced: [SavedHost]
        let created: Set<UUID>
        let stamp: UInt64
    }

    /// Validates everything first, then commits all changes in one write.
    public func applyImport(_ changes: ImportChanges) throws(HostLibraryError) -> ImportUndo {
        var next = hosts, replaced: [SavedHost] = []
        let stamp = revision + 1
        for replacement in changes.replacements {
            guard let index = next.firstIndex(where: { $0.id == replacement.id }) else { throw .notFound }
            guard next[index].revision == replacement.expectedRevision else {
                throw .conflict(expected: replacement.expectedRevision, actual: next[index].revision)
            }
            var host = SavedHost(id: replacement.id, draft: try validate(replacement.draft), revision: stamp)
            if host.sameConnection(as: next[index]) { host.connectionRevision = next[index].connectionRevision }
            replaced.append(next[index])
            next[index] = host
        }
        for create in changes.creates {
            guard !next.contains(where: { $0.id == create.id }) else { throw .conflict(expected: 0, actual: revision) }
            next.append(SavedHost(id: create.id, draft: try validate(create.draft), revision: stamp))
        }
        let undo = ImportUndo(replaced: replaced, created: Set(changes.creates.map(\.id)), stamp: stamp)
        if !changes.creates.isEmpty || !changes.replacements.isEmpty { try commit(next) }
        return undo
    }

    /// Undoes only the import's own records when the rest of an import could not
    /// be committed; hosts edited by someone else since then are left alone.
    public func revertImport(_ undo: ImportUndo) throws(HostLibraryError) {
        let untouched = { (id: UUID) in self.hosts.contains { $0.id == id && $0.revision == undo.stamp } }
        let restore = undo.replaced.filter { untouched($0.id) }
        let remove = undo.created.filter(untouched)
        guard !restore.isEmpty || !remove.isEmpty else { return }
        try commit(
            hosts.compactMap { host in
                if remove.contains(host.id) { return nil }
                guard var restored = restore.first(where: { $0.id == host.id }) else { return host }
                // Revisions only advance, so editors holding the imported revision see a conflict.
                restored.revision = revision + 1
                return restored
            })
    }

    /// `expectedRevision` is the host revision the editor started from.
    public func update(id: UUID, _ draft: HostDraft, expectedRevision: UInt64) throws(HostLibraryError) -> SavedHost {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { throw .notFound }
        guard hosts[index].revision == expectedRevision else { throw .conflict(expected: expectedRevision, actual: hosts[index].revision) }
        let valid = try validate(draft)
        // An unchanged save keeps the revision, so it does not invalidate approvals.
        let current = hosts[index]
        guard SavedHost(id: id, draft: valid, revision: current.revision, connectionRevision: current.connectionRevision) != current else { return current }
        var host = SavedHost(id: id, draft: valid, revision: revision + 1)
        // Renaming or retagging keeps the connection revision, so approvals survive.
        if host.sameConnection(as: current) { host.connectionRevision = current.connectionRevision }
        var next = hosts
        next[index] = host
        try commit(next)
        return host
    }

    /// Removes metadata only. No session, process, or SSH file is touched.
    public func delete(id: UUID, expectedRevision: UInt64? = nil) throws(HostLibraryError) {
        guard let host = hosts.first(where: { $0.id == id }) else { throw .notFound }
        if let expectedRevision, host.revision != expectedRevision { throw .conflict(expected: expectedRevision, actual: host.revision) }
        try commit(hosts.filter { $0.id != id })
    }

    private func validate(_ draft: HostDraft) throws(HostLibraryError) -> HostDraft.Valid {
        do { return try draft.validated(isRegularFile: isRegularFile) } catch { throw .invalid(error) }
    }

    private func commit(_ next: [SavedHost]) throws(HostLibraryError) {
        guard !loadFailed else { throw .readOnly }
        let sorted = next.sorted(by: Self.displayOrder)
        try persist(sorted, revision: revision + 1)
        hosts = sorted
        revision += 1
    }

    private func persist(_ hosts: [SavedHost], revision: UInt64) throws(HostLibraryError) {
        do {
            try storage.write(try HostLibraryCodec.encode(hosts, revision: revision))
        } catch let error as HostLibraryError {
            throw error
        } catch {
            throw .io(EIO)
        }
    }

    private static func displayOrder(_ a: SavedHost, _ b: SavedHost) -> Bool {
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: a.id.uuidString < b.id.uuidString
        }
    }
}
