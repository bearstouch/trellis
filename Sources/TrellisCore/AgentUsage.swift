import Foundation

// FR-AG22, FR-AG23: how much of an agent's subscription limits is used, read from the agent's own sign-in. Runtime only:
// nothing here is saved, and a token never leaves the single fetch that uses it.

/// Which limit a window is, named by its length so a plan with other windows (Codex Free's 30 days) still reads right.
public enum AgentUsageWindowKind: Equatable, Hashable, Sendable {
    case session, weekly, monthly
    case span(minutes: Int)
    /// A weekly limit of its own for one model ("Fable"): a smaller line under the main meters.
    case scoped(String)

    public init(minutes: Int) {
        switch minutes {
        case 300: self = .session
        case 10_080: self = .weekly
        case 40_320...44_640: self = .monthly
        default: self = .span(minutes: minutes)
        }
    }

    public var isScoped: Bool { if case .scoped = self { true } else { false } }
}

public struct AgentUsageWindow: Equatable, Sendable {
    public enum Level: Equatable, Sendable { case normal, high, critical }
    public var kind: AgentUsageWindowKind
    /// 0...100.
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(kind: AgentUsageWindowKind, usedPercent: Double, resetsAt: Date?) {
        self.kind = kind; self.resetsAt = resetsAt
        self.usedPercent = usedPercent.isFinite ? min(max(usedPercent, 0), 100) : 0
    }

    /// High from 80%, critical from 95%. The view writes the percentage too, so the level is never color alone.
    public var level: Level { usedPercent >= 95 ? .critical : usedPercent >= 80 ? .high : .normal }
}

public struct AgentUsageSnapshot: Equatable, Sendable {
    /// Main windows first (shortest first), then scoped ones, in the order reported.
    public var windows: [AgentUsageWindow]
    /// The plan's display name ("Max 5x", "Plus"); nil when unknown.
    public var plan: String?
    public var fetchedAt: Date

    public init(windows: [AgentUsageWindow], plan: String?, fetchedAt: Date) {
        let main = windows.filter { !$0.kind.isScoped }.sorted { Self.order($0.kind) < Self.order($1.kind) }
        self.windows = main + windows.filter(\.kind.isScoped); self.plan = plan; self.fetchedAt = fetchedAt
    }

    private static func order(_ kind: AgentUsageWindowKind) -> Int {
        switch kind {
        case .session: 300
        case .weekly: 10_080
        case .monthly: 43_200
        case .span(let minutes): minutes
        case .scoped: Int.max
        }
    }
}

public enum AgentUsageProblem: Equatable, Sendable {
    case notInstalled, notSignedIn, signInExpired
    /// Signed in with an API key, or a plan without limits: nothing to show.
    case noPlanLimits
    case rateLimited, failed
}

public enum AgentUsageStatus: Equatable, Sendable {
    case loading(last: AgentUsageSnapshot?)
    case ready(AgentUsageSnapshot)
    /// `last` is kept from an earlier read and shown as stale.
    case unavailable(AgentUsageProblem, last: AgentUsageSnapshot?)

    public var snapshot: AgentUsageSnapshot? {
        switch self {
        case .loading(let last), .unavailable(_, let last): last
        case .ready(let snapshot): snapshot
        }
    }
}

public enum AgentUsagePlan {
    /// "max" → "Max", "prolite" → "Pro Lite", "self_serve_business" → "Self Serve Business"; empty → nil.
    public static func displayName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, raw.count <= 64 else { return nil }
        let known = ["prolite": "Pro Lite", "promax": "Pro Max", "edu_plus": "Edu Plus", "edu_pro": "Edu Pro", "sci_plus": "Sci Plus"]
        if let name = known[raw.lowercased()] { return name }
        return raw.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " }).map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }
}

// MARK: Claude Code (FR-AG23)

/// Claude Code's sign-in, from its Keychain item. Only the access token is used, and only for one request; the refresh
/// token is never read into this type, so Trellis can't renew (and so rotate) Claude Code's sign-in.
public struct ClaudeCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let accessToken: String
    public let expiresAt: Date?
    public let plan: String?

    public init(accessToken: String, expiresAt: Date?, plan: String?) {
        self.accessToken = accessToken; self.expiresAt = expiresAt; self.plan = plan
    }

    public func isExpired(at now: Date) -> Bool { expiresAt.map { $0 <= now } ?? false }
    /// Never prints the token.
    public var description: String { "ClaudeCredential(plan: \(plan ?? "nil"), expiresAt: \(expiresAt.map { "\($0)" } ?? "nil"))" }
    public var debugDescription: String { description }
    /// `dump` and debuggers see no token either.
    public var customMirror: Mirror { Mirror(self, children: ["plan": plan as Any, "expiresAt": expiresAt as Any]) }
}

public enum ClaudeUsage {
    public static let keychainService = "Claude Code-credentials"
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let betaHeader = "oauth-2025-04-20"

    /// `{"claudeAiOauth":{"accessToken","expiresAt"(ms),"subscriptionType","rateLimitTier"}}`; nil without a token.
    public static func parseCredential(_ data: Data) -> ClaudeCredential? {
        guard data.count <= 65_536, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String, !token.isEmpty, token.utf8.count <= 8192, !token.contains(where: \.isNewline)
        else { return nil }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        var plan = AgentUsagePlan.displayName(oauth["subscriptionType"] as? String)
        // "default_claude_max_5x" → "Max 5x".
        if let plan0 = plan, let tier = oauth["rateLimitTier"] as? String, let multiple = tier.split(separator: "_").last, multiple.hasSuffix("x"),
            multiple.dropLast().allSatisfy(\.isNumber), multiple.count > 1
        {
            plan = "\(plan0) \(multiple)"
        }
        return ClaudeCredential(accessToken: token, expiresAt: expires, plan: plan)
    }

    /// The usage endpoint's `five_hour` and `seven_day` windows, and the scoped weekly ones from `limits`
    /// (else `seven_day_opus` / `seven_day_sonnet`). nil when the body isn't a JSON object.
    public static func parse(_ data: Data, plan: String?, now: Date) -> AgentUsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var windows: [AgentUsageWindow] = []
        func window(_ key: String, _ kind: AgentUsageWindowKind) {
            guard let object = root[key] as? [String: Any], let used = (object["utilization"] as? NSNumber)?.doubleValue else { return }
            windows.append(AgentUsageWindow(kind: kind, usedPercent: used, resetsAt: date(object["resets_at"])))
        }
        window("five_hour", .session)
        window("seven_day", .weekly)
        let limits = (root["limits"] as? [[String: Any]]) ?? []
        let scoped = limits.compactMap { limit -> AgentUsageWindow? in
            guard limit["kind"] as? String == "weekly_scoped", let percent = (limit["percent"] as? NSNumber)?.doubleValue,
                let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String, !model.isEmpty, model.count <= 40
            else { return nil }
            return AgentUsageWindow(kind: .scoped(model), usedPercent: percent, resetsAt: date(limit["resets_at"]))
        }
        if scoped.isEmpty {
            window("seven_day_opus", .scoped("Opus"))
            window("seven_day_sonnet", .scoped("Sonnet"))
        } else {
            windows += scoped
        }
        return AgentUsageSnapshot(windows: windows, plan: plan, fetchedAt: now)
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter(), plain = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? plain.date(from: text)
    }
}

// MARK: Codex (FR-AG23)

/// The few lines of Codex's app-server protocol (JSON-RPC 2.0, one JSON object per line on stdio) that read its limits.
public enum CodexUsage {
    public static let requestID = 2

    /// `initialize`, `initialized`, then `account/rateLimits/read`, each a line.
    public static func requestLines(version: String) -> Data {
        let messages: [[String: Any]] = [
            ["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "trellis", "title": "Trellis", "version": version]]],
            ["method": "initialized"],
            ["id": requestID, "method": "account/rateLimits/read"]
        ]
        return messages.reduce(into: Data()) { data, message in
            data += (try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            data += Data([10])
        }
    }

    public enum Reply: Equatable, Sendable {
        case result(Data)
        case error(String)
    }

    /// The reply to `account/rateLimits/read` in one line, or nil for any other line (notifications, `initialize`).
    public static func reply(in line: Data) -> Reply? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], (object["id"] as? NSNumber)?.intValue == requestID,
            object["method"] == nil
        else { return nil }
        if let error = object["error"] as? [String: Any] { return .error(String((error["message"] as? String ?? "").prefix(200))) }
        guard let result = object["result"], let data = try? JSONSerialization.data(withJSONObject: result) else { return .error("") }
        return .result(data)
    }

    /// Feeds bytes in and returns the reply once a full line holds it; keeps at most 4 MB of a line.
    public struct LineReader: Sendable {
        private var buffer = Data()
        public init() {}
        public mutating func append(_ data: Data) -> Reply? {
            buffer += data
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                if let reply = CodexUsage.reply(in: Data(line)) { return reply }
            }
            if buffer.count > 4 * 1_048_576 { buffer = Data() }
            return nil
        }

        /// At end of output: the reply on a last line without a newline, if any.
        public mutating func finish() -> Reply? {
            defer { buffer = Data() }
            return CodexUsage.reply(in: buffer)
        }
    }

    /// `GetAccountRateLimitsResponse`: `rateLimits.primary` / `.secondary` (`usedPercent`, `windowDurationMins`,
    /// `resetsAt` in Unix seconds) and `planType`. nil when the result isn't a JSON object.
    public static func parse(_ result: Data, now: Date) -> AgentUsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: result) as? [String: Any] else { return nil }
        let limits = root["rateLimits"] as? [String: Any] ?? [:]
        let windows = ["primary", "secondary"].compactMap { key -> AgentUsageWindow? in
            guard let window = limits[key] as? [String: Any], let used = (window["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
            let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue
            let resets = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            // Without a length, the protocol's own order: primary is the short window, secondary the weekly one.
            let kind = minutes.map(AgentUsageWindowKind.init(minutes:)) ?? (key == "primary" ? .session : .weekly)
            return AgentUsageWindow(kind: kind, usedPercent: used, resetsAt: resets)
        }
        return AgentUsageSnapshot(windows: windows, plan: AgentUsagePlan.displayName(limits["planType"] as? String), fetchedAt: now)
    }
}
