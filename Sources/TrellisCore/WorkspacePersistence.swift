import Darwin
import Foundation

public struct WorkspaceSettings: Codable, Equatable, Sendable {
    public var shell: String
    public var directory: String
    public var windowFrame: String?
    public var appearance: AppearanceSettings
    public var remoteControl: RemoteControlSettings
    public init(
        shell: String = LocalLaunchConfiguration.loginShell().executable,
        directory: String = FileManager.default.homeDirectoryForCurrentUser.path, windowFrame: String? = nil,
        appearance: AppearanceSettings = .init(), remoteControl: RemoteControlSettings = .init()
    ) {
        self.shell = shell; self.directory = directory; self.windowFrame = windowFrame
        self.appearance = appearance; self.remoteControl = remoteControl
    }
    private enum CodingKeys: String, CodingKey { case shell, directory, windowFrame, appearance, remoteControl }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shell = try values.decode(String.self, forKey: .shell)
        directory = try values.decode(String.self, forKey: .directory)
        windowFrame = try values.decodeIfPresent(String.self, forKey: .windowFrame)
        appearance = try values.decodeIfPresent(AppearanceSettings.self, forKey: .appearance) ?? .init()
        appearance.migrateLegacyThemeIDs()
        guard appearance.isValid else {
            throw DecodingError.dataCorruptedError(forKey: .appearance, in: values, debugDescription: "Invalid appearance settings")
        }
        // An unusable value turns the server off instead of failing the whole workspace.
        let remote = try? values.decodeIfPresent(RemoteControlSettings.self, forKey: .remoteControl)
        remoteControl = remote.flatMap { $0 }.flatMap { $0.isValid ? $0 : nil } ?? .init()
    }
}

public struct RestoredWorkspace: Sendable {
    public let snapshot: WorkspaceSnapshot
    public let settings: WorkspaceSettings
    public let unconfiguredPaneIDs: Set<UUID>
}

public enum WorkspacePersistenceError: Error, Equatable, Sendable {
    case unsupportedVersion(Int), corrupt, readOnly, io(Int32)
}

private enum SavedLaunch: Codable {
    case shell(executable: String, directory: String?)
    case host(UUID)
    case customProcess(directory: String?)

    init(_ launch: SessionLaunch, settings: WorkspaceSettings) {
        switch launch {
        case .shell(let directory): self = .shell(executable: settings.shell, directory: directory)
        case .host(let id): self = .host(id)
        case .process(let executable, let arguments, let directory):
            // Never serialize arbitrary command arguments, which can contain
            // typed commands or credentials. Login shells are safe references.
            self = arguments == ["-l"] ? .shell(executable: executable, directory: directory) : .customProcess(directory: directory)
        }
    }
    var restored: SessionLaunch {
        switch self {
        case .shell(let executable, let directory): .process(executable: executable, arguments: ["-l"], directory: directory)
        case .host(let id): .host(id)
        case .customProcess(let directory): .process(executable: "", arguments: [], directory: directory)
        }
    }
    var needsConfiguration: Bool { if case .customProcess = self { return true }; return false }
}

private struct SavedPane: Codable {
    var pane: WorkspacePane
    var launch: SavedLaunch
}

private struct SavedWorkspace: Codable {
    var revision: UInt64
    var windows: [ManagedWindow]
    var activeWindowID: UUID?
    var tabs: [WorkspaceTab]
    var panes: [SavedPane]
}

public enum WorkspaceSnapshotCodec {
    public static let currentVersion = 1
    private struct Header: Decodable { var schemaVersion: Int }
    private struct Document: Codable {
        var schemaVersion: Int
        var workspace: SavedWorkspace
        var settings: WorkspaceSettings?
    }

    public static func encode(_ snapshot: WorkspaceSnapshot, settings: WorkspaceSettings) throws -> Data {
        try snapshot.validate()
        let panes = try snapshot.panes.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { pane in
            guard let session = snapshot.sessions[pane.sessionID] else { throw WorkspacePersistenceError.corrupt }
            return SavedPane(pane: pane, launch: SavedLaunch(session.launch, settings: settings))
        }
        let saved = SavedWorkspace(
            revision: snapshot.revision, windows: snapshot.windows, activeWindowID: snapshot.activeWindowID,
            tabs: snapshot.tabs.values.sorted { $0.id.uuidString < $1.id.uuidString }, panes: panes)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(schemaVersion: currentVersion, workspace: saved, settings: settings))
        guard data.count <= 4_194_304 else { throw WorkspacePersistenceError.corrupt }
        return data
    }

    public static func decode(_ data: Data) throws -> RestoredWorkspace {
        guard data.count <= 4_194_304 else { throw WorkspacePersistenceError.corrupt }
        // Bound recursive Codable work before decoding a user-controlled tree.
        var depth = 0, string = false, escaped = false
        for byte in data {
            if string {
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { string = false }
            } else if byte == 34 {
                string = true
            } else if byte == 91 || byte == 123 {
                depth += 1; guard depth <= 128 else { throw WorkspacePersistenceError.corrupt }
            } else if byte == 93 || byte == 125 {
                depth -= 1
            }
        }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else { throw WorkspacePersistenceError.corrupt }
        guard (0...currentVersion).contains(header.schemaVersion) else { throw WorkspacePersistenceError.unsupportedVersion(header.schemaVersion) }
        do {
            let document = try decoder.decode(Document.self, from: data)
            // Prototype v0 has the same graph and optional settings. Migration
            // supplies defaults in memory; a later atomic save publishes v1.
            let settings = document.settings ?? WorkspaceSettings()
            var result = WorkspaceSnapshot()
            result.revision = document.workspace.revision
            result.windows = document.workspace.windows
            result.activeWindowID = document.workspace.activeWindowID
            for tab in document.workspace.tabs {
                guard result.tabs.updateValue(tab, forKey: tab.id) == nil else { throw WorkspacePersistenceError.corrupt }
            }
            var unconfigured = Set<UUID>()
            for saved in document.workspace.panes {
                guard result.panes.updateValue(saved.pane, forKey: saved.pane.id) == nil,
                    result.sessions[saved.pane.sessionID] == nil
                else { throw WorkspacePersistenceError.corrupt }
                result.sessions[saved.pane.sessionID] = WorkspaceSession(id: saved.pane.sessionID, launch: saved.launch.restored)
                if saved.launch.needsConfiguration { unconfigured.insert(saved.pane.id) }
            }
            try result.validate()
            return RestoredWorkspace(snapshot: result, settings: settings, unconfiguredPaneIDs: unconfigured)
        } catch { throw WorkspacePersistenceError.corrupt }
    }
}

public enum WorkspaceLoadResult: Sendable {
    case missing
    case loaded(RestoredWorkspace)
    case recovery(reason: WorkspacePersistenceError, backup: RestoredWorkspace?)
}

/// Single writer; replacement and backup publication use same-directory rename.
public actor WorkspacePersistence {
    public nonisolated let directory: URL
    public nonisolated var currentURL: URL { directory.appendingPathComponent("workspace.json") }
    public nonisolated var backupURL: URL { directory.appendingPathComponent("workspace.backup.json") }
    private var writable = false
    private var replaceCorrupt = false
    private var lastSequence: UInt64 = 0
    private let beforeReplace: @Sendable (URL) throws -> Void

    public init(directory: URL, beforeReplace: @escaping @Sendable (URL) throws -> Void = { _ in }) {
        self.directory = directory; self.beforeReplace = beforeReplace
    }

    public func load() -> WorkspaceLoadResult {
        do {
            guard let data = try read(currentURL) else { writable = true; return .missing }
            let restored = try WorkspaceSnapshotCodec.decode(data)
            writable = true
            return .loaded(restored)
        } catch {
            writable = false
            let reason = (error as? WorkspacePersistenceError) ?? .corrupt
            let backup = try? read(backupURL).map(WorkspaceSnapshotCodec.decode)
            return .recovery(reason: reason, backup: backup)
        }
    }

    /// Explicit recovery preserves the original bytes before enabling writes.
    /// A newer version always remains read-only, including after recovery choice.
    public func authorizeRecovery() throws {
        if let data = try read(currentURL) {
            do { _ = try WorkspaceSnapshotCodec.decode(data) } catch WorkspacePersistenceError.unsupportedVersion { throw WorkspacePersistenceError.readOnly } catch { /* preserve the malformed source below */  }
            try ensureDirectory()
            try atomicWrite(data, to: directory.appendingPathComponent("workspace.corrupt.\(UUID().uuidString).json"))
        }
        replaceCorrupt = true
        writable = true
    }

    public func save(_ snapshot: WorkspaceSnapshot, settings: WorkspaceSettings, sequence: UInt64) throws {
        guard writable else { throw WorkspacePersistenceError.readOnly }
        guard sequence >= lastSequence else { return }
        let data = try WorkspaceSnapshotCodec.encode(snapshot, settings: settings)
        try ensureDirectory()
        if let previous = try read(currentURL) {
            if (try? WorkspaceSnapshotCodec.decode(previous)) != nil { try atomicWrite(previous, to: backupURL) } else if !replaceCorrupt { writable = false; throw WorkspacePersistenceError.readOnly }
        }
        try atomicWrite(data, to: currentURL)
        replaceCorrupt = false
        lastSequence = sequence
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func read(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return nil }; throw WorkspacePersistenceError.io(errno) }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 4_194_304 else { throw WorkspacePersistenceError.corrupt }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { return result }
            if count < 0 { if errno == EINTR { continue }; throw WorkspacePersistenceError.io(errno) }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= 4_194_304 else { throw WorkspacePersistenceError.corrupt }
        }
    }

    private func atomicWrite(_ data: Data, to target: URL) throws {
        let temporary = directory.appendingPathComponent(".workspace.\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw WorkspacePersistenceError.io(errno) }
        var openDescriptor = true
        defer { if openDescriptor { _ = close(fd) }; _ = unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw WorkspacePersistenceError.io(errno) }
                guard count > 0 else { throw WorkspacePersistenceError.io(EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw WorkspacePersistenceError.io(errno) }
        guard close(fd) == 0 else { openDescriptor = false; throw WorkspacePersistenceError.io(errno) }
        openDescriptor = false
        try beforeReplace(target)
        guard rename(temporary.path, target.path) == 0 else { throw WorkspacePersistenceError.io(errno) }
        let folder = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard folder >= 0 else { throw WorkspacePersistenceError.io(errno) }
        defer { _ = close(folder) }
        guard fsync(folder) == 0 else { throw WorkspacePersistenceError.io(errno) }
    }
}
