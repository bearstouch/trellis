import Foundation

/// A desktop notification a program asked for through OSC 9, OSC 777 `notify` or OSC 99 (FR-T08).
/// Its text is untrusted terminal output: it is shown only in the notification, never stored or logged.
public struct TerminalNotification: Equatable, Sendable {
    /// When the program wants it shown (OSC 99 `o=`); OSC 9 and 777 always use `unfocused`.
    public enum Occasion: String, Sendable { case always, unfocused, invisible }
    public static let titleLimit = 256
    public static let bodyLimit = 1024
    public let title: String
    public let body: String
    public let occasion: Occasion

    /// Nil when both parts are empty once control characters are removed.
    public init?(title: String, body: String, occasion: Occasion = .unfocused) {
        self.title = Self.sanitized(title, limit: Self.titleLimit)
        self.body = Self.sanitized(body, limit: Self.bodyLimit)
        self.occasion = occasion
        if self.title.isEmpty && self.body.isEmpty { return nil }
    }

    /// Controls (C0, DEL, C1 and bidi overrides) become spaces so output can't spoof the notification's layout.
    static func sanitized(_ text: String, limit: Int) -> String {
        // Bounded first: an OSC payload can be megabytes, and only the start can ever be shown.
        let scalars = text.unicodeScalars.prefix(limit * 4).map { scalar -> Unicode.Scalar in
            let v = scalar.value
            let control = v < 0x20 || (0x7F...0x9F).contains(v) || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
            return control ? " " : scalar
        }
        let words = String(String.UnicodeScalarView(scalars)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count > limit ? String(words.prefix(limit - 1)) + "…" : words
    }

    /// OSC 9 text (iTerm2 style). Numbered forms (`9;4;…` progress and other ConEmu commands) aren't notifications.
    public static func isNotification(osc9 data: ArraySlice<UInt8>) -> Bool {
        guard !data.isEmpty else { return false }
        let digits = data.prefix { (0x30...0x39).contains($0) }
        guard !digits.isEmpty else { return true }
        let rest = data.dropFirst(digits.count)
        return !(rest.isEmpty || rest.first == UInt8(ascii: ";"))
    }

    public static func parse(osc9 data: ArraySlice<UInt8>) -> Self? {
        guard isNotification(osc9: data) else { return nil }
        return Self(title: "", body: String(decoding: data, as: UTF8.self))
    }

    /// OSC 777 `notify;title;body` (rxvt-unicode style); the body may contain `;`.
    public static func parse(osc777 data: ArraySlice<UInt8>) -> Self? {
        let prefix = Array("notify;".utf8)
        guard data.starts(with: prefix) else { return nil }
        let parts = String(decoding: data.dropFirst(prefix.count), as: UTF8.self).split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        return Self(title: parts.first.map(String.init) ?? "", body: parts.count > 1 ? String(parts[1]) : "")
    }
}

/// kitty's desktop notification protocol (OSC 99): `99 ; key=value:key=value ; payload`.
/// Supports the title and body payloads, `d=0` chunking, base64 (`e=1`), the `o=` occasion and the `p=?` query.
/// Other payload types (icons, buttons, close, alive) are accepted and ignored.
public struct KittyNotificationAssembler: Sendable {
    public enum Event: Equatable, Sendable {
        case notification(TerminalNotification)
        /// The answer to a `p=?` query, to write back to the program.
        case reply(String)
    }
    private struct Pending: Sendable {
        var title = "", body = ""
        var occasion = TerminalNotification.Occasion.unfocused
    }
    /// Bounds memory when a program opens chunked notifications it never finishes.
    static let pendingLimit = 8
    private var pending: [(id: String, value: Pending)] = []
    public init() {}

    public mutating func receive(_ data: ArraySlice<UInt8>) -> Event? {
        guard let split = data.firstIndex(of: UInt8(ascii: ";")) else { return nil }
        var keys: [String: String] = [:]
        for item in String(decoding: data[..<split], as: UTF8.self).split(separator: ":") {
            let pair = item.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { keys[String(pair[0])] = String(pair[1]) }
        }
        let id = Self.identifier(keys["i"])
        let kind = keys["p"] ?? "title"
        // The spec has replies use `i=0` when the program sent no (usable) identifier.
        if kind == "?" { return .reply("\u{1b}]99;i=\(id.isEmpty ? "0" : id):p=?;a=focus:o=always,unfocused,invisible:p=title,body,?\u{1b}\\") }
        // Close and alive requests are about earlier notifications; they must not finish a pending one.
        if kind == "close" || kind == "alive" { return nil }
        // Bounded before decoding (a multiple of 4 keeps base64 whole): an OSC payload can be megabytes.
        let cap = TerminalNotification.bodyLimit * 4
        let raw = data[data.index(after: split)...].prefix(cap * 4)
        var text = String(decoding: raw, as: UTF8.self)
        if keys["e"] == "1" { text = Data(base64Encoded: Data(raw), options: .ignoreUnknownCharacters).map { String(decoding: $0, as: UTF8.self) } ?? "" }
        var current = take(id) ?? Pending()
        // Bounded before sanitizing: a chunk stream can't grow without limit.
        switch kind {
        case "title": current.title = String((current.title + text).prefix(cap))
        case "body": current.body = String((current.body + text).prefix(cap))
        default: break
        }
        if let occasion = keys["o"].flatMap(TerminalNotification.Occasion.init(rawValue:)) { current.occasion = occasion }
        guard keys["d"] == "0" else {
            return TerminalNotification(title: current.title, body: current.body, occasion: current.occasion).map(Event.notification)
        }
        pending.append((id, current))
        if pending.count > Self.pendingLimit { pending.removeFirst() }
        return nil
    }

    private mutating func take(_ id: String) -> Pending? {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
        return pending.remove(at: index).value
    }

    /// The spec limits identifiers to `[a-zA-Z0-9-_+.]`; anything else is dropped, so a reply never echoes other bytes.
    static func identifier(_ raw: String?) -> String {
        guard let raw, raw.utf8.count <= 64,
            raw.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_+.".unicodeScalars.contains($0)) })
        else { return "" }
        return raw
    }
}

/// Caps how many notifications one pane can post: a looping program can't flood Notification Center.
public struct NotificationRateLimiter: Sendable {
    public let limit: Int
    public let window: TimeInterval
    private var posts: [UUID: [Date]] = [:]
    public init(limit: Int = 5, window: TimeInterval = 10) { self.limit = limit; self.window = window }

    public mutating func allow(_ key: UUID, at now: Date) -> Bool {
        var recent = (posts[key] ?? []).filter { now.timeIntervalSince($0) < window }
        defer { posts[key] = recent }
        guard recent.count < limit else { return false }
        recent.append(now)
        return true
    }

    public mutating func retain(_ keys: Set<UUID>) { posts = posts.filter { keys.contains($0.key) } }
}
