import Foundation

/// Which terminal-provided links may open. Output is untrusted: only web and
/// mail links, only after the user clicked them.
public enum LinkPolicy {
    public static let allowedSchemes: Set<String> = ["http", "https", "mailto"]
    public static let maximumLength = 2048
    /// A click must have happened this recently for a link request to count.
    public static let gestureWindow: TimeInterval = 1.5

    public static func url(_ link: String) -> URL? {
        guard link.utf8.count <= maximumLength,
            !link.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0 == " " }),
            let components = URLComponents(string: link), let scheme = components.scheme?.lowercased(),
            allowedSchemes.contains(scheme), var components = Optional(components)
        else { return nil }
        // Output must not add recipients or headers to a mail draft.
        if scheme == "mailto" { components.queryItems = components.queryItems?.filter { ["subject", "body"].contains($0.name.lowercased()) }.nilIfEmpty }
        guard let url = components.url else { return nil }
        // Web links need a host; credentials in the URL are never followed.
        if scheme != "mailto" { guard let host = components.host, !host.isEmpty, components.user == nil, components.password == nil else { return nil } }
        return url
    }

    /// True only for an allowed link requested within the gesture window.
    public static func mayOpen(_ link: String, lastGesture: Date?, now: Date) -> URL? {
        guard gestureIsFresh(lastGesture: lastGesture, now: now) else { return nil }
        return url(link)
    }

    public static func gestureIsFresh(lastGesture: Date?, now: Date) -> Bool {
        guard let lastGesture else { return false }
        return now.timeIntervalSince(lastGesture) >= 0 && now.timeIntervalSince(lastGesture) <= gestureWindow
    }
}

extension Array {
    fileprivate var nilIfEmpty: Self? { isEmpty ? nil : self }
}

/// Defense in depth for anything that leaves the app as text: grant tokens,
/// home-directory paths, and email addresses are replaced.
public enum SecretRedactor {
    public static func redact(_ text: String, home: String = NSHomeDirectory()) -> String {
        var result = text
        let patterns = [
            (#"trl_[A-Za-z0-9_\-]{8,}"#, "[redacted token]"),
            (#"sha256:[0-9a-f]{64}"#, "[redacted hash]"),
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "[redacted key]"),
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[redacted email]")
        ]
        for (pattern, replacement) in patterns {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        if !home.isEmpty, home != "/" { result = result.replacingOccurrences(of: home, with: "~") }
        return result
    }
}

/// Diagnostics are built only from structured, allow-listed facts — never
/// names, titles, directories, commands, output, hosts, or credentials.
public struct DiagnosticsReport: Equatable, Sendable {
    public var appVersion: String
    public var systemVersion: String
    public var architecture: String
    public var windows = 0, tabs = 0, panes = 0
    public var sessionStates: [String: Int] = [:]
    public var savedHosts = 0
    public var activeGrants = 0
    public var customThemes = 0
    public var appearanceMode = ""
    public var controlSocketRunning = false
    /// Stable error codes only (for example `LAUNCH_FAILED`), never messages.
    public var recentErrorCodes: [String] = []
    /// The only codes a report may contain.
    public static let knownErrorCodes: Set<String> = [
        "UI_ERROR", "LAUNCH_FAILED", "AUTH_REQUIRED", "PERMISSION_DENIED", "NOT_FOUND", "CONFLICT", "INVALID_STATE", "LIMIT_EXCEEDED", "CLOSE_PENDING",
        "CONFIRMATION_REQUIRED", "INVALID_CURSOR", "UNSUPPORTED_VERSION"
    ]

    public init(appVersion: String, systemVersion: String, architecture: String) {
        self.appVersion = appVersion; self.systemVersion = systemVersion; self.architecture = architecture
    }

    public mutating func count(_ snapshot: WorkspaceSnapshot) {
        windows = snapshot.windows.count
        tabs = snapshot.tabs.count
        panes = snapshot.panes.count
        sessionStates = Dictionary(grouping: snapshot.sessions.values, by: \.state.rawValue).mapValues(\.count)
    }

    /// The exact text shown in the preview and written on Save.
    public var text: String {
        let states = sessionStates.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        let codes = recentErrorCodes.filter(Self.knownErrorCodes.contains).suffix(20)
        let lines = [
            "Trellis diagnostics",
            "App version: \(appVersion)",
            "macOS: \(systemVersion)",
            "Architecture: \(architecture)",
            "Workspace: \(windows) window(s), \(tabs) tab(s), \(panes) pane(s)",
            "Sessions: \(states.isEmpty ? "none" : states)",
            "Saved hosts: \(savedHosts)",
            "Active automation grants: \(activeGrants)",
            "Custom themes: \(customThemes)",
            "Appearance mode: \(appearanceMode)",
            "Control socket: \(controlSocketRunning ? "running" : "not running")",
            "Recent error codes: \(codes.isEmpty ? "none" : codes.joined(separator: ", "))",
            "",
            "Not included: window/tab/pane names, directories, commands, terminal output, typed input, hosts, keys, tokens, or clipboard contents."
        ]
        return SecretRedactor.redact(lines.joined(separator: "\n"))
    }
}
