import SwiftUI
import UTermCore

extension Color {
    init(themeRGB rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                  blue: Double(rgb & 255) / 255, opacity: 1)
    }
}
extension AppWorkspaceModel {
    func themeColor(_ field: UIColorField) -> Color { Color(themeRGB: effectiveTheme[field].rgb) }
    var terminalBackground: Color { Color(themeRGB: effectiveTheme.terminal.background) }
}
