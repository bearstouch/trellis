import Foundation

public enum ChromeMode: String, Codable, CaseIterable, Sendable {
    case light, dark, system
    public func isDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .light: false;
        case .dark: true;
        case .system: systemIsDark
        }
    }
}

public enum TerminalCursorShape: String, Codable, CaseIterable, Sendable { case block, underline, bar }

/// What a BEL does (FR-T07). Attention requests (FR-T06) fire whatever the style.
public enum TerminalBellStyle: String, Codable, CaseIterable, Sendable {
    case sound, visual, soundAndVisual, off
    public var displayName: String {
        switch self {
        case .sound: "Sound";
        case .visual: "Visual flash";
        case .soundAndVisual: "Sound and flash";
        case .off: "Off"
        }
    }
}

public struct AppearanceSettings: Codable, Equatable, Sendable {
    public var chromeMode: ChromeMode = .dark
    public static let defaultFontName = "RobotoMono-Regular"
    public var fontName = Self.defaultFontName
    public var fontSize: Double = 13
    public var cursorShape: TerminalCursorShape = .block
    public var cursorBlinks = false
    public var scrollbackLines = 10_000
    public var lightThemeID = "trellis-light"
    public var darkThemeID = "trellis-dark"
    // Text rendering (FR-TX01, FR-TX03).
    public var fontLigatures = true
    public var boldAsBright = true
    public var allowBoldFont = true
    public var allowItalicFont = true
    public var blinkingText = true
    public var bellStyle: TerminalBellStyle = .sound
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case chromeMode, fontName, fontSize, cursorShape, cursorBlinks, scrollbackLines, lightThemeID, darkThemeID
        case fontLigatures, boldAsBright, allowBoldFont, allowItalicFont, blinkingText, bellStyle
    }
    /// Settings saved before the text-rendering and bell keys existed load with their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chromeMode = try c.decode(ChromeMode.self, forKey: .chromeMode)
        fontName = try c.decode(String.self, forKey: .fontName)
        fontSize = try c.decode(Double.self, forKey: .fontSize)
        cursorShape = try c.decode(TerminalCursorShape.self, forKey: .cursorShape)
        cursorBlinks = try c.decode(Bool.self, forKey: .cursorBlinks)
        scrollbackLines = try c.decode(Int.self, forKey: .scrollbackLines)
        lightThemeID = try c.decode(String.self, forKey: .lightThemeID)
        darkThemeID = try c.decode(String.self, forKey: .darkThemeID)
        fontLigatures = try c.decodeIfPresent(Bool.self, forKey: .fontLigatures) ?? true
        boldAsBright = try c.decodeIfPresent(Bool.self, forKey: .boldAsBright) ?? true
        allowBoldFont = try c.decodeIfPresent(Bool.self, forKey: .allowBoldFont) ?? true
        allowItalicFont = try c.decodeIfPresent(Bool.self, forKey: .allowItalicFont) ?? true
        blinkingText = try c.decodeIfPresent(Bool.self, forKey: .blinkingText) ?? true
        // A style added by a newer build falls back to Sound instead of discarding every appearance setting.
        bellStyle = (try? c.decodeIfPresent(TerminalBellStyle.self, forKey: .bellStyle)) ?? .sound
    }
    /// True when terminals must be updated: everything except chrome mode and theme selection.
    public func terminalRenderingDiffers(from other: Self) -> Bool {
        var normalized = self
        (normalized.chromeMode, normalized.lightThemeID, normalized.darkThemeID) = (other.chromeMode, other.lightThemeID, other.darkThemeID)
        return normalized != other
    }
    mutating func migrateLegacyThemeIDs() {
        if lightThemeID == "uterm-light" { lightThemeID = "trellis-light" }
        if darkThemeID == "uterm-dark" { darkThemeID = "trellis-dark" }
    }
    public var isValid: Bool {
        fontSize.isFinite && (8...48).contains(fontSize) && (0...50_000).contains(scrollbackLines)
            && [fontName, lightThemeID, darkThemeID].allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256
            }
    }
    public func themeID(systemIsDark: Bool) -> String {
        chromeMode.isDark(systemIsDark: systemIsDark) ? darkThemeID : lightThemeID
    }
}

public struct TerminalFontChoice: Equatable, Sendable {
    /// nil denotes the platform's monospaced system font.
    public let name: String?
    public let notice: String?
    public static func resolve(_ requested: String, available: (String) -> Bool) -> Self {
        if available(requested) { return Self(name: requested, notice: nil) }
        let fallback = available("Menlo") ? "Menlo" : nil
        return Self(name: fallback, notice: "\(requested) is unavailable or not monospaced. Using \(fallback ?? "the system monospace font").")
    }
}

/// Color-only built-ins. Chrome follows native AppKit appearance independently.
public struct TerminalPalette: Equatable, Sendable {
    public let background: UInt32
    public let foreground: UInt32
    public let cursor: UInt32
    public let cursorText: UInt32
    public let selectionBackground: UInt32
    public let selectionForeground: UInt32
    public let ansi: [UInt32]
    init(
        background: UInt32 = 0x151719, foreground: UInt32 = 0xDEE0E5, cursor: UInt32 = 0xB9DCFF,
        cursorText: UInt32 = 0x151719, selectionBackground: UInt32 = 0x354C6A, selectionForeground: UInt32 = 0xFFFFFF,
        ansi: [UInt32] = [
            0x1B202A, 0xEF8585, 0x8DDAA4, 0xF2CC7A, 0x8BB8F0, 0xC6A0E8, 0x7FD5DD, 0xCFD7E2,
            0x7C899C, 0xFFA4A4, 0xB3EFBC, 0xFFE3A3, 0xB9DCFF, 0xE4BDFF, 0xA7F2F5, 0xFFFFFF
        ]
    ) {
        self.background = background; self.foreground = foreground; self.cursor = cursor; self.cursorText = cursorText
        self.selectionBackground = selectionBackground; self.selectionForeground = selectionForeground; self.ansi = ansi
    }
    public static let builtIn = Self()
}
