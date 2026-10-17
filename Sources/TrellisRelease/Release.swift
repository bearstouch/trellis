import Foundation

/// The committed release decision record (`release/manifest.json`).
public struct ReleaseManifest: Codable, Equatable, Sendable {
    public struct Dependency: Codable, Equatable, Sendable {
        public let name: String, version: String, revision: String, license: String, licenseFile: String
    }
    public let bundleIdentifier: String
    public let name: String
    public let version: String
    public let minimumMacOS: String
    public let architectures: [String]
    public let packageFormat: String
    public let artifacts: [String]
    public let dependencies: [Dependency]

    /// Facts read from the built product, compared with the manifest.
    public struct BuiltProduct: Equatable, Sendable {
        public var bundleIdentifier: String
        public var minimumMacOS: String
        public var architectures: Set<String>
        public var files: Set<String>
        public init(bundleIdentifier: String, minimumMacOS: String, architectures: Set<String>, files: Set<String>) {
            self.bundleIdentifier = bundleIdentifier; self.minimumMacOS = minimumMacOS; self.architectures = architectures; self.files = files
        }
    }

    /// Every mismatch between policy and product; empty means consistent.
    public func problems(packageMinimumMacOS: String, product: BuiltProduct) -> [String] {
        var problems: [String] = []
        if !["dmg", "pkg"].contains(packageFormat) { problems.append("Package format \(packageFormat) is not a DMG or signed installer.") }
        if minimumMacOS != packageMinimumMacOS { problems.append("Package.swift targets macOS \(packageMinimumMacOS) but the manifest says \(minimumMacOS).") }
        if product.minimumMacOS != minimumMacOS { problems.append("Info.plist LSMinimumSystemVersion is \(product.minimumMacOS), expected \(minimumMacOS).") }
        if product.bundleIdentifier != bundleIdentifier { problems.append("Bundle identifier is \(product.bundleIdentifier), expected \(bundleIdentifier).") }
        for architecture in architectures where !product.architectures.contains(architecture) {
            problems.append("The executable lacks the \(architecture) slice.")
        }
        for artifact in artifacts where !product.files.contains(artifact) { problems.append("Missing artifact \(artifact).") }
        for dependency in dependencies where dependency.license.isEmpty || dependency.licenseFile.isEmpty {
            problems.append("Dependency \(dependency.name) has no recorded license.")
        }
        return problems
    }
}

/// Plans the explicit, user-invoked CLI link. It only ever creates or removes
/// one symlink inside a directory under the user's home, and never edits
/// shell startup files or system directories.
public enum CLILinkPlanner {
    public static let linkName = "trellis"

    public enum Plan: Equatable, Sendable {
        case create(link: String, target: String)
        case replace(link: String, target: String)
        case alreadyInstalled(link: String)
        case remove(link: String)
        case nothingToRemove
        case refused(String)
    }

    /// What exists at the link path, injected so tests use fixtures.
    public enum Existing: Equatable, Sendable { case nothing, symlink(to: String), otherFile }

    static func standardized(_ path: String) -> String { (path as NSString).standardizingPath }

    /// The link path for a directory (`~/` expanded against `home`).
    public static func linkPath(directory: String, home: String) -> String {
        standardized((directory.hasPrefix("~/") ? home + directory.dropFirst() : directory) + "/" + linkName)
    }

    /// The directory must be inside the home directory, outside system and
    /// SSH locations. Paths are compared after `..` and `~` are resolved, and
    /// case-insensitively for sensitive folders (APFS is case-insensitive by
    /// default). Callers also validate the symlink-resolved directory.
    public static func validate(directory: String, home: String) -> String? {
        let expanded = standardized(directory.hasPrefix("~/") ? home + directory.dropFirst() : directory)
        let root = standardized(home)
        guard expanded.hasPrefix("/"), expanded.hasPrefix(root + "/") else { return "Choose a directory inside your home folder, such as ~/.local/bin." }
        let relative = String(expanded.dropFirst(root.count + 1)).lowercased()
        let forbidden = [".ssh", "library", ".gnupg", ".config/git"]
        if forbidden.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { return "That directory holds sensitive configuration; use ~/.local/bin." }
        return nil
    }

    public static func install(directory: String, home: String, cliPath: String, existing: Existing) -> Plan {
        if let problem = validate(directory: directory, home: home) { return .refused(problem) }
        let link = standardized((directory.hasPrefix("~/") ? home + directory.dropFirst() : directory) + "/" + linkName)
        switch existing {
        case .nothing: return .create(link: link, target: cliPath)
        case .symlink(let target) where target == cliPath: return .alreadyInstalled(link: link)
        // Only a link to a Trellis app's bundled CLI may be replaced (an upgrade or moved app).
        case .symlink(let target) where target.hasSuffix(".app/Contents/Helpers/\(linkName)"): return .replace(link: link, target: cliPath)
        case .symlink, .otherFile: return .refused("\(link) already exists and is not a Trellis link. Nothing was changed.")
        }
    }

    public static func remove(directory: String, home: String, existing: Existing) -> Plan {
        if let problem = validate(directory: directory, home: home) { return .refused(problem) }
        let link = standardized((directory.hasPrefix("~/") ? home + directory.dropFirst() : directory) + "/" + linkName)
        switch existing {
        case .symlink(let target) where target.hasSuffix(".app/Contents/Helpers/\(linkName)"): return .remove(link: link)
        case .nothing: return .nothingToRemove
        case .symlink, .otherFile: return .refused("\(link) is not a Trellis link. Nothing was removed.")
        }
    }
}

/// App-owned data that uninstalling may remove, as an explicit allow-list.
/// SSH configuration, keys, known_hosts, and shell history can never appear.
public enum UninstallPlanner {
    public struct Item: Equatable, Sendable {
        public let path: String
        public let description: String
    }

    public static let keychainService = "Trellis Automation"
    /// Every Keychain service Trellis creates items under: automation grants and saved-host passwords.
    public static let keychainServices = [keychainService, "Trellis SSH Host"]

    public static func items(home: String, bundleIdentifier: String = "dev.trellis", cliLink: String? = nil) -> [Item] {
        var items = [
            Item(path: "\(home)/Library/Application Support/\(bundleIdentifier)", description: "Workspace, themes, saved hosts, grants, and layout bindings"),
            Item(path: "\(home)/Library/Preferences/\(bundleIdentifier).plist", description: "Preferences"),
            Item(path: "\(home)/Library/Caches/\(bundleIdentifier)", description: "Caches"),
            Item(path: "\(home)/Library/Saved Application State/\(bundleIdentifier).savedState", description: "Window restoration state")
        ]
        if let cliLink { items.append(Item(path: cliLink, description: "CLI link (removed only if it points to Trellis)")) }
        return items.filter { isAllowed($0.path, home: home, bundleIdentifier: bundleIdentifier) }
    }

    /// Defense in depth: only the exact app-owned locations, or a `trellis`
    /// link in a directory the link planner accepts, are allowed. Protected
    /// names are matched case-insensitively.
    public static func isAllowed(_ path: String, home: String, bundleIdentifier: String = "dev.trellis") -> Bool {
        let path = CLILinkPlanner.standardized(path), home = CLILinkPlanner.standardized(home)
        let protected = ["/.ssh", "/.zsh_history", "/.bash_history", "/.zshrc", "/.bashrc", "/.profile", "/.config/fish", "/.gnupg", "/library/keychains"]
        guard path.hasPrefix(home + "/"), !protected.contains(where: { path.lowercased().contains($0) }) else { return false }
        let name = (path as NSString).lastPathComponent, parent = (path as NSString).deletingLastPathComponent
        if name == CLILinkPlanner.linkName { return CLILinkPlanner.validate(directory: parent, home: home) == nil }
        return [("Application Support", ""), ("Preferences", ".plist"), ("Caches", ""), ("Saved Application State", ".savedState")].contains {
            parent == "\(home)/Library/\($0.0)" && name == bundleIdentifier + $0.1
        }
    }
}

/// Release gate: every required piece of evidence must be present.
public struct ReleaseChecklist: Equatable, Sendable {
    public struct MatrixEntry: Equatable, Sendable {
        public let macOS: String, architecture: String, passed: Bool
        public init(macOS: String, architecture: String, passed: Bool) { self.macOS = macOS; self.architecture = architecture; self.passed = passed }
    }
    public var matrix: [MatrixEntry] = []
    public var signatureVerified = false
    public var hardenedRuntime = false
    public var notarized = false
    public var stapled = false
    public var gatekeeperOnCleanMachine = false
    public var licensesRecorded = false
    public var cliInstallVerified = false
    public var acceptanceChecksComplete = false
    public var qualificationPassed = false
    public init() {}

    /// Each missing item, in a stable order; empty means ready.
    public func missing(requiredArchitectures: [String], minimumMacOS: String) -> [String] {
        var missing: [String] = []
        for architecture in requiredArchitectures where !matrix.contains(where: { $0.architecture == architecture && $0.passed }) {
            missing.append("Tested matrix: no passing run on \(architecture).")
        }
        // Same major release as the minimum ("14.7" counts for "14.0"; "140.1" and "15.0" do not).
        let major = { (version: String) in version.split(separator: ".").first.map(String.init) }
        if !matrix.contains(where: { major($0.macOS) == major(minimumMacOS) && $0.passed }) {
            missing.append("Tested matrix: no passing run on the minimum macOS \(minimumMacOS).")
        }
        for (done, item) in [
            (signatureVerified, "Signature verification"), (hardenedRuntime, "Hardened runtime"), (notarized, "Notarization"), (stapled, "Stapled ticket"),
            (gatekeeperOnCleanMachine, "Gatekeeper check on a clean machine"), (licensesRecorded, "Dependency licenses"), (cliInstallVerified, "CLI link install/remove"),
            (acceptanceChecksComplete, "Acceptance checks"), (qualificationPassed, "Performance and reliability qualification")
        ] where !done {
            missing.append("\(item) is not evidenced.")
        }
        return missing
    }
}
