import SwiftUI
import TrellisCore
import TrellisTerminal

extension ChromeMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light;
        case .dark: .dark;
        case .system: nil
        }
    }
}

public struct AppSettingsView: View {
    @ObservedObject var model: AppWorkspaceModel
    @State private var selection: SettingsSection = .appearance
    private let grants: GrantListModel?
    private let hosts: HostListModel?
    public init(model: AppWorkspaceModel, grants: GrantListModel? = nil, hosts: HostListModel? = nil) {
        self.model = model; self.grants = grants; self.hosts = hosts
    }
    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SETTINGS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.themeColor(.mutedForeground))
                    .padding(.horizontal, 12).padding(.top, 24).padding(.bottom, 12)
                ForEach(SettingsSection.allCases.filter { $0 != .automation || (grants != nil && hosts != nil) }) { section in
                    Button {
                        if selection == .themes { model.cancelThemePreview() }
                        selection = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.symbol).frame(width: 18)
                            Text(section.rawValue)
                            Spacer()
                        }
                        .font(.system(size: 13, weight: selection == section ? .semibold : .regular))
                        .padding(.horizontal, 12).padding(.vertical, 11)
                        .contentShape(Rectangle())
                        .foregroundStyle(model.themeColor(selection == section ? .activeTabForeground : .foreground))
                        .background(selection == section ? model.themeColor(.activeTabBackground) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(width: 200)
            .background(model.themeColor(.sidebarBackground))
            Rectangle().fill(model.themeColor(.border)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selection.rawValue).font(.system(size: 22, weight: .semibold))
                    Text(selection.detail).font(.callout).foregroundStyle(model.themeColor(.mutedForeground))
                }
                .padding(28)
                Divider().padding(.horizontal, 28)
                Group {
                    switch selection {
                    case .appearance:
                        ScrollView { AppearanceSettingsView(model: model).disabled(model.previewedTheme != nil) }
                    case .sessions:
                        ScrollView { LaunchSettingsView(model: model) }
                    case .keyboard:
                        KeyboardSettingsView(model: model)
                    case .themes:
                        ThemePreviewView(workspace: model)
                    case .automation:
                        if let grants, let hosts { AutomationSettingsView(grants: grants, workspace: model, hosts: hosts) }
                    case .remoteControl:
                        ScrollView {
                            RemoteControlSettingsView(model: model, showAutomation: grants != nil && hosts != nil ? { selection = .automation } : nil)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(model.themeColor(.foreground))
            .background(model.themeColor(.background))
        }
        .frame(minWidth: 860, minHeight: 620)
        .preferredColorScheme(model.effectiveChromeMode.colorScheme)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance = "Appearance", sessions = "Sessions", keyboard = "Keyboard", themes = "Themes", automation = "Automation"
    case remoteControl = "Remote Control"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .appearance: "paintbrush"
        case .sessions: "terminal"
        case .keyboard: "keyboard"
        case .themes: "swatchpalette"
        case .automation: "bolt"
        case .remoteControl: "antenna.radiowaves.left.and.right"
        }
    }
    var detail: String {
        switch self {
        case .appearance: "Customize the window, terminal text, and cursor."
        case .sessions: "Choose how new local sessions start."
        case .keyboard: "Set your shortcuts and terminal key behavior."
        case .themes: "Browse, preview, and manage your color themes."
        case .automation: "Manage access for scripts and agents."
        case .remoteControl: "Let agents connect over the Model Context Protocol (MCP)."
        }
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject var model: AppWorkspaceModel
    @State private var draft = AppearanceSettings()
    @State private var message: String?
    @State private var fontNames: [String] = []
    var body: some View {
        Form {
            Picker("Application appearance", selection: $draft.chromeMode) {
                ForEach(ChromeMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.pickerStyle(.segmented)
            Text("Choose matching light and dark palettes for the app and terminal.").font(.caption).foregroundStyle(.secondary)
            Picker("Light theme", selection: $draft.lightThemeID) {
                ForEach(model.availableThemes(for: .light), id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker("Dark theme", selection: $draft.darkThemeID) {
                ForEach(model.availableThemes(for: .dark), id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker("Terminal font", selection: $draft.fontName) {
                if !fontNames.contains(draft.fontName) {
                    Text("\(draft.fontName) (unavailable)").tag(draft.fontName)
                }
                ForEach(fontNames, id: \.self) { name in
                    Text(NativeTerminalFont.typefaceName(for: name)).tag(name)
                }
            }
            Text("Installed monospace typefaces on this Mac.").font(.caption).foregroundStyle(.secondary)
            Text("The quick brown fox jumps over 0123456789")
                .font(.custom(draft.fontName, size: draft.fontSize))
                .lineLimit(1)
            Stepper("Font size: \(draft.fontSize, specifier: "%.0f") pt", value: $draft.fontSize, in: 8...48)
            Text("Use View → Zoom In / Zoom Out, or ⌘+ / ⌘−. Actual Size restores 13 pt.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Cursor", selection: $draft.cursorShape) {
                ForEach(TerminalCursorShape.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Toggle("Blink cursor", isOn: $draft.cursorBlinks)
            Picker("Bell", selection: $draft.bellStyle) {
                ForEach(TerminalBellStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("Desktop notifications", isOn: $draft.desktopNotifications)
            Text("Shows notifications that programs send (OSC 9, OSC 777, OSC 99) when you aren’t looking at their pane. macOS asks for permission the first time.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Notify when a command finishes", selection: $draft.commandFinishedNotificationSeconds) {
                ForEach(AppearanceSettings.commandFinishedNotificationChoices, id: \.self) { Text($0 == 0 ? "Off" : "After \($0) s").tag($0) }
            }.disabled(!draft.desktopNotifications)
            Text("With shell integration, a command that ran at least this long notifies when it finishes out of view. Only the program name is shown, never the command line.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Ligatures", isOn: $draft.fontLigatures)
            Text("Joins sequences such as -> and != in fonts that include ligatures, such as JetBrains Mono.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Bold as bright colors", isOn: $draft.boldAsBright)
            Toggle("Use bold fonts", isOn: $draft.allowBoldFont)
            Toggle("Use italic fonts", isOn: $draft.allowItalicFont)
            Toggle("Allow blinking text", isOn: $draft.blinkingText)
            Text("Blinking text stays steady while Reduce Motion is on.").font(.caption).foregroundStyle(.secondary)
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
        .onAppear {
            draft = model.appearance
            fontNames = NativeTerminalFont.installedNames
            if let regular = fontNames.first(where: {
                NativeTerminalFont.typefaceName(for: $0) == NativeTerminalFont.typefaceName(for: draft.fontName)
            }) {
                draft.fontName = regular
            }
        }
        .onChange(of: model.appearance) { _, value in draft = value }
    }
}
