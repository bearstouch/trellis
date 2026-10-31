import Foundation

/// How an agent reports its state to Trellis (FR-AG08). Each kind is wired by Trellis at launch, never by editing the
/// user's own agent configuration.
public enum AgentIntegration: String, Codable, CaseIterable, Sendable {
    /// Claude Code hooks passed with `--settings`.
    case claudeHooks = "claude-hooks"
    /// Codex's `notify` program, set with `-c notify=…`.
    case codexNotify = "codex-notify"
    /// A pi extension loaded with `-e`.
    case piExtension = "pi-extension"
    /// Only the terminal's own signals: bell, desktop notifications and progress (FR-T06–T09).
    case none

    public var displayName: String {
        switch self {
        case .claudeHooks: "Hooks"
        case .codexNotify: "Notify + bell"
        case .piExtension: "Extension"
        case .none: "Bell and notifications"
        }
    }
    /// Whether the agent itself says when a prompt starts; without that, submitting input counts as working.
    public var reportsPrompts: Bool { self == .claudeHooks || self == .piExtension }
}

/// What a tab shows in place of its terminal icon while the agent runs (FR-AG09).
public enum AgentIcon: Equatable, Sendable {
    /// An SF Symbol name.
    case symbol(String)
    /// One or two characters drawn in the tab's tint.
    case monogram(String)
    /// An SVG, PNG or PDF beside the definition file, drawn as a template image.
    case image(String)

    public static let fallback = AgentIcon.symbol("sparkles")
}

extension AgentIcon: Codable {
    private enum Key: String, CodingKey { case symbol, monogram, image }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        guard values.allKeys.count == 1, let key = values.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "An icon names exactly one of symbol, monogram or image."))
        }
        let value = try values.decode(String.self, forKey: key)
        switch key {
        case .symbol: self = .symbol(value)
        case .monogram: self = .monogram(value)
        case .image: self = .image(value)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Key.self)
        switch self {
        case .symbol(let name): try values.encode(name, forKey: .symbol)
        case .monogram(let text): try values.encode(text, forKey: .monogram)
        case .image(let file): try values.encode(file, forKey: .image)
        }
    }
}

/// The vendor's own installer, run in the user's login shell in a visible pane (FR-AG12). Never with sudo.
public struct AgentInstallRecipe: Codable, Equatable, Sendable {
    public var command: String
    /// Programs the command needs on PATH (for example `npm`); a missing one is named before anything runs.
    public var requires: [String]
    public init(command: String, requires: [String] = []) { self.command = command; self.requires = requires }

    private enum CodingKeys: String, CodingKey { case command, requires }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        command = try values.decode(String.self, forKey: .command)
        requires = try values.decodeIfPresent([String].self, forKey: .requires) ?? []
    }
}

/// One agent Trellis can launch, from the bundled set or the user's Agents folder (FR-AG01). The same schema serves a
/// future registry.
public struct AgentDefinition: Codable, Equatable, Identifiable, Sendable {
    public static let schemaVersion = 1
    public var version: Int
    public var id: String
    public var name: String
    /// A command name looked up on the login shell's PATH, or an absolute path.
    public var executable: String
    public var arguments: [String]
    /// Arguments that continue the last conversation in the launch directory.
    public var resumeArguments: [String]
    public var integration: AgentIntegration
    public var icon: AgentIcon
    /// Keyed by platform: `darwin` or `linux`.
    public var install: [String: AgentInstallRecipe]
    public var homepage: String?

    public init(
        id: String, name: String, executable: String, arguments: [String] = [], resumeArguments: [String] = [], integration: AgentIntegration = .none,
        icon: AgentIcon = .fallback, install: [String: AgentInstallRecipe] = [:], homepage: String? = nil
    ) {
        version = Self.schemaVersion; self.id = id; self.name = name; self.executable = executable; self.arguments = arguments
        self.resumeArguments = resumeArguments; self.integration = integration; self.icon = icon; self.install = install; self.homepage = homepage
    }

    private enum CodingKeys: String, CodingKey { case version, id, name, executable, arguments, resumeArguments, integration, icon, install, homepage }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        executable = try values.decode(String.self, forKey: .executable)
        arguments = try values.decodeIfPresent([String].self, forKey: .arguments) ?? []
        resumeArguments = try values.decodeIfPresent([String].self, forKey: .resumeArguments) ?? []
        // An integration from a newer build degrades to the terminal's own signals.
        integration = (try? values.decodeIfPresent(String.self, forKey: .integration)).flatMap { $0.flatMap(AgentIntegration.init(rawValue:)) } ?? .none
        icon = (try? values.decodeIfPresent(AgentIcon.self, forKey: .icon)) ?? .fallback
        install = try values.decodeIfPresent([String: AgentInstallRecipe].self, forKey: .install) ?? [:]
        homepage = try values.decodeIfPresent(String.self, forKey: .homepage)
    }

    public var isBuiltIn: Bool { id.hasPrefix(AgentCatalog.reservedPrefix) }
}

public enum AgentDefinitionError: Error, Equatable, Sendable, LocalizedError {
    case tooLarge, malformed, unsupportedVersion(Int), invalid(String)
    public var errorDescription: String? {
        switch self {
        case .tooLarge: "The agent definition is larger than 16 KB."
        case .malformed: "The agent definition isn’t valid JSON in the agent schema."
        case .unsupportedVersion(let version): "Agent definition version \(version) isn’t supported by this Trellis."
        case .invalid(let field): "The agent definition’s \(field) isn’t valid."
        }
    }
}

public enum AgentDefinitionValidator {
    public static let maximumBytes = 16_384

    public static func validate(_ data: Data) throws -> AgentDefinition {
        guard data.count <= maximumBytes else { throw AgentDefinitionError.tooLarge }
        // A newer schema may not decode as this one; its version number is what the user needs to see (FR-AG03).
        struct Header: Decodable { var version: Int }
        if let header = try? JSONDecoder().decode(Header.self, from: data), header.version != AgentDefinition.schemaVersion {
            throw AgentDefinitionError.unsupportedVersion(header.version)
        }
        guard let definition = try? JSONDecoder().decode(AgentDefinition.self, from: data) else { throw AgentDefinitionError.malformed }
        try validate(definition)
        return definition
    }

    public static func validate(_ definition: AgentDefinition) throws {
        guard definition.version == AgentDefinition.schemaVersion else { throw AgentDefinitionError.unsupportedVersion(definition.version) }
        guard isID(definition.id) else { throw AgentDefinitionError.invalid("id") }
        let name = definition.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 60, !definition.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AgentDefinitionError.invalid("name")
        }
        guard isExecutable(definition.executable) else { throw AgentDefinitionError.invalid("executable") }
        for (field, list) in [("arguments", definition.arguments), ("resumeArguments", definition.resumeArguments)] {
            guard list.count <= 32, list.allSatisfy(isArgument) else { throw AgentDefinitionError.invalid(field) }
        }
        switch definition.icon {
        case .symbol(let name): guard !name.isEmpty, name.count <= 64, name.utf8.allSatisfy({ isLower($0) || isDigit($0) || $0 == 0x2e }) else { throw AgentDefinitionError.invalid("icon") }
        case .monogram(let text): guard (1...2).contains(text.count), !text.contains(where: \.isWhitespace) else { throw AgentDefinitionError.invalid("icon") }
        case .image(let file): guard isIconFile(file) else { throw AgentDefinitionError.invalid("icon") }
        }
        for (platform, recipe) in definition.install {
            guard ["darwin", "linux"].contains(platform), !recipe.command.isEmpty, recipe.command.utf8.count <= 1024,
                !recipe.command.contains(where: { $0 == "\0" || $0.isNewline }), recipe.requires.count <= 8, recipe.requires.allSatisfy(isCommandName)
            else { throw AgentDefinitionError.invalid("install") }
        }
        if let homepage = definition.homepage {
            guard homepage.count <= 512, let url = URL(string: homepage), url.scheme == "https" else { throw AgentDefinitionError.invalid("homepage") }
        }
    }

    public static func isID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...64).contains(bytes.count), isLower(bytes[0]) || isDigit(bytes[0]) else { return false }
        return bytes.allSatisfy { isLower($0) || isDigit($0) || $0 == 0x2d }
    }

    /// A bare command name, or an absolute path made of the same safe characters.
    static func isExecutable(_ value: String) -> Bool {
        guard value.hasPrefix("/") else { return isCommandName(value) }
        return value.utf8.count <= 512 && !value.contains("//") && value.split(separator: "/").allSatisfy { isCommandName(String($0)) && $0 != ".." }
    }

    static func isCommandName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...64).contains(bytes.count), bytes[0] != 0x2d else { return false }
        return bytes.allSatisfy { isLower($0) || isDigit($0) || (65...90).contains($0) || [0x2e, 0x5f, 0x2d, 0x2b].contains($0) }
    }

    static func isArgument(_ value: String) -> Bool { value.utf8.count <= 512 && !value.contains(where: { $0 == "\0" || $0.isNewline }) }

    static func isIconFile(_ value: String) -> Bool {
        guard let dot = value.lastIndex(of: "."), ["svg", "png", "pdf"].contains(value[value.index(after: dot)...]) else { return false }
        let stem = value[..<dot]
        return isID(String(stem))
    }

    private static func isLower(_ byte: UInt8) -> Bool { (97...122).contains(byte) }
    private static func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
}

public struct AgentCatalogIssue: Equatable, Sendable {
    public let filename: String
    public let message: String
}

/// Every agent this Trellis can launch: the bundled ones first, then the user's in name order.
public struct AgentCatalogSnapshot: Equatable, Sendable {
    public var definitions: [AgentDefinition] = []
    public var issues: [AgentCatalogIssue] = []
    /// Where a definition's `image` icon is read from: the user's Agents folder for theirs.
    public var iconDirectories: [String: URL] = [:]
    public init(definitions: [AgentDefinition] = [], issues: [AgentCatalogIssue] = [], iconDirectories: [String: URL] = [:]) {
        self.definitions = definitions; self.issues = issues; self.iconDirectories = iconDirectories
    }

    public func definition(_ id: String) -> AgentDefinition? { definitions.first { $0.id == id } }
}

public protocol AgentCatalogFiles: Sendable {
    func filenames(in directory: URL) throws -> [String]
    func read(_ file: URL) throws -> Data
}

public struct DiskAgentCatalogFiles: AgentCatalogFiles {
    public init() {}
    public func filenames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") && $0.hasSuffix(AgentCatalog.fileSuffix) }.sorted()
    }
    /// Regular files only, never through a symlink; the theme reader has the same rules and a larger cap.
    public func read(_ file: URL) throws -> Data { try DiskThemeLibraryFiles().read(file) }
}

public enum AgentCatalog {
    public static let reservedPrefix = "trellis-"
    public static let fileSuffix = ".agent.json"
    public static let builtInIDs = ["trellis-claude-code", "trellis-pi", "trellis-codex"]

    public static func bundled() -> [AgentDefinition] {
        builtInIDs.compactMap { id in
            guard let url = bundledFile(id + fileSuffix), let data = try? Data(contentsOf: url) else { return nil }
            return try? AgentDefinitionValidator.validate(data)
        }
    }

    /// A file shipped in the bundle's Agents folder, such as the pi extension.
    public static func bundledFile(_ name: String) -> URL? {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Trellis_TrellisCore.bundle")
        let resources = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        let url = resources.resourceURL?.appendingPathComponent("Agents", isDirectory: true).appendingPathComponent(name)
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// A user file that can't be used is listed as an issue and skipped; it never hides the others.
    public static func load(userDirectory: URL?, bundled: [AgentDefinition] = bundled(), files: any AgentCatalogFiles = DiskAgentCatalogFiles()) -> AgentCatalogSnapshot {
        var snapshot = AgentCatalogSnapshot(definitions: bundled)
        guard let userDirectory, let names = try? files.filenames(in: userDirectory) else { return snapshot }
        var user: [AgentDefinition] = []
        for filename in names {
            func issue(_ message: String) { snapshot.issues.append(AgentCatalogIssue(filename: filename, message: message)) }
            let definition: AgentDefinition
            do { definition = try AgentDefinitionValidator.validate(files.read(userDirectory.appendingPathComponent(filename))) } catch {
                issue((error as? LocalizedError)?.errorDescription ?? "The file couldn’t be read.")
                continue
            }
            guard filename == definition.id + fileSuffix else { issue("The filename must match the agent ID: \(definition.id)\(fileSuffix)."); continue }
            guard !definition.isBuiltIn else { issue("The trellis- namespace is reserved for built-in agents."); continue }
            guard !user.contains(where: { $0.id == definition.id }) else { issue("Another file already defines \(definition.id)."); continue }
            user.append(definition)
            snapshot.iconDirectories[definition.id] = userDirectory
        }
        snapshot.definitions += user.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return snapshot
    }
}
