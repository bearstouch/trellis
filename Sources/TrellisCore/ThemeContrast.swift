import Foundation

public struct ThemeContrastWarning: Equatable, Sendable {
    public let foregroundPath: String
    public let backgroundPath: String
    public let ratio: Double
    public let minimum: Double
    public var message: String {
        String(format: "%@ / %@: %.2f:1 contrast; aim for %.1f:1.", foregroundPath, backgroundPath, ratio, minimum)
    }
}

extension ResolvedTheme {
    public var contrastWarnings: [ThemeContrastWarning] {
        var warnings: [ThemeContrastWarning] = []
        func check(_ a: ThemeColor, _ b: ThemeColor, _ first: String, _ second: String, minimum: Double = 4.5) {
            let ratio = a.contrast(against: b)
            if ratio < minimum {
                warnings.append(ThemeContrastWarning(foregroundPath: first, backgroundPath: second, ratio: ratio, minimum: minimum))
            }
        }
        check(ThemeColor(terminal.foreground), ThemeColor(terminal.background), "terminal.foreground", "terminal.background")
        check(ThemeColor(terminal.selectionForeground), ThemeColor(terminal.selectionBackground), "terminal.selectionForeground", "terminal.selectionBackground")
        check(ThemeColor(terminal.cursorText), ThemeColor(terminal.cursor), "terminal.cursorText", "terminal.cursor")
        check(ThemeColor(terminal.cursor), ThemeColor(terminal.background), "terminal.cursor", "terminal.background", minimum: 3)
        // Separators provide quiet structure; focus rings communicate interaction.
        // 1.2 is a visibility advisory for separators, not a WCAG contrast target.
        for (boundary, minimum) in [(UIColorField.focusRing, 3.0), (.border, 1.2)] {
            check(self[boundary], ThemeColor(terminal.background), "ui.\(boundary.rawValue)", "terminal.background", minimum: minimum)
        }
        for background in [UIColorField.background, .surface, .sidebarBackground] {
            for foreground in [UIColorField.foreground, .mutedForeground, .accent, .success, .warning, .error] {
                check(self[foreground], self[background], "ui.\(foreground.rawValue)", "ui.\(background.rawValue)")
            }
            for (boundary, minimum) in [(UIColorField.focusRing, 3.0), (.border, 1.2)] {
                check(self[boundary], self[background], "ui.\(boundary.rawValue)", "ui.\(background.rawValue)", minimum: minimum)
            }
        }
        check(self[.activeTabForeground], self[.activeTabBackground], "ui.activeTabForeground", "ui.activeTabBackground")
        check(self[.focusRing], self[.activeTabBackground], "ui.focusRing", "ui.activeTabBackground", minimum: 3)
        return warnings
    }
}
