import SwiftUI
import TrellisCore

extension Color {
    init(themeRGB rgb: UInt32) {
        self.init(
            .sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
            blue: Double(rgb & 255) / 255, opacity: 1)
    }
}
/// The cues that tell the focused pane from its neighbors (FR-P05). All are drawn over the pane, so none resizes a terminal.
struct PaneFocusStyle: Equatable {
    static let neighborDim = 0.18
    enum Header: Equatable { case plain, focused, receded }
    let header: Header
    let dim: Double

    init(focused: Bool, severalPanesVisible: Bool, windowActive: Bool, increasedContrast: Bool) {
        header = severalPanesVisible ? (focused ? .focused : .receded) : .plain
        // An inactive window is often being read beside another app, and Increase Contrast must not lose text contrast.
        dim = severalPanesVisible && !focused && windowActive && !increasedContrast ? Self.neighborDim : 0
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
    /// FR-P05. The system accent can't be measured here, so native chrome uses a fixed tint, as the sidebar selection does.
    var focusedPaneHeaderBackground: Color {
        usesNativeChrome ? Color.accentColor.opacity(0.16) : Color(themeRGB: effectiveTheme.focusedPaneHeader.rgb)
    }
    /// How a pane shows focus right now (FR-P05). Only a tab showing several panes needs telling apart.
    func paneFocusStyle(paneID: UUID, tabID: UUID, windowActive: Bool, increasedContrast: Bool) -> PaneFocusStyle {
        let panes = snapshot.tabs[tabID]?.root.paneIDs.count ?? 0
        return PaneFocusStyle(
            focused: snapshot.tabs[tabID]?.activePaneID == paneID, severalPanesVisible: panes > 1 && maximizedPanes[tabID] == nil,
            windowActive: windowActive, increasedContrast: increasedContrast)
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
