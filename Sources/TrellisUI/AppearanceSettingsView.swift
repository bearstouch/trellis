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
    var localizedTitle: String {
        switch self {
        case .light: L("Light")
        case .dark: L("Dark")
        case .system: L("System")
        }
    }
}

extension TerminalCursorShape {
    var localizedTitle: String {
        switch self {
        case .block: L("Block")
        case .underline: L("Underline")
        case .bar: L("Bar")
        }
    }
}

extension View {
    /// Settings forms size their columns from each row's one-line width, so a caption gets
    /// a capped width to wrap within the pane instead of widening it.
    func wrappingSettingsCaption() -> some View {
        fixedSize(horizontal: false, vertical: true).frame(maxWidth: 360, alignment: .leading)
    }
}

public struct AppSettingsView: View {
    @ObservedObject var model: AppWorkspaceModel
    @State private var selection: SettingsSection = .appearance
    private let grants: GrantListModel?
    private let hosts: HostListModel?
    private let updates: UpdateSettingsModel?
    public init(model: AppWorkspaceModel, grants: GrantListModel? = nil, hosts: HostListModel? = nil, updates: UpdateSettingsModel? = nil) {
        self.model = model; self.grants = grants; self.hosts = hosts; self.updates = updates
    }
    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("SETTINGS"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.themeColor(.mutedForeground))
                    .padding(.horizontal, 12).padding(.top, 24).padding(.bottom, 12)
                ForEach(SettingsSection.allCases.filter { ($0 != .automation || (grants != nil && hosts != nil)) && ($0 != .updates || updates != nil) }) { section in
                    Button {
                        if selection == .themes { model.cancelThemePreview() }
                        selection = section
                    } label: {
                        HStack(spacing: 10) {
                            section.iconImage
                                .frame(width: 28, height: 28)
                                .accessibilityHidden(true)
                            Text(section.title)
                            Spacer()
                        }
                        .font(.system(size: 13, weight: selection == section ? .semibold : .regular))
                        .padding(.horizontal, 8).padding(.vertical, 7)
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
                    Text(selection.title).font(.system(size: 22, weight: .semibold))
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
                    case .broker:
                        ScrollView { SessionBrokerStatusView(model: model).padding(.top, 8) }
                    case .keyboard:
                        KeyboardSettingsView(model: model)
                    case .themes:
                        ThemePreviewView(workspace: model)
                    case .agents:
                        ScrollView { AgentSettingsView(model: model) }
                    case .automation:
                        if let grants, let hosts { AutomationSettingsView(grants: grants, workspace: model, hosts: hosts) }
                    case .remoteControl:
                        ScrollView {
                            RemoteControlSettingsView(model: model, showAutomation: grants != nil && hosts != nil ? { selection = .automation } : nil)
                        }
                    case .updates:
                        if let updates { ScrollView { UpdateSettingsView(updates: updates) } }
                    }
                }
                .padding(.vertical, 12).padding(.leading, 12).padding(.trailing, 28)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            // minWidth 0: a pane's long captions wrap instead of widening the window past the sidebar.
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(model.themeColor(.foreground))
            .background(model.themeColor(.background))
        }
        .frame(minWidth: 860, minHeight: 620)
        .preferredColorScheme(model.effectiveChromeMode.colorScheme)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance = "Appearance", sessions = "Sessions", broker = "Session Broker", keyboard = "Keyboard", themes = "Themes", agents = "Agents"
    case automation = "Automation"
    case remoteControl = "Remote Control", updates = "Updates"
    var id: Self { self }
    var title: String {
        switch self {
        case .appearance: L("Appearance")
        case .sessions: L("Sessions")
        case .broker: L("Session Broker")
        case .keyboard: L("Keyboard")
        case .themes: L("Themes")
        case .agents: L("Agents")
        case .automation: L("Automation")
        case .remoteControl: L("Remote Control")
        case .updates: L("Updates")
        }
    }
    private var icon: BundledSettingsIcon {
        switch self {
        case .appearance: .appearance
        case .sessions: .sessions
        case .broker: .broker
        case .keyboard: .keyboard
        case .themes: .themes
        case .agents: .agents
        case .automation: .automation
        case .remoteControl: .remote
        case .updates: .updates
        }
    }
    /// Decoded once: the sidebar redraws on every selection change.
    @MainActor private static let iconImages: [SettingsSection: NSImage] = Dictionary(
        uniqueKeysWithValues: allCases.compactMap { section in section.icon.url.flatMap(NSImage.init(contentsOf:)).map { (section, $0) } })
    /// A missing resource leaves an empty tile rather than failing Settings.
    @MainActor @ViewBuilder var iconImage: some View {
        if let image = Self.iconImages[self] { Image(nsImage: image).resizable().interpolation(.high) } else { Color.clear }
    }
    var detail: String {
        switch self {
        case .appearance: L("Customize the window, terminal text, and cursor.")
        case .sessions: L("Choose how sessions start, draw, and keep their output.")
        case .broker: L("The helpers that keep sessions running, on this Mac and on your hosts.")
        case .keyboard: L("Set your shortcuts and terminal key behavior.")
        case .themes: L("Browse, preview, and manage your color themes.")
        case .agents: L("The coding agents the Agents view launches, and how they report their state.")
        case .automation: L("Manage access for scripts and agents.")
        case .remoteControl: L("Let agents connect over the Model Context Protocol (MCP).")
        case .updates: L("Check for new versions of Trellis and install them.")
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
            Picker(L("Language"), selection: $draft.language) {
                Text(L("System")).tag(AppLanguage.system)
                // Each language is listed under its own name, whatever the app shows (FR-LN02).
                ForEach(AppLanguage.translated, id: \.self) { Text(verbatim: $0.nativeName ?? $0.rawValue).tag($0) }
            }.accessibilityIdentifier("settings.language")
            Text(L("Menus, settings and messages. Terminal output and the trellis command stay as they are.")).font(.caption).foregroundStyle(.secondary).wrappingSettingsCaption()
            SegmentedPicker(L("Application appearance"), selection: draft.chromeMode, options: ChromeMode.allCases.map { ($0, $0.localizedTitle) }) { draft.chromeMode = $0 }
            Text(L("Choose matching light and dark palettes for the app and terminal.")).font(.caption).foregroundStyle(.secondary).wrappingSettingsCaption()
            Picker(L("Light theme"), selection: $draft.lightThemeID) {
                ForEach(model.availableThemes(for: .light), id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker(L("Dark theme"), selection: $draft.darkThemeID) {
                ForEach(model.availableThemes(for: .dark), id: \.id) { Text($0.name).tag($0.id) }
            }
            LabeledContent(L("Background opacity")) {
                HStack {
                    Slider(value: $draft.backgroundOpacity, in: AppearanceSettings.backgroundOpacityRange, step: 0.05)
                        .accessibilityLabel(L("Background opacity")).accessibilityValue(L("%d percent", Int((draft.backgroundOpacity * 100).rounded())))
                        .accessibilityIdentifier("settings.backgroundOpacity")
                    Text("\(Int((draft.backgroundOpacity * 100).rounded())) %").monospacedDigit().frame(width: 44, alignment: .trailing).accessibilityHidden(true)
                }
            }
            Toggle(L("Blur behind background"), isOn: $draft.backgroundBlur).disabled(draft.backgroundOpacity >= 1).accessibilityIdentifier("settings.backgroundBlur")
            Text(
                model.increaseContrast || model.reduceTransparency
                    ? L("Panes stay opaque while Reduce Transparency or Increase Contrast is on.")
                    : L("Only the terminal background shows the desktop; text, colors and selections stay opaque.")
            ).font(.caption).foregroundStyle(.secondary).wrappingSettingsCaption()
            Picker(L("Terminal font"), selection: $draft.fontName) {
                if !fontNames.contains(draft.fontName) {
                    Text(L("%@ (unavailable)", draft.fontName)).tag(draft.fontName)
                }
                ForEach(fontNames, id: \.self) { name in
                    Text(NativeTerminalFont.typefaceName(for: name)).tag(name)
                }
            }
            Text(L("Installed monospace typefaces on this Mac.")).font(.caption).foregroundStyle(.secondary).wrappingSettingsCaption()
            Text(L("The quick brown fox jumps over 0123456789"))
                .font(.custom(draft.fontName, size: draft.fontSize))
                .lineLimit(1)
            Stepper(L("Font size: %@ pt", String(format: "%.0f", draft.fontSize)), value: $draft.fontSize, in: 8...48)
            Text(L("Use View → Zoom In / Zoom Out, or ⌘+ / ⌘−. Actual Size restores 13 pt."))
                .font(.caption).foregroundStyle(.secondary).wrappingSettingsCaption()
            Picker(L("Cursor"), selection: $draft.cursorShape) {
                ForEach(TerminalCursorShape.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
            }
            Toggle(L("Blink cursor"), isOn: $draft.cursorBlinks)
            Picker(L("Bell"), selection: $draft.bellStyle) {
                ForEach(TerminalBellStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle(L("Ligatures"), isOn: $draft.fontLigatures)
            Text(L("Joins sequences such as -> and != in fonts that include ligatures, such as JetBrains Mono."))
                .font(.caption).foregroundStyle(.secondary).wrappingSettingsCaption()
            Toggle(L("Bold as bright colors"), isOn: $draft.boldAsBright)
            Toggle(L("Use bold fonts"), isOn: $draft.allowBoldFont)
            Toggle(L("Use italic fonts"), isOn: $draft.allowItalicFont)
            Toggle(L("Allow blinking text"), isOn: $draft.blinkingText)
            Text(L("Blinking text stays steady while Reduce Motion is on.")).font(.caption).foregroundStyle(.secondary).wrappingSettingsCaption()
            if let notice = model.appearanceNotice { Text(notice).font(.caption).foregroundStyle(.secondary).wrappingSettingsCaption() }
            if let message { Text(message).font(.caption).wrappingSettingsCaption() }
            HStack {
                Spacer()
                Button(L("Apply Appearance")) {
                    message = model.applyAppearance(draft) ? L("Appearance saved.") : L("Use a font name and 8–48 pt.")
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
