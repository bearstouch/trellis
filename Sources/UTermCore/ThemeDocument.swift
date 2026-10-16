import Foundation

public enum ThemeAppearance: String, CaseIterable, Sendable { case light, dark }
public enum TerminalColorField: String, CaseIterable, Sendable {
    case background, foreground, cursor, cursorText, selectionBackground, selectionForeground
}
public enum UIColorField: String, CaseIterable, Sendable {
    case background, surface, sidebarBackground, foreground, mutedForeground, accent, border
    case activeTabBackground, activeTabForeground, focusRing, success, warning, error
}

public struct ThemeColor: Equatable, Hashable, Sendable {
    public let rgb: UInt32
    public init?(hex: String) {
        let bytes = Array(hex.utf8)
        guard bytes.count == 7, bytes[0] == 35,
              bytes.dropFirst().allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        rgb = value
    }
    init(_ rgb: UInt32) { self.rgb = rgb }
    public var hex: String { String(format: "#%06X", rgb) }
    public var relativeLuminance: Double {
        func linear(_ channel: UInt32) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear((rgb >> 16) & 255) + 0.7152 * linear((rgb >> 8) & 255) + 0.0722 * linear(rgb & 255)
    }
    public func contrast(against other: Self) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// Only the validator creates documents, so resolution always has known fields,
/// well-formed colors, and either no ANSI override or exactly sixteen entries.
public struct ThemeDocument: Equatable, Sendable {
    public let id: String
    public let name: String
    public let appearance: ThemeAppearance
    public let terminal: [TerminalColorField: ThemeColor]
    public let ansi: [ThemeColor]?
    public let ui: [UIColorField: ThemeColor]
    /// Installation reserves this namespace; built-ins are constructed in code.
    public var hasReservedID: Bool { id.hasPrefix("uterm-") }

    public func resolved() -> ResolvedTheme {
        let base = ResolvedTheme.builtIn(appearance)
        let inherited = base.terminal
        func color(_ field: TerminalColorField, _ fallback: UInt32) -> UInt32 { terminal[field]?.rgb ?? fallback }
        let palette = TerminalPalette(
            background: color(.background, inherited.background), foreground: color(.foreground, inherited.foreground),
            cursor: color(.cursor, inherited.cursor), cursorText: color(.cursorText, inherited.cursorText),
            selectionBackground: color(.selectionBackground, inherited.selectionBackground),
            selectionForeground: color(.selectionForeground, inherited.selectionForeground), ansi: ansi?.map(\.rgb) ?? inherited.ansi)
        return ResolvedTheme(id: id, name: name, appearance: appearance, terminal: palette,
                             ui: base.ui.merging(ui) { _, override in override })
    }
}

public struct ResolvedTheme: Equatable, Sendable {
    public let id: String
    public let name: String
    public let appearance: ThemeAppearance
    public let terminal: TerminalPalette
    private let uiColors: [UIColorField: ThemeColor]
    public subscript(_ field: UIColorField) -> ThemeColor { uiColors[field]! }
    fileprivate var ui: [UIColorField: ThemeColor] { uiColors }
    fileprivate init(id: String, name: String, appearance: ThemeAppearance, terminal: TerminalPalette, ui: [UIColorField: ThemeColor]) {
        self.id = id; self.name = name; self.appearance = appearance; self.terminal = terminal; uiColors = ui
    }
    public static func builtIn(_ appearance: ThemeAppearance) -> Self {
        let light: [UInt32] = [0xFFFFFF, 0xF2F5F9, 0xE8EDF4, 0x18212F, 0x4E5B6D, 0x185AA8, 0x758397,
                               0xC8DDF5, 0x18212F, 0x2869B5, 0x216B3B, 0x805400, 0xB22D32]
        let dark: [UInt32] = [0x141820, 0x202735, 0x10141B, 0xE8EEF4, 0xB0BAC9, 0x8BC7FF, 0x66758B,
                              0x354C6A, 0xFFFFFF, 0x8BC7FF, 0x8DDAA4, 0xF2CC7A, 0xFFA4A4]
        let values = appearance == .light ? light : dark
        return Self(id: "uterm-\(appearance.rawValue)", name: "uTerm \(appearance.rawValue.capitalized)", appearance: appearance,
                    terminal: .builtIn, ui: Dictionary(uniqueKeysWithValues: zip(UIColorField.allCases, values.map(ThemeColor.init))))
    }
}

public enum ThemeValidator {
    public static let maximumBytes = 64 * 1024
    public static func validate(_ data: Data) throws -> ThemeDocument {
        let root = try object(ThemeJSON.parse(data), path: "$")
        try known(root, allowed: ["version", "id", "name", "appearance", "terminal", "ui"], path: "$")
        let version = try required(root, key: "version")
        guard case .number(let number) = version else { throw error("$.version", .wrongType, "Expected the number 1.") }
        guard isVersionOne(number) else { throw error("$.version", .unsupportedVersion, "Only theme version 1 is supported.") }
        let id = try string(required(root, key: "id"), path: "$.id")
        let bytes = Array(id.utf8)
        guard (1...64).contains(bytes.count), let first = bytes.first, (97...122).contains(first),
              bytes.dropFirst().allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
            throw error("$.id", .invalidID, "Use 1–64 lowercase letters, digits, or hyphens, beginning with a letter.")
        }
        let name = try string(required(root, key: "name"), path: "$.name")
        guard (1...100).contains(name.unicodeScalars.count) else { throw error("$.name", .invalidName, "Use a name of 1–100 Unicode characters.") }
        let appearanceText = try string(required(root, key: "appearance"), path: "$.appearance")
        guard let appearance = ThemeAppearance(rawValue: appearanceText) else { throw error("$.appearance", .invalidAppearance, "Choose light or dark.") }
        var terminal: [TerminalColorField: ThemeColor] = [:], ansi: [ThemeColor]?
        if let value = root["terminal"] {
            let fields = try object(value, path: "$.terminal")
            try known(fields, allowed: Set(TerminalColorField.allCases.map(\.rawValue) + ["ansi"]), path: "$.terminal")
            for field in TerminalColorField.allCases {
                if let value = fields[field.rawValue] { terminal[field] = try color(value, path: "$.terminal.\(field.rawValue)") }
            }
            if let value = fields["ansi"] {
                guard case .array(let values) = value else { throw error("$.terminal.ansi", .wrongType, "Expected an array of 16 colors.") }
                guard values.count == 16 else { throw error("$.terminal.ansi", .invalidANSI, "Supply exactly 16 colors in terminal index order.") }
                ansi = try values.enumerated().map { try color($0.element, path: "$.terminal.ansi[\($0.offset)]") }
            }
        }
        var ui: [UIColorField: ThemeColor] = [:]
        if let value = root["ui"] {
            let fields = try object(value, path: "$.ui")
            try known(fields, allowed: Set(UIColorField.allCases.map(\.rawValue)), path: "$.ui")
            for field in UIColorField.allCases {
                if let value = fields[field.rawValue] { ui[field] = try color(value, path: "$.ui.\(field.rawValue)") }
            }
        }
        return ThemeDocument(id: id, name: name, appearance: appearance, terminal: terminal, ansi: ansi, ui: ui)
    }
    private static func error(_ path: String, _ code: ThemeValidationError.Code, _ reason: String) -> ThemeValidationError {
        ThemeValidationError(path: path, code: code, reason: reason)
    }
    private static func object(_ value: ThemeJSON, path: String) throws -> [String: ThemeJSON] {
        guard case .object(let fields) = value else { throw error(path, .wrongType, "Expected an object.") }
        return fields
    }
    private static func known(_ fields: [String: ThemeJSON], allowed: Set<String>, path: String) throws {
        if let key = fields.keys.sorted().first(where: { !allowed.contains($0) }) { throw error(path + "." + key, .unknownField, "Unknown field.") }
    }
    private static func required(_ fields: [String: ThemeJSON], key: String) throws -> ThemeJSON {
        guard let value = fields[key] else { throw error("$." + key, .missingField, "Required field is missing.") }
        return value
    }
    private static func string(_ value: ThemeJSON, path: String) throws -> String {
        guard case .string(let text) = value else { throw error(path, .wrongType, "Expected a string.") }
        return text
    }
    private static func color(_ value: ThemeJSON, path: String) throws -> ThemeColor {
        let text = try string(value, path: path)
        guard let color = ThemeColor(hex: text) else { throw error(path, .invalidColor, "Use an opaque #RRGGBB color.") }
        return color
    }
    /// Compare JSON numbers exactly, without floating-point rounding of values
    /// such as 1.00000000000000000001 into an accepted schema version.
    private static func isVersionOne(_ text: String) -> Bool {
        guard !text.hasPrefix("-") else { return false }
        let parts = text.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        guard let exponent = parts.count == 2 ? Int(parts[1]) : 0 else { return false }
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let fraction = mantissa.count == 2 ? mantissa[1].count : 0
        let digits = mantissa.joined()
        let withoutLeading = digits.drop(while: { $0 == "0" })
        let significant = withoutLeading.reversed().drop(while: { $0 == "0" }).reversed()
        let zeros = withoutLeading.count - significant.count
        return String(significant) == "1" && exponent == fraction - zeros
    }
}
