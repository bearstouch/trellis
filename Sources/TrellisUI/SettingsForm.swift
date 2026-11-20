import SwiftUI
import TrellisCore

/// The layout every settings pane shares: grouped sections of rows, each with its control on the right and its help
/// text under the label, so a long explanation never pushes the control out of line.
extension View {
    /// A grouped form over the pane's own background.
    func settingsFormStyle() -> some View { formStyle(.grouped).scrollContentBackground(.hidden) }
}

/// A row's label with its help text underneath. Spoken as one label: the help is part of what the control does.
struct SettingsLabel: View {
    let title: String
    var help: String?
    var helpColor: Color?
    init(_ title: String, help: String? = nil, helpColor: Color? = nil) {
        self.title = title; self.help = help; self.helpColor = helpColor
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let help {
                Text(help).font(.subheadline).foregroundStyle(helpColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Help text on a row of its own, such as a status note under a group's controls.
struct SettingsNote: View {
    let text: String
    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// The bar under a settings form that holds its result message and main buttons.
struct SettingsFooter<Buttons: View>: View {
    var message: String?
    var identifier = "settings.result"
    @ViewBuilder var buttons: Buttons
    var body: some View {
        HStack(spacing: 8) {
            if let message { Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(identifier) }
            Spacer(minLength: 0)
            buttons
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

/// Settings → Appearance's mode choice: a tile per mode showing a small window in the light or dark theme it uses,
/// with System split between the two. Plain buttons, not a segmented `Picker` (see ``SegmentedPicker``).
struct AppearanceModePicker: View {
    let selection: ChromeMode
    let light: ResolvedTheme
    let dark: ResolvedTheme
    let onSelect: (ChromeMode) -> Void
    static let modes: [ChromeMode] = [.system, .light, .dark]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Self.modes, id: \.self) { mode in tile(mode) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Application appearance"))
        .accessibilityIdentifier("settings.chromeMode")
    }

    private func themeNames(_ mode: ChromeMode) -> String {
        switch mode {
        case .system: "\(light.name) · \(dark.name)"
        case .light: light.name
        case .dark: dark.name
        }
    }

    private func tile(_ mode: ChromeMode) -> some View {
        let selected = mode == selection
        return Button {
            onSelect(mode)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    ThemeMiniWindow(theme: mode == .dark ? dark : light)
                    if mode == .system { ThemeMiniWindow(theme: dark).clipShape(DiagonalHalf()) }
                }
                .frame(height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator), lineWidth: selected ? 3 : 1)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.localizedTitle).fontWeight(selected ? .semibold : .regular)
                    Text(themeNames(mode)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(.leading, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.localizedTitle)
        .accessibilityValue(themeNames(mode))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.chromeMode.\(mode.rawValue)")
    }
}

/// A small window in a theme's colors: title bar and a terminal with a prompt. Decorative; the tile names the theme.
private struct ThemeMiniWindow: View {
    let theme: ResolvedTheme
    private func color(_ rgb: UInt32) -> Color { Color(themeRGB: rgb) }
    var body: some View {
        let terminal = theme.terminal
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) { Circle().fill(color($0)).frame(width: 6, height: 6) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7).frame(height: 16).background(color(theme[.surface].rgb))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "~/trellis").foregroundColor(color(terminal.ansi[2])) + Text(verbatim: " $ swift test").foregroundColor(color(terminal.foreground))
                Text(verbatim: "Test Suite").foregroundColor(color(terminal.ansi[4])) + Text(verbatim: " passed").foregroundColor(color(terminal.foreground))
                Text(verbatim: "~/trellis").foregroundColor(color(terminal.ansi[2])) + Text(verbatim: " $ ").foregroundColor(color(terminal.foreground))
                    + Text(verbatim: "▍").foregroundColor(color(terminal.cursor))
            }
            .font(.system(size: 9, design: .monospaced)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(color(terminal.background))
        }
        .accessibilityHidden(true)
    }
}

/// The right part of a tile, cut on a slant: System's dark half.
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.58, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
