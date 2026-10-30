import Foundation

/// `projects.json` in the state directory (FR-PL05): owner-only, atomic, with a backup of the last valid version.
public struct ProjectFileStorage: HostStorage {
    public let directory: URL
    public var url: URL { directory.appendingPathComponent("projects.json") }
    public var backupURL: URL { directory.appendingPathComponent("projects.backup.json") }
    public init(directory: URL) { self.directory = directory }

    public func read() throws -> Data? { try LibraryFile.read(url, limit: ProjectLibraryCodec.byteLimit) }

    public func write(_ data: Data) throws {
        try LibraryFile.write(data, to: url, backup: backupURL, limit: ProjectLibraryCodec.byteLimit) { (try? ProjectLibraryCodec.decode($0)) != nil }
    }

    public func preserveUnreadable() throws { try LibraryFile.preserveUnreadable(url, name: "projects") }
}

public enum ProjectLibraryCodec {
    public static let currentVersion = 1
    static let byteLimit = 8_388_608
    private struct Header: Decodable { var schemaVersion: Int }
    private struct Document: Codable {
        var schemaVersion: Int
        var revision: UInt64
        var projects: [ProjectDefinition]
    }

    public static func encode(_ projects: [ProjectDefinition], revision: UInt64) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Document(schemaVersion: currentVersion, revision: revision, projects: projects))
    }

    /// Re-validates every stored project, so a hand-edited file can't smuggle a command or URL the editor refuses.
    public static func decode(_ data: Data) throws -> (projects: [ProjectDefinition], revision: UInt64) {
        guard data.count <= byteLimit, let header = try? JSONDecoder().decode(Header.self, from: data), header.schemaVersion == currentVersion,
            let document = try? JSONDecoder().decode(Document.self, from: data), Set(document.projects.map(\.id)).count == document.projects.count,
            document.projects.allSatisfy({ $0.revision <= document.revision && $0.issues.isEmpty && $0 == $0.normalized })
        else { throw HostLibraryError.readOnly }
        return (document.projects, document.revision)
    }
}

public enum ProjectLibraryError: Error, Equatable, Sendable {
    case invalid([ProjectDefinition.Issue])
    case notFound
    /// The project changed since the editor loaded it.
    case conflict
    /// The stored file is unreadable or newer; it is preserved, not overwritten.
    case readOnly
    case io
}

/// Single writer for the project library (FR-PL05). Every change validates first and persists before it becomes
/// visible, so a failed write leaves the previous library.
public actor ProjectLibrary {
    public private(set) var projects: [ProjectDefinition] = []
    public private(set) var revision: UInt64 = 0
    public private(set) var loadFailed = false
    /// Writes wait for a load, so a change made before it can never replace the stored library.
    private var loaded = false
    private let storage: HostStorage
    private let makeID: @Sendable () -> UUID

    public init(storage: HostStorage, makeID: @escaping @Sendable () -> UUID = { UUID() }) { self.storage = storage; self.makeID = makeID }

    @discardableResult
    public func load() -> Bool {
        do {
            loaded = true
            guard let data = try storage.read() else { loadFailed = false; return true }
            (projects, revision) = try ProjectLibraryCodec.decode(data)
            projects.sort(by: Self.displayOrder)
            loadFailed = false
        } catch {
            projects = []; revision = 0; loadFailed = true
        }
        return !loadFailed
    }

    /// Explicit recovery: keep the unreadable file beside the library, then start empty.
    public func resetUnreadable() throws(ProjectLibraryError) {
        do { try storage.preserveUnreadable() } catch { throw .io }
        try persist([], revision: 0)
        projects = []; revision = 0; loadFailed = false
    }

    /// Adds `project` under a new identity, so importing or capturing twice gives two projects.
    public func create(_ project: ProjectDefinition) throws(ProjectLibraryError) -> ProjectDefinition {
        var created = try validated(project)
        created.id = makeID(); created.revision = revision + 1
        try commit(projects + [created])
        return created
    }

    /// Adds several projects in one write, each under a new identity (FR-PL05 import); all or none.
    public func createAll(_ added: [ProjectDefinition]) throws(ProjectLibraryError) -> [ProjectDefinition] {
        var created: [ProjectDefinition] = []
        for project in added {
            var next = try validated(project)
            next.id = makeID(); next.revision = revision + 1; next.lastFolders = [:]
            created.append(next)
        }
        guard !created.isEmpty else { return [] }
        try commit(projects + created)
        return created
    }

    /// Saves the editor's project; `project.revision` must be the stored one. Launch history is kept as stored.
    public func update(_ project: ProjectDefinition) throws(ProjectLibraryError) -> ProjectDefinition {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { throw .notFound }
        guard projects[index].revision == project.revision else { throw .conflict }
        var saved = try validated(project)
        saved.lastFolders = projects[index].lastFolders
        guard saved != projects[index] else { return projects[index] }
        saved.revision = revision + 1
        var next = projects
        next[index] = saved
        try commit(next)
        return saved
    }

    /// Remembers where the project was launched (FR-PL06); an open editor's revision stays valid.
    public func recordLaunch(_ id: UUID, target: ProjectTarget, folder: String) throws(ProjectLibraryError) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw .notFound }
        guard projects[index].lastFolders[target.key] != folder else { return }
        var next = projects
        next[index].lastFolders[target.key] = folder
        try commit(next)
    }

    public func delete(_ id: UUID, expectedRevision: UInt64) throws(ProjectLibraryError) {
        guard let project = projects.first(where: { $0.id == id }) else { throw .notFound }
        guard project.revision == expectedRevision else { throw .conflict }
        try commit(projects.filter { $0.id != id })
    }

    private func validated(_ project: ProjectDefinition) throws(ProjectLibraryError) -> ProjectDefinition {
        let normalized = project.normalized
        let issues = normalized.issues
        guard issues.isEmpty else { throw .invalid(issues) }
        return normalized
    }

    private func commit(_ next: [ProjectDefinition]) throws(ProjectLibraryError) {
        guard loaded, !loadFailed else { throw .readOnly }
        let sorted = next.sorted(by: Self.displayOrder)
        try persist(sorted, revision: revision + 1)
        projects = sorted
        revision += 1
    }

    private func persist(_ projects: [ProjectDefinition], revision: UInt64) throws(ProjectLibraryError) {
        do { try storage.write(try ProjectLibraryCodec.encode(projects, revision: revision)) } catch HostLibraryError.readOnly { throw .readOnly } catch { throw .io }
    }

    private static func displayOrder(_ a: ProjectDefinition, _ b: ProjectDefinition) -> Bool {
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: a.id.uuidString < b.id.uuidString
        }
    }
}
