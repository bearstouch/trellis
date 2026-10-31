import CryptoKit
import Foundation

/// The helpers this build can install (FR-RW02): Linux builds listed in `remote/remote-helpers.json` beside the bundled
/// helpers, and the macOS one, which is the bundled `trellis-broker` itself.
public struct RemoteArtifactCatalog: Equatable, Sendable {
    public static let manifestName = "remote-helpers.json"
    public var artifacts: [String: RemoteArtifact]
    /// The shell integration scripts every install carries; empty means plain shells only (INT-01).
    public var integration: [RemoteIntegrationFile]
    public init(artifacts: [String: RemoteArtifact], integration: [RemoteIntegrationFile] = []) {
        self.integration = integration
        // Each install directory names the helper and the scripts together.
        let scripts = integration.map { "\($0.path)\u{0}\($0.digest)" }.joined(separator: "\u{0}")
        self.artifacts = artifacts.mapValues { artifact in
            var named = artifact
            named.directory = String(Self.hex(SHA256.hash(data: Data((artifact.digest + "\u{0}" + scripts).utf8))).prefix(16))
            return named
        }
    }

    private struct Manifest: Codable {
        struct Entry: Codable { var platform: String; var file: String; var digest: String; var fileDigest: String; var fileSize: Int; var compressed: Bool }
        var helpers: [Entry]
    }

    /// Entries naming a file outside `remoteDirectory`, or with malformed digests, are ignored.
    public static func load(remoteDirectory: URL?, macHelper: String?, integrationDirectory: String? = BundledShellIntegration.directory()) -> RemoteArtifactCatalog {
        var artifacts: [String: RemoteArtifact] = [:]
        if let remoteDirectory, let data = try? Data(contentsOf: remoteDirectory.appendingPathComponent(manifestName)),
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        {
            for entry in manifest.helpers
            where !entry.file.contains("/") && !entry.file.hasPrefix(".") && RemoteArtifact.isDigest(entry.digest) && RemoteArtifact.isDigest(entry.fileDigest) {
                artifacts[entry.platform] = RemoteArtifact(
                    platform: entry.platform, path: remoteDirectory.appendingPathComponent(entry.file).path, digest: entry.digest,
                    fileDigest: entry.fileDigest, fileSize: entry.fileSize, compressed: entry.compressed)
            }
        }
        if let macHelper, let digest = sha256(file: macHelper), let size = (try? FileManager.default.attributesOfItem(atPath: macHelper)[.size]) as? Int {
            artifacts["darwin"] = RemoteArtifact(platform: "darwin", path: macHelper, digest: digest, fileDigest: digest, fileSize: size, compressed: false)
        }
        return RemoteArtifactCatalog(artifacts: artifacts, integration: integrationDirectory.map(integrationFiles) ?? [])
    }

    /// Every regular file under the bundled shell integration folder, by relative path.
    static func integrationFiles(_ root: String) -> [RemoteIntegrationFile] {
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        var files: [RemoteIntegrationFile] = []
        while let relative = walker.nextObject() as? String {
            let path = root + "/" + relative
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue,
                relative.utf8.allSatisfy({ $0 == 0x2e || $0 == 0x2f || $0 == 0x2d || $0 == 0x5f || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
                !relative.contains(".."), let data = FileManager.default.contents(atPath: path)
            else { continue }
            files.append(RemoteIntegrationFile(path: relative, data: data, digest: hex(SHA256.hash(data: data))))
        }
        return files.sorted { $0.path < $1.path }
    }

    public func artifact(for probe: RemoteProbe) -> RemoteArtifact? { probe.platform.flatMap { artifacts[$0] } }

    /// The file still has the size and digest recorded for it; read once, right before upload.
    public static func payload(_ artifact: RemoteArtifact) -> Data? {
        guard let data = FileManager.default.contents(atPath: artifact.path), data.count == artifact.fileSize, hex(SHA256.hash(data: data)) == artifact.fileDigest else {
            return nil
        }
        return data
    }

    public static func sha256(file: String) -> String? { FileManager.default.contents(atPath: file).map { hex(SHA256.hash(data: $0)) } }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}

/// What Trellis last observed about a host's helper (FR-RW17). Recorded only from a probe, never inferred.
public struct RemoteHelperRecord: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// The helper this build installs.
        case current
        /// Only other builds are installed.
        case outdated
        case missing
        /// No helper for this platform, or no way to check a digest there.
        case unsupported
    }
    public var state: State
    public var system: String
    public var machine: String
    public var checkedAt: Date
    public init(state: State, system: String, machine: String, checkedAt: Date) {
        self.state = state; self.system = system; self.machine = machine; self.checkedAt = checkedAt
    }

    public init(probe: RemoteProbe, catalog: RemoteArtifactCatalog, checkedAt: Date) {
        let state: State
        if let artifact = catalog.artifact(for: probe), probe.checksumTool != nil {
            state = probe.installed.contains(artifact.directory) ? .current : (probe.installed.isEmpty ? .missing : .outdated)
        } else {
            state = .unsupported
        }
        self.init(state: state, system: probe.system, machine: probe.machine, checkedAt: checkedAt)
    }

    public var summary: String {
        let platform = RemotePlatform.displayName(system: system, machine: machine)
        return switch state {
        case .current: "Installed, up to date (\(platform))"
        case .outdated: "Update available (\(platform))"
        case .missing: "Not installed (\(platform))"
        case .unsupported: "Not available for \(platform)"
        }
    }
}

public struct RemoteHostPreferences: Codable, Equatable, Sendable {
    /// Install or update the helper without asking when opening a remote workspace. Off by default.
    public var autoInstall = false
    public var helper: RemoteHelperRecord?
    public init(autoInstall: Bool = false, helper: RemoteHelperRecord? = nil) { self.autoInstall = autoInstall; self.helper = helper }
}

/// `remote-hosts.json` in the state directory: per saved host, the helper status and the auto-install choice. Owner-only,
/// replaced atomically with the previous version kept as `remote-hosts.backup.json`, never holds a secret. An unparsable
/// file is set aside and reads as empty; one from a newer Trellis, or one that can't be read, is never written over, so
/// changes then last until quit.
public actor RemoteHostSettings {
    public static let fileName = "remote-hosts.json"
    static let byteLimit = 4_194_304
    private let url: URL?
    private var hosts: [UUID: RemoteHostPreferences] = [:]
    private var loaded = false
    private var readOnly = false

    public init(stateDirectory: URL?) { url = stateDirectory?.appendingPathComponent(Self.fileName) }

    private struct Document: Codable {
        var version = 1
        var hosts: [String: RemoteHostPreferences]
    }
    private struct Version: Decodable { var version: Int }

    public func all() -> [UUID: RemoteHostPreferences] {
        load()
        return hosts
    }

    public func preferences(_ host: UUID) -> RemoteHostPreferences {
        load()
        return hosts[host] ?? .init()
    }

    @discardableResult
    public func update(_ host: UUID, _ change: @Sendable (inout RemoteHostPreferences) -> Void) -> RemoteHostPreferences {
        load()
        var value = hosts[host] ?? .init()
        change(&value)
        hosts[host] = value == .init() ? nil : value
        save()
        return value
    }

    /// Drops entries for hosts that no longer exist.
    public func retain(_ ids: Set<UUID>) {
        load()
        guard hosts.keys.contains(where: { !ids.contains($0) }) else { return }
        hosts = hosts.filter { ids.contains($0.key) }
        save()
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let url else { return }
        let data: Data?
        do { data = try LibraryFile.read(url, limit: Self.byteLimit) } catch { readOnly = true; return }
        guard let data else { return }
        if let version = try? Self.decoder.decode(Version.self, from: data), version.version > 1 { readOnly = true; return }
        guard let document = Self.decode(data) else {
            if (try? LibraryFile.preserveUnreadable(url, name: "remote-hosts")) == nil { readOnly = true }
            return
        }
        hosts = Dictionary(uniqueKeysWithValues: document.hosts.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    private static func decode(_ data: Data) -> Document? {
        guard let document = try? decoder.decode(Document.self, from: data), document.version == 1 else { return nil }
        return document
    }

    private func save() {
        guard let url, !readOnly else { return }
        let document = Document(hosts: Dictionary(uniqueKeysWithValues: hosts.map { ($0.key.uuidString, $0.value) }))
        guard let data = try? Self.encoder.encode(document) else { return }
        try? LibraryFile.write(data, to: url, backup: url.deletingLastPathComponent().appendingPathComponent("remote-hosts.backup.json"), limit: Self.byteLimit) {
            Self.decode($0) != nil
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
