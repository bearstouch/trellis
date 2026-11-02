import SwiftUI
import TrellisCore

extension Color {
    init(themeRGB rgb: UInt32) {
        self.init(
            .sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
            blue: Double(rgb & 255) / 255, opacity: 1)
    }
}
extension AppWorkspaceModel {
    /// The pane header's machine name: one dark green, not a theme's success color, which is teal or yellow in some palettes.
    /// Lighter on dark chrome, where the darker shade would be hard to read.
    var machineLabelColor: Color { Color(themeRGB: effectiveTheme.appearance == .dark ? 0x259A4C : 0x1B7A3A) }

    // The original Trellis defaults retain native chrome. Bundled editor palettes
    // and imported/previewed JSON themes own their entire palette.
    var usesNativeChrome: Bool {
        previewedTheme == nil && effectiveTheme == .builtIn(effectiveTheme.appearance)
    }
    func themeColor(_ field: UIColorField) -> Color {
        guard usesNativeChrome else { return Color(themeRGB: effectiveTheme[field].rgb) }
        switch field {
        case .background, .activeTabBackground: return Color(nsColor: .textBackgroundColor)
        case .surface, .sidebarBackground: return Color(nsColor: .windowBackgroundColor)
        case .foreground, .activeTabForeground: return .primary
        case .mutedForeground: return .secondary
        case .accent: return .accentColor
        case .border: return Color(nsColor: .separatorColor)
        case .focusRing: return Color.accentColor.opacity(0.65)
        case .success, .warning, .error: return Color(themeRGB: effectiveTheme[field].rgb)
        }
    }
    var chromeTint: Color? { usesNativeChrome ? nil : themeColor(.accent) }
    // A native Divider already draws its separator; don't paint over it twice.
    var separatorOverlay: Color { usesNativeChrome ? .clear : themeColor(.border) }
    var sidebarSelectionBackground: Color {
        usesNativeChrome ? Color.accentColor.opacity(0.11) : themeColor(.activeTabBackground)
    }
    /// Readable text on an accent fill: the system accent is made for white; a theme accent picks by luminance.
    var accentForeground: Color {
        usesNativeChrome ? .white : effectiveTheme[.accent].relativeLuminance > 0.179 ? .black : .white
    }
    var terminalBackground: Color { Color(themeRGB: effectiveTheme.terminal.background) }
}
