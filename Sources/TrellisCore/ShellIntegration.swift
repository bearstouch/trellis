import Foundation

/// Shells with bundled integration scripts (FR-SI01). Anything else launches
/// unchanged and Trellis claims no shell knowledge for it (INT-01).
public enum ShellIntegrationKind: String, CaseIterable, Sendable {
    case zsh, bash, fish

    public init?(executable: String) {
        self.init(rawValue: (executable as NSString).lastPathComponent)
    }
}

/// Trusted launch rewrite that loads the integration script without editing user dotfiles.
/// Applied by `LocalLaunchValidator` after reserved-key filtering, so automation
/// overrides still cannot set `TRELLIS_*` variables.
public struct ShellIntegrationInjection: Equatable, Sendable {
    public static let protocolVersion = "1"
    public let kind: ShellIntegrationKind
    public let nonce: String
    public let arguments: [String]
    public let environment: [String: String]
    /// The script the shell will load; injection is skipped when it is missing.
    public let scriptPath: String

    /// Plans injection for a login shell (`-l`) only; custom argument lists are left alone.
    public static func plan(
        kind: ShellIntegrationKind, arguments: [String], inheritedEnvironment: [String: String], resourceDirectory: String, nonce: String
    ) -> Self? {
        guard arguments == ["-l"], resourceDirectory.hasPrefix("/"), isValidNonce(nonce) else { return nil }
        let root = (resourceDirectory as NSString).standardizingPath
        var environment = ["TRELLIS_SHELL_INTEGRATION": protocolVersion, "TRELLIS_SHELL_INTEGRATION_NONCE": nonce]
        switch kind {
        case .zsh:
            environment["ZDOTDIR"] = root + "/zsh"
            if let original = inheritedEnvironment["ZDOTDIR"] { environment["TRELLIS_ZSH_ZDOTDIR"] = original }
            return Self(kind: kind, nonce: nonce, arguments: ["-l"], environment: environment, scriptPath: root + "/zsh/.zshenv")
        case .bash:
            // `--rcfile` is ignored by login shells, so the script emulates login startup instead.
            let script = root + "/bash/trellis.bash"
            environment["TRELLIS_BASH_LOGIN"] = "1"
            return Self(kind: kind, nonce: nonce, arguments: ["--rcfile", script, "-i"], environment: environment, scriptPath: script)
        case .fish:
            let original = inheritedEnvironment["XDG_DATA_DIRS"]
            environment["XDG_DATA_DIRS"] = root + ":" + (original?.isEmpty == false ? original! : "/usr/local/share:/usr/share")
            if let original { environment["TRELLIS_FISH_XDG_DATA_DIRS"] = original }
            return Self(
                kind: kind, nonce: nonce, arguments: ["-l"], environment: environment,
                scriptPath: root + "/fish/vendor_conf.d/trellis-shell-integration.fish")
        }
    }

    /// 128 random bits as lowercase hex.
    public static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<2).map { _ in String(format: "%016llx", generator.next() as UInt64) }.joined()
    }

    static func isValidNonce(_ nonce: String) -> Bool {
        nonce.utf8.count == 32 && nonce.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// The bundled scripts' directory inside the packaged or SwiftPM resource bundle.
public enum BundledShellIntegration {
    public static func directory() -> String? {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Trellis_TrellisCore.bundle")
        let resources = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        return resources.resourceURL.map { $0.appendingPathComponent("ShellIntegration").path }
    }
}

/// Where a session's shell marks come from. Remote marks (FR-SI09) carry no nonce, so they are unverified and display-only.
public enum ShellMarkOrigin: String, Sendable { case authenticated, remote }

/// An authenticated OSC 133 mark from the integration script (protocol v1, FR-SI02), or an SSH pane's unverified mark (FR-SI09).
public enum ShellIntegrationEvent: Equatable, Sendable {
    /// `directory` is nil when the reported path is missing or unusable.
    case promptStart(directory: String?)
    case commandInputStart
    case commandStart(commandLine: String?)
    case commandFinished(exitCode: Int32?)
    /// Remote only: OSC 7 `file://host/path` or OSC 1337 `CurrentDir=`.
    case reportedDirectory(String, host: String?)
    /// Remote only: OSC 1337 `RemoteHost=user@host`.
    case reportedHost(String)

    /// Scripts send at most 4,096 characters; percent-encoded UTF-8 can triple four-byte characters.
    public static let maximumPayloadBytes = 65_536
    public static let maximumCommandLineBytes = 4_096
    static let maximumHostBytes = 253

    /// Returns nil unless the mark carries the session's nonce. Marks forged by
    /// ordinary output (`cat` of a file, a remote shell) are never authenticated.
    public static func parse(_ payload: some Collection<UInt8>, nonce: String) -> Self? {
        guard ShellIntegrationInjection.isValidNonce(nonce), let mark = Mark(payload), let token = mark.options["trellis"],
            constantTimeEqual(Array(token.utf8), Array(nonce.utf8))
        else { return nil }
        switch mark.action {
        case "A": return .promptStart(directory: mark.options["cwd"].flatMap(directory))
        case "B": return .commandInputStart
        default: return mark.command
        }
    }

    /// An SSH pane's OSC 133 `A`, `C` and `D;exit` without a nonce (FR-SI09). Anything printed in the pane can
    /// forge these, so they only feed display state; a directory comes from OSC 7 or 1337 instead.
    public static func parseRemote(_ payload: some Collection<UInt8>) -> Self? {
        guard let mark = Mark(payload) else { return nil }
        return mark.action == "A" ? .promptStart(directory: nil) : mark.command
    }

    /// OSC 7 `file://host/path`, percent-encoded; the host is optional (FR-SI09).
    public static func parseRemote(osc7 payload: some Collection<UInt8>) -> Self? {
        guard payload.count <= maximumPayloadBytes, let text = String(bytes: payload, encoding: .utf8), text.lowercased().hasPrefix("file://") else { return nil }
        let rest = text.dropFirst(7)
        guard let slash = rest.firstIndex(of: "/"), let path = directory(rest[slash...]) else { return nil }
        if rest[..<slash].isEmpty { return .reportedDirectory(path, host: nil) }
        return remoteHost(rest[..<slash]).map { .reportedDirectory(path, host: $0) }
    }

    /// OSC 1337 `CurrentDir=<path>` and `RemoteHost=<user@host>`, unencoded, as iTerm2's shell integration sends them.
    public static func parseRemote(osc1337 payload: some Collection<UInt8>) -> Self? {
        guard payload.count <= maximumPayloadBytes, let text = String(bytes: payload, encoding: .utf8) else { return nil }
        if text.hasPrefix("CurrentDir=") { return absolutePath(String(text.dropFirst(11))).map { .reportedDirectory($0, host: nil) } }
        guard text.hasPrefix("RemoteHost="), let host = text.dropFirst(11).split(separator: "@", omittingEmptySubsequences: false).last else { return nil }
        return remoteHost(host).map { .reportedHost($0) }
    }

    /// OSC 133 fields: a one-letter action, positional values, and `key=value` options without duplicates.
    private struct Mark {
        var action: Substring
        var positional: [Substring] = []
        var options: [Substring: Substring] = [:]

        init?(_ payload: some Collection<UInt8>) {
            guard payload.count <= ShellIntegrationEvent.maximumPayloadBytes, let text = String(bytes: payload, encoding: .utf8) else { return nil }
            let fields = text.split(separator: ";", omittingEmptySubsequences: false)
            guard let action = fields.first, action.count == 1 else { return nil }
            self.action = action
            for field in fields.dropFirst() {
                guard let separator = field.firstIndex(of: "=") else { positional.append(field); continue }
                let key = field[..<separator]
                guard options[key] == nil else { return nil }
                options[key] = field[field.index(after: separator)...]
            }
        }

        var command: ShellIntegrationEvent? {
            switch action {
            case "C": .commandStart(commandLine: options["cmdline_url"].flatMap(ShellIntegrationEvent.commandLine))
            case "D": .commandFinished(exitCode: positional.first.flatMap { Int32($0) })
            default: nil
            }
        }
    }

    static func directory(_ encoded: Substring) -> String? { String(encoded).removingPercentEncoding.flatMap(absolutePath) }

    static func absolutePath(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.utf8.count < Int(PATH_MAX), !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        return path
    }

    /// A host name or address only: letters, digits and `.-_:[]`, so it can't carry spaces, controls or markup.
    static func remoteHost(_ host: Substring) -> String? {
        guard !host.isEmpty, host.utf8.count <= maximumHostBytes,
            host.unicodeScalars.allSatisfy({ ($0.isASCII && $0.properties.isAlphabetic) || ("0"..."9").contains($0) || ".-_:[]".unicodeScalars.contains($0) })
        else { return nil }
        return String(host)
    }

    static func commandLine(_ encoded: Substring) -> String? {
        guard let decoded = String(encoded).removingPercentEncoding, !decoded.contains("\0") else { return nil }
        var result = ""
        for character in decoded {
            guard result.utf8.count + character.utf8.count <= maximumCommandLineBytes else { break }
            result.append(character)
        }
        return result
    }

    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Runtime-only shell knowledge for one session. Never Codable, persisted or logged:
/// the command line is typed input.
public struct ShellIntegrationState: Equatable, Sendable {
    public private(set) var currentDirectory: String?
    public private(set) var commandLine: String?
    public private(set) var commandRunning = false
    public private(set) var commandStartedAt: Date?
    public private(set) var lastExitCode: Int32?
    public private(set) var lastDuration: TimeInterval?
    /// Program name of the last finished command (FR-SI08); the command line itself is never kept past `finish`.
    public private(set) var lastCommandName: String?
    /// Remote state (FR-SI09) is display-only: never a file-link base, launch directory or automation directory.
    public let origin: ShellMarkOrigin
    public private(set) var remoteHost: String?

    public init(origin: ShellMarkOrigin = .authenticated) { self.origin = origin }

    /// The last finished command exited non-zero and no newer command has started.
    public var lastCommandFailed: Bool { !commandRunning && (lastExitCode ?? 0) != 0 }

    public mutating func apply(_ event: ShellIntegrationEvent, at now: Date) {
        switch event {
        case .promptStart(let directory):
            if let directory { currentDirectory = directory }
            if commandRunning { finish(exitCode: nil, at: now) }
        case .commandInputStart: break
        case .commandStart(let line):
            commandLine = line; commandRunning = true; commandStartedAt = now
        case .commandFinished(let code):
            guard commandRunning else { return }
            finish(exitCode: code, at: now)
        case .reportedDirectory(let directory, let host):
            guard origin == .remote else { return }
            currentDirectory = directory
            if let host { remoteHost = host }
        case .reportedHost(let host):
            if origin == .remote { remoteHost = host }
        }
    }

    private mutating func finish(exitCode: Int32?, at now: Date) {
        lastCommandName = commandName
        lastExitCode = exitCode; lastDuration = commandStartedAt.map { now.timeIntervalSince($0) }
        commandRunning = false; commandLine = nil; commandStartedAt = nil
    }

    /// Program name for automatic titles: the first word, without a path or control characters.
    public var commandName: String? {
        guard commandRunning, let line = commandLine else { return nil }
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        let skipped = Set(["sudo", "exec", "time", "nohup", "command", "builtin", "env"])
        guard let word = words.first(where: { !skipped.contains($0) && !$0.contains("=") && !$0.hasPrefix("-") }) ?? words.first else {
            return nil
        }
        let name = String((word as NSString).lastPathComponent.unicodeScalars.filter { $0.properties.generalCategory != .control })
        return name.isEmpty ? nil : String(name.prefix(64))
    }

    /// The last command's duration in whole seconds: "12 s", "2 min 5 s", "1 h 3 min".
    public var durationText: String? { lastDuration.map(Self.durationText) }

    public static func durationText(_ duration: TimeInterval) -> String {
        let total = duration.isFinite ? Int(max(0, min(duration, 8_640_000))) : 0
        let (hours, minutes, seconds) = (total / 3600, total % 3600 / 60, total % 60)
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h" }
        if minutes > 0 { return seconds > 0 ? "\(minutes) min \(seconds) s" : "\(minutes) min" }
        return "\(seconds) s"
    }
}
