import AppKit
import SwiftTerm
import TrellisCore

@MainActor
public enum NativeTerminalFont {
    public static var installedNames: [String] {
        let fonts = NSFontManager.shared.availableFonts.compactMap { NSFont(name: $0, size: 13) }
            .filter { $0.isFixedPitch || $0.fontDescriptor.symbolicTraits.contains(.monoSpace) }
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
        TerminalFontChoice.resolve(name) { candidate in
            guard let font = NSFont(name: candidate, size: 13) else { return false }
            return font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }
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
