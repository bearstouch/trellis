import Darwin
import Foundation
import UniformTypeIdentifiers

/// Where a pane's file links resolve. Only local panes supply one (FR-L04).
public struct FileLinkContext: Equatable, Sendable {
    /// The authenticated shell-integration directory; relative paths need it.
    public var currentDirectory: String?
    public var homeDirectory: String
    /// Lowercased names a `file://` host may use; empty and `localhost` are always local.
    public var localHostNames: Set<String>

    public init(currentDirectory: String?, homeDirectory: String, localHostNames: Set<String> = FileLinkContext.systemHostNames) {
        self.currentDirectory = currentDirectory; self.homeDirectory = homeDirectory; self.localHostNames = localHostNames
    }

    /// From `gethostname`, which never blocks on DNS (unlike `ProcessInfo.hostName`).
    public static var systemHostNames: Set<String> {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return [] }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased()
        guard !name.isEmpty else { return [] }
        return name.hasSuffix(".local") ? [name, String(name.dropLast(6))] : [name, name + ".local"]
    }
}

public enum TerminalLinkTarget: Equatable, Sendable {
    case web(URL)
    case file(path: String, line: Int?, column: Int?)
}

public enum FileLinkAction: Equatable, Sendable {
    case open(URL)
    case reveal(URL)
}

/// What the file system says about a link target, after resolving symbolic links.
public struct FileFacts: Equatable, Sendable {
    public enum Kind: Sendable { case regular, directory, other }
    public var resolvedPath: String
    public var kind: Kind
    public var isPackage = false
    public var isExecutable = false
    /// The content type is an application, script, executable, installer, disk image or alias.
    public var isLaunchableType = false

    public init(resolvedPath: String, kind: Kind, isPackage: Bool = false, isExecutable: Bool = false, isLaunchableType: Bool = false) {
        self.resolvedPath = resolvedPath; self.kind = kind
        self.isPackage = isPackage; self.isExecutable = isExecutable; self.isLaunchableType = isLaunchableType
    }
}

/// Injected so tests never depend on the real file system.
public struct FileProbe: Sendable {
    public var facts: @Sendable (String) -> FileFacts?
    public init(facts: @escaping @Sendable (String) -> FileFacts?) { self.facts = facts }

    public static let live = FileProbe { path in
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isExecutableKey, .contentTypeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let kind: FileFacts.Kind = values.isRegularFile == true ? .regular : values.isDirectory == true ? .directory : .other
        let launchable: [UTType] = [
            .executable, .unixExecutable, .application, .applicationBundle, .script, .shellScript, .package, .diskImage, .resolvable, .aliasFile, .bundle
        ]
        // Any execute bit counts (FR-L03): `isExecutableKey` only asks whether this user may run it.
        var status = stat()
        let anyExecuteBit = stat(url.path, &status) == 0 && status.st_mode & 0o111 != 0
        return FileFacts(
            resolvedPath: url.path, kind: kind, isPackage: values.isPackage == true,
            isExecutable: kind == .regular && (anyExecuteBit || values.isExecutable == true),
            isLaunchableType: values.contentType.map { type in launchable.contains { type.conforms(to: $0) } } ?? false)
    }
}

/// Turns a clicked terminal link into something Trellis may open. Output is
/// untrusted: only vetted web links, and local files when the pane allows them.
public enum TerminalLinkClassifier {
    /// - Parameter explicit: the link came from an OSC 8 hyperlink rather than the visible text.
    public static func classify(_ link: String, explicit: Bool, files: FileLinkContext?) -> TerminalLinkTarget? {
        if let url = LinkPolicy.url(link) { return .web(url) }
        guard let files, link.utf8.count <= LinkPolicy.maximumLength, !link.unicodeScalars.contains(where: isControl) else { return nil }
        if link.lowercased().hasPrefix("file:") { return fileURL(link, files: files) }
        if hasScheme(link) { return nil }
        // An OSC 8 target is hidden behind its visible text; only `file://` names a local file.
        guard !explicit else { return nil }
        return path(SmartSelection.trimmed(link), files: files)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.generalCategory == .control }

    /// `ssh:host`, `tel:123` and `x-app:do` are schemes; `notes.txt:12` is a path with a line number.
    private static func hasScheme(_ link: String) -> Bool {
        guard let colon = link.firstIndex(of: ":") else { return false }
        let scheme = link[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
            scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) })
        else { return false }
        return !scheme.contains(".") || !(link[link.index(after: colon)...].first?.isNumber ?? false)
    }

    private static func fileURL(_ link: String, files: FileLinkContext) -> TerminalLinkTarget? {
        guard let components = URLComponents(string: link), components.user == nil, components.password == nil, components.port == nil,
            components.query == nil
        else { return nil }
        var host = (components.host ?? "").lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard host.isEmpty || host == "localhost" || files.localHostNames.contains(host) else { return nil }
        let path = components.path
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: isControl) else { return nil }
        return checked(URL(fileURLWithPath: path).standardized.path, line: nil, column: nil)
    }

    private static func path(_ text: String, files: FileLinkContext) -> TerminalLinkTarget? {
        var path = text, line: Int?, column: Int?
        // `file.swift:12:5` and `file.swift:12` as printed by compilers and grep.
        for _ in 0..<2 {
            guard let colon = path.lastIndex(of: ":"), let number = Int(path[path.index(after: colon)...]), number > 0 else { break }
            column = line; line = number
            path = String(path[..<colon])
        }
        if line == nil { column = nil }
        guard !path.isEmpty else { return nil }
        let absolute: String
        if path == "~" || path.hasPrefix("~/") {
            guard files.homeDirectory.hasPrefix("/") else { return nil }
            absolute = files.homeDirectory + path.dropFirst()
        } else if path.hasPrefix("/") {
            absolute = path
        } else if path.hasPrefix("~") || path.hasPrefix("$") {
            return nil  // Other users' homes and variables would need the remote shell to expand.
        } else {
            guard let directory = files.currentDirectory, directory.hasPrefix("/") else { return nil }
            absolute = directory + "/" + path
        }
        return checked(URL(fileURLWithPath: absolute).standardized.path, line: line, column: column)
    }

    private static func checked(_ path: String, line: Int?, column: Int?) -> TerminalLinkTarget? {
        guard path.hasPrefix("/"), path.utf8.count <= FileLinkPolicy.maximumPathLength else { return nil }
        // Probing an automount path makes the Mac contact the host that output named.
        let root = path.split(separator: "/").first?.lowercased()
        guard root != "net", root != "network" else { return nil }
        return .file(path: path, line: line, column: column)
    }
}

/// Opening a file must never run code (FR-L03): anything launchable is only revealed.
public enum FileLinkPolicy {
    public static let maximumPathLength = 1024
    public static let launchableExtensions: Set<String> = [
        "app", "command", "tool", "sh", "bash", "zsh", "csh", "tcsh", "ksh", "fish", "py", "pl", "rb", "scpt", "scptd", "applescript",
        "workflow", "action", "terminal", "pkg", "mpkg", "dmg", "jar", "webloc", "inetloc", "fileloc", "mobileconfig", "prefpane", "kext",
        "shortcut", "saver", "plugin", "osax", "qlgenerator", "systemextension", "appex", "url", "desktop", "alias"
    ]

    /// Nil when nothing should happen: a missing file, or a device, socket or FIFO.
    public static func action(path: String, probe: FileProbe = .live) -> FileLinkAction? {
        guard let facts = probe.facts(path) else { return nil }
        let url = URL(fileURLWithPath: facts.resolvedPath)
        let launchableName = launchableExtensions.contains(url.pathExtension.lowercased())
        switch facts.kind {
        case .other: return nil
        case .directory: return facts.isPackage || facts.isLaunchableType || launchableName ? .reveal(url) : .open(url)
        case .regular: return facts.isExecutable || facts.isLaunchableType || facts.isPackage || launchableName ? .reveal(url) : .open(url)
        }
    }
}
