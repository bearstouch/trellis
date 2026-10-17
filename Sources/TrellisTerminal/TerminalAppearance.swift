import AppKit
import SwiftTerm
import TrellisCore

@MainActor
public enum NativeTerminalFont {
    private static var registered = false
    /// Process-scoped so the bundled faces never leak into the user's font library.
    /// Idempotent; a missing or damaged face falls back through `TerminalFontChoice`.
    public static func registerBundledFonts() {
        guard !registered else { return }
        registered = true
        // Synchronous per-URL registration: the batch API registers asynchronously,
        // so the first terminal would otherwise resolve the fallback font.
        for url in BundledFonts.urls() { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }

    public static var installedNames: [String] {
        registerBundledFonts()
        let fonts = NSFontManager.shared.availableFonts.compactMap { NSFont(name: $0, size: 13) }
            .filter(isMonospaced)
        let families = Dictionary(grouping: fonts) { $0.familyName ?? $0.fontName }
        return families.values.compactMap { faces in
            faces.sorted { a, b in
                func score(_ font: NSFont) -> Int {
                    let traits = font.fontDescriptor.symbolicTraits
                    return (traits.contains(.bold) ? 100 : 0) + (traits.contains(.italic) ? 100 : 0)
                        + abs(NSFontManager.shared.weight(of: font) - 5)
                }
                let left = score(a), right = score(b)
                return left == right ? a.fontName < b.fontName : left < right
            }.first?.fontName
        }.sorted { typefaceName(for: $0).localizedStandardCompare(typefaceName(for: $1)) == .orderedAscending }
    }

    public static func typefaceName(for name: String) -> String {
        NSFont(name: name, size: 13)?.familyName ?? name
    }

    public static func choice(for name: String) -> TerminalFontChoice {
        registerBundledFonts()
        return TerminalFontChoice.resolve(name) { candidate in
            NSFont(name: candidate, size: 13).map(isMonospaced) ?? false
        }
    }
    /// Some monospace faces, including bundled Roboto Mono 3.001, leave the fixed-pitch
    /// flags unset, so uniform advances across narrow and wide glyphs also qualify.
    static func isMonospaced(_ font: NSFont) -> Bool {
        if font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace) { return true }
        let characters = Array("iIl.W@m0 ".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) else { return false }
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        return advances[0].width > 0 && advances.allSatisfy { abs($0.width - advances[0].width) < 0.01 }
    }
    static func font(_ choice: TerminalFontChoice, size: Double) -> NSFont {
        choice.name.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

extension TerminalPalette {
    @MainActor func apply(to view: AccessibleTerminalView) {
        // Theme indexes 0–15 must not derive new 256-color cube values.
        view.getTerminal().ansi256PaletteStrategy = .xterm
        func color(_ rgb: UInt32) -> NSColor {
            NSColor(
                srgbRed: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                blue: Double(rgb & 255) / 255, alpha: 1)
        }
        view.nativeBackgroundColor = color(background)
        view.nativeForegroundColor = color(foreground)
        view.caretColor = color(cursor)
        view.getTerminal().cursorColor = SwiftTerm.Color(red8: UInt16((cursor >> 16) & 255), green8: UInt16((cursor >> 8) & 255), blue8: UInt16(cursor & 255))
        view.caretTextColor = color(cursorText)
        view.selectedTextBackgroundColor = color(selectionBackground)
        view.selectedTextForegroundColor = color(selectionForeground)
        view.installColors(ansi.map { Color(red8: UInt16(($0 >> 16) & 255), green8: UInt16(($0 >> 8) & 255), blue8: UInt16($0 & 255)) })
    }
}
