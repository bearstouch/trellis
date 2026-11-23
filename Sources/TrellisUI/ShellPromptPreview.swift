import SwiftUI
import TrellisCore

/// A preset prompt drawn in the current theme's terminal colors and font (FR-SI10): no shell runs, nothing is saved.
struct ShellPromptPreview: View {
    let preset: ShellPromptPreset
    let theme: ResolvedTheme
    let appearance: AppearanceSettings
    var sample = ShellPromptSample.example

    private func color(_ segment: ShellPromptSegment) -> Color {
        let palette = theme.terminal
        guard let index = segment.color, palette.ansi.indices.contains(index) else { return Color(themeRGB: palette.foreground) }
        // Bold basic colors draw bright, as the terminal does with "Bold as bright colors" on.
        let bright = segment.bold && appearance.boldAsBright && index < 8 && palette.ansi.indices.contains(index + 8)
        return Color(themeRGB: palette.ansi[bright ? index + 8 : index])
    }

    private func line(_ segments: [ShellPromptSegment]) -> Text {
        segments.reduce(Text(verbatim: "")) { text, segment in
            text + Text(verbatim: segment.text).foregroundColor(color(segment)).fontWeight(segment.bold && appearance.allowBoldFont ? .bold : .regular)
        }
    }

    /// A finished command, then the prompt waiting with the cursor; presets that show failure add a failed `false`.
    private var rows: [(Text, String)] {
        let cursor = Text(verbatim: "▍").foregroundColor(Color(themeRGB: theme.terminal.cursor))
        let command = { (name: String) in Text(verbatim: name).foregroundColor(Color(themeRGB: theme.terminal.foreground)) }
        func prompt(failed: Bool, then tail: Text) -> [(Text, String)] {
            let lines = preset.preview(sample, failed: failed)
            let texts = preset.previewText(sample, failed: failed)
            return lines.indices.map { index in
                index == lines.count - 1 ? (line(lines[index]) + tail, texts[index]) : (line(lines[index]), texts[index])
            }
        }
        if preset.showsFailure { return prompt(failed: false, then: command("false")) + prompt(failed: true, then: cursor) }
        return prompt(failed: false, then: command("git status")) + prompt(failed: false, then: cursor)
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows.indices, id: \.self) { rows[$0].0 }
        }
        .font(.custom(appearance.fontName, size: 12)).lineLimit(1)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(themeRGB: theme.terminal.background), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Prompt preview"))
        .accessibilityValue(preset.previewText(sample).joined(separator: " "))
        .accessibilityIdentifier("settings.shellPromptPreview")
    }
}
