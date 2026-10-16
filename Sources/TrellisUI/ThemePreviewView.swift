import SwiftUI
import TrellisCore

struct ThemePreviewView: View {
    @StateObject private var model = ThemePreviewModel()
    @ObservedObject var workspace: AppWorkspaceModel
    private func ui(_ field: UIColorField) -> Color { color(model.theme[field].rgb) }
    private func color(_ rgb: UInt32) -> Color {
        Color(
            .sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
            blue: Double(rgb & 255) / 255, opacity: 1)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ThemeLibraryControls(workspace: workspace, preview: model)
                HStack {
                    Button("Preview JSON…") { model.chooseFile() }.disabled(model.loading)
                    Spacer()
                    ForEach(ThemeExample.allCases, id: \.self) { example in
                        Button(example.rawValue.capitalized) { model.example(example) }
                    }
                }
                Text("The sample stays separate until you choose Preview in Workspace. Save & Use installs the theme.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.validationMessage {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                Text(model.theme.name).font(.headline)
                sample
                if model.theme.contrastWarnings.isEmpty {
                    Text("Text and essential boundary contrast checks pass.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Contrast advice · Colors are valid and may still be used.").font(.caption.bold())
                    ForEach(Array(model.theme.contrastWarnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning.message).font(.caption).textSelection(.enabled)
                    }
                }
            }.padding(16)
        }
        .onDisappear { workspace.cancelThemePreview() }
    }
    private var sample: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("WINDOWS").font(.system(size: 9)).foregroundStyle(ui(.mutedForeground))
                    Text("Workspace").font(.system(size: 11, weight: .semibold)).foregroundStyle(ui(.foreground))
                    Text("Local").font(.system(size: 11)).foregroundStyle(ui(.accent))
                    Spacer()
                }.padding(10).frame(width: 105).background(ui(.sidebarBackground))
                Rectangle().fill(ui(.border)).frame(width: 1)
                VStack(spacing: 0) {
                    HStack {
                        Text("Terminal").padding(6).foregroundStyle(ui(.activeTabForeground)).background(ui(.activeTabBackground))
                        Text("Logs").foregroundStyle(ui(.mutedForeground))
                        Spacer()
                    }.font(.system(size: 11)).padding(4).background(ui(.surface))
                    NativeTerminalSurface(terminal: model.terminal, isFocused: false)
                        .frame(height: 170).overlay(Rectangle().stroke(ui(.focusRing), lineWidth: 2))
                }
            }
            HStack(spacing: 12) {
                Text("✓ Ready").foregroundStyle(ui(.success))
                Text("⚠ Warning").foregroundStyle(ui(.warning))
                Text("! Error").foregroundStyle(ui(.error))
                Spacer()
            }.font(.system(size: 11)).padding(10).background(ui(.background))
            HStack(spacing: 3) {
                ForEach(0..<16, id: \.self) { index in
                    let rgb = model.theme.terminal.ansi[index]
                    let luminance = ThemeColor(hex: String(format: "#%06X", rgb))!.relativeLuminance
                    Text(String(format: "%02d", index)).font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(luminance > 0.179 ? Color.black : Color.white)
                        .frame(maxWidth: .infinity).frame(height: 20).background(color(rgb))
                        .accessibilityLabel("ANSI \(index): \(String(format: "#%06X", rgb))")
                }
            }.padding(8).background(ui(.surface))
            HStack {
                Text("Selected text").foregroundStyle(color(model.theme.terminal.selectionForeground))
                    .padding(4).background(color(model.theme.terminal.selectionBackground))
                Text("A").foregroundStyle(color(model.theme.terminal.cursorText))
                    .padding(4).background(color(model.theme.terminal.cursor))
                Text("Cursor text").foregroundStyle(ui(.foreground))
                Spacer()
            }.font(.system(size: 11)).padding(8).background(ui(.background))
        }
        .overlay(Rectangle().stroke(ui(.border), lineWidth: 1))
        .environment(\.colorScheme, model.theme.appearance == .light ? .light : .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Theme sample: application chrome, terminal indexes 0–15, selection, cursor, and status")
    }
}
