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
    var terminalBackground: Color { Color(themeRGB: effectiveTheme.terminal.background) }
}
