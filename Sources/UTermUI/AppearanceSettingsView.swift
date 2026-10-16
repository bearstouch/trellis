import SwiftUI
import UTermCore

extension ChromeMode {
    var colorScheme: ColorScheme? {
        switch self { case .light: .light; case .dark: .dark; case .system: nil }
    }
}

public struct AppSettingsView: View {
    @ObservedObject var model: AppWorkspaceModel
    public init(model: AppWorkspaceModel) { self.model = model }
    public var body: some View {
        TabView {
            AppearanceSettingsView(model: model).disabled(model.previewedTheme != nil).tabItem { Text("Appearance") }
            LaunchSettingsView(model: model).tabItem { Text("Sessions") }
            ThemePreviewView(workspace: model).tabItem { Text("Themes") }
        }
        .padding(16)
        .preferredColorScheme(model.effectiveChromeMode.colorScheme)
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject var model: AppWorkspaceModel
    @State private var draft = AppearanceSettings()
    @State private var message: String?
    var body: some View {
        Form {
            Picker("Application appearance", selection: $draft.chromeMode) {
                ForEach(ChromeMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.pickerStyle(.segmented)
            Text("Built-in themes keep terminal backgrounds dark. Custom themes can change terminal colors.").font(.caption).foregroundStyle(.secondary)
            Picker("Light theme", selection: $draft.lightThemeID) {
                ForEach(model.availableThemes(for: .light), id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker("Dark theme", selection: $draft.darkThemeID) {
                ForEach(model.availableThemes(for: .dark), id: \.id) { Text($0.name).tag($0.id) }
            }
            TextField("Terminal font", text: $draft.fontName)
            Stepper("Font size: \(draft.fontSize, specifier: "%.0f") pt", value: $draft.fontSize, in: 8...48)
            Text("Use View → Zoom In / Zoom Out, or ⌘+ / ⌘−. Actual Size restores 13 pt.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Cursor", selection: $draft.cursorShape) {
                ForEach(TerminalCursorShape.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Toggle("Blink cursor", isOn: $draft.cursorBlinks)
            TextField("Scrollback lines (0–50,000)", value: $draft.scrollbackLines, format: .number.grouping(.never))
            Text("History also has a 16 MiB text limit. Reducing history discards older output.")
                .font(.caption).foregroundStyle(.secondary)
            if let notice = model.appearanceNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if let message { Text(message).font(.caption) }
            HStack {
                Spacer()
                Button("Apply Appearance") {
                    message = model.applyAppearance(draft) ? "Appearance saved." : "Use a font name, 8–48 pt, and 0–50,000 scrollback lines."
                }.disabled(!draft.isValid)
            }
        }
        .padding(16)
        .onAppear { draft = model.appearance }
        .onChange(of: model.appearance) { _, value in draft = value }
    }
}
