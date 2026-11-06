import AppKit
import SwiftUI
import TrellisCore

struct WelcomeTourHost: ViewModifier {
    @ObservedObject var model: AppWorkspaceModel
    func body(content: Content) -> some View {
        content
            .overlay {
                if model.welcomeTourVisible { WelcomeTourView(model: model).transition(.opacity) }
            }
            .animation(model.reduceMotion ? nil : .easeOut(duration: 0.15), value: model.welcomeTourVisible)
    }
}

/// The tour's dialog (FR-ON04, FR-ON08). The backdrop swallows clicks without closing, so a stray click can't lose the tour.
struct WelcomeTourView: View {
    @ObservedObject var model: AppWorkspaceModel
    static let fullSize = CGSize(width: 900, height: 560)
    static let stageWidth: CGFloat = 414
    /// Below these the illustration gives way to the text.
    static func showsStage(in size: CGSize) -> Bool { size.width >= 760 && size.height >= 440 }
    /// The dots need this much beside Back and the longest primary button, or the footer runs off the dialog.
    static let dotsMinimumPanelWidth: CGFloat = 430
    static func showsDots(in size: CGSize) -> Bool { panelWidth(in: size) >= dotsMinimumPanelWidth }
    static func panelWidth(in size: CGSize) -> CGFloat { dialogSize(in: size).width - (showsStage(in: size) ? stageWidth + 8 : 0) }
    static func dialogSize(in size: CGSize) -> CGSize {
        let width = showsStage(in: size) ? min(fullSize.width, size.width - 32) : min(470, max(280, size.width - 16))
        return CGSize(width: width, height: min(fullSize.height, max(200, size.height - 16)))
    }

    var body: some View {
        GeometryReader { geometry in
            let step = model.welcomeTourStep ?? .welcome
            let dialog = Self.dialogSize(in: geometry.size)
            ZStack {
                Color.black.opacity(model.increaseContrast ? 0.6 : 0.45)
                    .contentShape(Rectangle()).onTapGesture {}
                    .accessibilityHidden(true)
                HStack(spacing: 0) {
                    if Self.showsStage(in: geometry.size) {
                        WelcomeTourStage(model: model, step: step)
                            .frame(width: Self.stageWidth).frame(maxHeight: .infinity)
                            .background(model.welcomeTourFill)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(8).padding(.trailing, -8)
                            .accessibilityHidden(true)
                    }
                    panel(step, showsDots: Self.showsDots(in: geometry.size))
                }
                .frame(width: dialog.width, height: dialog.height)
                .background(model.themeColor(.background))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(model.themeColor(.border), lineWidth: model.increaseContrast ? 1.5 : 0.5))
                .shadow(color: .black.opacity(0.35), radius: 32, y: 16)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Welcome Tour")
                .accessibilityAddTraits(.isModal)
            }
            .animation(model.reduceMotion ? nil : .easeOut(duration: 0.15), value: step)
            .onChange(of: step) { _, value in
                NSAccessibility.post(
                    element: NSApp as Any, notification: .announcementRequested,
                    userInfo: [.announcement: "Step \(value.counter): \(value.title)", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        }
        .background(WelcomeTourKeyMonitor(model: model))
    }

    private func panel(_ step: WelcomeTourStep, showsDots: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(step.counter).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(model.themeColor(.accent))
                    .accessibilityLabel("Step \(step.counter)")
                Spacer()
                if step.next != nil {
                    Button("Skip Tour") { model.closeWelcomeTour() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(model.themeColor(.mutedForeground))
                        .accessibilityIdentifier("welcomeTour.skip")
                }
            }
            .frame(height: 28).padding(.top, 14).padding(.horizontal, 24)
            ScrollView {
                WelcomeTourCopy(model: model, step: step)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 12)
            }
            .id(step).transition(.opacity).scrollBounceBehavior(.basedOnSize).frame(maxHeight: .infinity)
            Divider().overlay(model.separatorOverlay)
            HStack(spacing: 10) {
                if showsDots { dots(step) }
                Spacer(minLength: 0)
                if step.previous != nil {
                    Button("Back") { model.retreatWelcomeTour() }.controlSize(.large).accessibilityIdentifier("welcomeTour.back")
                }
                Button(step == .welcome ? "Start Tour" : step.next == nil ? "Start Using Trellis" : "Next") { model.advanceWelcomeTour() }
                    .buttonStyle(WelcomeTourPrimaryStyle(fill: model.themeColor(.accent), text: model.accentForeground))
                    .fixedSize().accessibilityIdentifier("welcomeTour.primary")
            }
            .padding(.horizontal, 24).frame(height: 56)
        }
    }

    private func dots(_ current: WelcomeTourStep) -> some View {
        HStack(spacing: 0) {
            ForEach(WelcomeTourStep.allCases, id: \.self) { step in
                let selected = step == current
                Button {
                    model.goToWelcomeTourStep(step)
                } label: {
                    Circle()
                        .fill(selected ? model.themeColor(.accent) : model.themeColor(.mutedForeground).opacity(model.increaseContrast ? 0.8 : 0.4))
                        .frame(width: selected ? 8 : 7, height: selected ? 8 : 7)
                        .frame(width: 17, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go to step \(step.rawValue + 1): \(step.title)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

private struct WelcomeTourPrimaryStyle: ButtonStyle {
    let fill: Color, text: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(text)
            .padding(.horizontal, 14).frame(height: 30)
            .background(fill.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// A monitor, not SwiftUI focus: a new pane can take first responder after the tour opens, and its keys must still move the tour.
private struct WelcomeTourKeyMonitor: NSViewRepresentable {
    let model: AppWorkspaceModel
    func makeNSView(context: Context) -> Monitor { Monitor(model) }
    func updateNSView(_ view: Monitor, context: Context) {}

    final class Monitor: NSView {
        private weak var model: AppWorkspaceModel?
        private var monitor: Any?
        init(_ model: AppWorkspaceModel) { self.model = model; super.init(frame: .zero) }
        @available(*, unavailable) required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.handle(event) ?? event }
        }
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, window.attachedSheet == nil, let model, model.welcomeTourVisible else { return event }
            if model.welcomeTourMustTakeFocus(from: window.firstResponder) { window.makeFirstResponder(nil) }
            let consumed = model.handleWelcomeTourKeyDown(
                keyCode: event.keyCode, modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask), firstResponder: window.firstResponder)
            return consumed ? nil : event
        }
    }
}

// MARK: Copy

private struct WelcomeTourCopy: View {
    @ObservedObject var model: AppWorkspaceModel
    let step: WelcomeTourStep

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(step.title)
                .font(.system(size: 25, weight: .bold)).foregroundStyle(model.themeColor(.foreground))
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Text(intro)
                .font(.system(size: 14)).lineSpacing(3).foregroundStyle(model.themeColor(.mutedForeground))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 12).padding(.bottom, 22)
            rows
        }
    }

    private var intro: String {
        switch step {
        case .welcome: "A native Mac terminal that keeps your work organized and your sessions alive. This short tour shows you around and sets up the essentials."
        case .workspace: "Give each piece of work its own place. Everything lives in one Mac window, and the layout comes back after you relaunch."
        case .sessions: "Quit Trellis, or lose it to a crash, and your long builds and servers carry on. They’re back in their panes at the next launch."
        case .projects: "Save the layout and commands a project needs, then open it all together, ready to work."
        case .remote: "Save your SSH hosts, then open one as a whole workspace. When the network drops, your remote sessions keep going."
        case .agents: "Run Claude Code, pi or Codex from the Agents view in the right sidebar, here or on a remote host. Your agent, your account: Trellis adds no AI of its own."
        case .keyboard: "Three shortcuts are worth learning first. You can rebind all of them in Settings → Keyboard."
        case .setup: "A few choices to finish. You can change them later."
        }
    }

    private var splitDetail: String {
        let nest = "Nest them to build the layout you need."
        guard let leftRight = model.welcomeTourChord(.splitLeftRight), let topBottom = model.welcomeTourChord(.splitTopBottom) else {
            return "The Pane menu splits left and right, or top and bottom. \(nest)"
        }
        return "\(leftRight) splits left and right, \(topBottom) top and bottom. \(nest)"
    }

    @ViewBuilder private var rows: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case .welcome:
                row("slider.horizontal.3", "Set up the essentials", "Choose an appearance and how sessions behave at quit.")
                row("sparkles", "See what makes it different", "Sessions that outlive the app, coding agents and remote workspaces.")
                row("clock", "About a minute", "Skip whenever you like. Replay it from the Help menu or the command palette.")
            case .workspace:
                row(chord: .newWindow, "macwindow", "Windows in the sidebar", "Rename and reorder them. Sessions keep running when you switch away.")
                row(chord: .newTab, "plus.square", "Tabs in each window", "Double-click a tab to name it. Each tab keeps its own layout.")
                row(chord: .splitLeftRight, "rectangle.split.2x1", "Splits inside a tab", splitDetail)
                row("sidebar.right", "A sidebar on the right", "The dock on the window’s edge opens files, the scratchpad, tasks and agents beside your panes.")
            case .sessions:
                row("waveform.path.ecg", "On by default", "Prefer sessions to end at quit? You can choose that at the end of this tour.")
                row("checkmark.shield", "Nothing replays by itself", "Sessions that ended come back stopped, and typed commands are never rerun.")
            case .projects:
                row(chord: .showProjects, "folder", "Your project library", "Open it from the sidebar, above Hosts and Settings.")
                row("desktopcomputer", "Launch it anywhere", "Choose This Mac or a saved host each time. Trellis remembers the last folder.")
            case .remote:
                row("server.rack", "Saved hosts", "Connect in a new tab, a new window or a split. Uses your own ssh and config.")
                row("arrow.clockwise", "Remote workspaces", "Trellis reconnects by itself when it can and shows what you missed, without repeating output.")
            case .agents:
                row("bell", "Know when you’re needed", "Tabs say Needs you, Done or Error, and the dock counts agents waiting on you, so you can leave them to work.")
                row("play", "Pick up where you left off", "Stopped agent panes offer to resume the last conversation.")
            case .keyboard:
                row(chord: .commandPalette, "command", "Command palette", "Search actions, windows, hosts, projects and themes in one list.")
                row(chord: .jumpToDirectory, "arrow.turn.down.right", "Jump to a directory", "Return to folders you visit often, on this Mac or a host.")
                row(chord: .toggleFiles, "folder", "Files", model.welcomeTourSidebarDetail)
            case .setup: setup
            }
        }
    }

    private func text(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(model.themeColor(.foreground))
            Text(detail).font(.system(size: 12.5)).lineSpacing(1.5).foregroundStyle(model.themeColor(.mutedForeground))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(model.themeColor(.accent))
                .frame(width: 32, height: 32).background(model.welcomeTourFill, in: RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
            text(title, detail)
        }
    }

    /// The bound chord, or the row's symbol when it was unbound (FR-ON08).
    @ViewBuilder private func row(chord action: ShortcutAction, _ symbol: String, _ title: String, _ detail: String) -> some View {
        if let chord = model.welcomeTourChord(action) {
            HStack(alignment: .top, spacing: 12) {
                Text(chord).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(model.themeColor(.foreground))
                    .frame(width: 48, height: 28).background(model.welcomeTourFill, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Shortcut \(chord)")
                text(title, detail)
            }
        } else {
            row(symbol, title, detail)
        }
    }

    @ViewBuilder private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Appearance").font(.system(size: 13, weight: .semibold)).foregroundStyle(model.themeColor(.foreground))
            Picker("Appearance", selection: Binding(get: { model.appearance.chromeMode }, set: { model.setChromeModeFromWelcomeTour($0) })) {
                Text("System").tag(ChromeMode.system)
                Text("Dark").tag(ChromeMode.dark)
                Text("Light").tag(ChromeMode.light)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity).accessibilityIdentifier("welcomeTour.appearance")
        }
        if model.welcomeTourCLIStatus != .unavailable {
            Divider().overlay(model.separatorOverlay)
            HStack(spacing: 16) {
                text("Command line tool", "Adds one link at ~/.local/bin/trellis. Your shell files aren’t touched. It’s also in the Trellis menu.")
                Spacer(minLength: 0)
                if model.welcomeTourCLIStatus == .installed {
                    Label("Installed", systemImage: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(model.themeColor(.success))
                } else {
                    Button("Install") { model.installCLIFromWelcomeTour() }.disabled(model.welcomeTourCLIInstalling).accessibilityIdentifier("welcomeTour.installCLI")
                }
            }
        }
        Divider().overlay(model.separatorOverlay)
        HStack(spacing: 16) {
            text(
                "Keep sessions running after quit",
                model.keepSessionsRunning ? "Builds and servers carry on after you quit." : "Quitting Trellis ends your sessions.")
            Spacer(minLength: 0)
            Toggle("Keep sessions running after quit", isOn: Binding(get: { model.keepSessionsRunning }, set: { model.setKeepSessionsRunning($0) }))
                .toggleStyle(.switch).labelsHidden().accessibilityIdentifier("welcomeTour.keepSessions")
        }
    }
}

// MARK: Illustrations

/// Drawn in code with sample text, in the current theme's own colors (FR-ON08). Hidden from VoiceOver by the dialog.
private struct WelcomeTourStage: View {
    @ObservedObject var model: AppWorkspaceModel
    let step: WelcomeTourStep

    private var palette: TerminalPalette { model.effectiveTheme.terminal }
    private func ansi(_ index: Int) -> Color { palette.ansi.indices.contains(index) ? Color(themeRGB: palette.ansi[index]) : termText }
    private var termText: Color { Color(themeRGB: palette.foreground) }
    private var red: Color { ansi(1) }
    private var green: Color { ansi(2) }
    private var yellow: Color { ansi(3) }
    private var purple: Color { ansi(5) }
    private var cyan: Color { ansi(6) }
    private var dim: Color { ansi(8) }
    private var border: Color { model.themeColor(.border) }
    private var fg: Color { model.themeColor(.foreground) }
    private var muted: Color { model.themeColor(.mutedForeground) }
    private var card: Color { model.themeColor(.background) }
    private func mono(_ size: CGFloat) -> Font { .custom(model.appearance.fontName, size: size) }

    var body: some View {
        ZStack {
            switch step {
            case .welcome: welcome
            case .workspace: workspace
            case .sessions: sessions
            case .projects: projects
            case .remote: remote
            case .agents: agents
            case .keyboard: palettePreview
            case .setup: setup
            }
        }
        .id(step).transition(.opacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 128, height: 128)
    }

    private func prompt(_ command: String) -> some View {
        HStack(spacing: 0) {
            Text("❯ ").foregroundStyle(cyan); Text(command).foregroundStyle(termText)
        }
    }
    private func output(_ line: String, _ color: Color) -> some View { Text(line).foregroundStyle(color).lineLimit(1) }

    private func terminal<Content: View>(_ title: String, width: CGFloat, height: CGFloat, size: CGFloat = 11, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Text(title).font(mono(size)).foregroundStyle(dim).frame(maxWidth: .infinity).frame(height: 26)
            Rectangle().fill(border.opacity(0.6)).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 4) { content() }
                .font(mono(size)).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: width, height: height)
        .background(model.terminalBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
    }

    private func list<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(fg).padding(.horizontal, 14).frame(height: 38)
            Rectangle().fill(border.opacity(0.6)).frame(height: 0.5)
            content()
        }
        .font(.system(size: 12)).frame(width: 358)
        .background(card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
    }

    private var welcome: some View {
        ZStack(alignment: .topLeading) {
            appIcon.offset(x: 143, y: 40)
            terminal("npm run dev", width: 226, height: 128) { prompt("npm run dev") }.offset(x: 22, y: 216)
            terminal("swift test", width: 206, height: 128) {
                prompt("swift test")
                output("Building for debugging…", dim)
            }
            .offset(x: 188, y: 190)
            terminal("claude", width: 262, height: 176) {
                prompt("claude")
                output("* Reading login.test.ts", purple)
                output("* Fixing the failing test", purple)
                output("✓ All tests pass", green)
            }
            .offset(x: 76, y: 298)
        }
        .frame(width: 414, height: 500, alignment: .topLeading)
    }

    private var workspace: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                sidebarRow("api", selected: true); sidebarRow("web", selected: false); sidebarRow("ops", selected: false)
                Spacer()
            }
            .padding(.top, 34).padding(.horizontal, 8).frame(width: 96)
            Rectangle().fill(border.opacity(0.6)).frame(width: 0.5)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("server").fontWeight(.semibold).foregroundStyle(fg).padding(.horizontal, 14).frame(maxHeight: .infinity).background(model.terminalBackground)
                        .overlay(alignment: .top) { model.themeColor(.accent).frame(height: 2) }
                    Text("tests").foregroundStyle(muted).padding(.horizontal, 14)
                    Text("+").foregroundStyle(muted)
                    Spacer()
                }
                .frame(height: 34)
                HStack(spacing: 0) {
                    pane {
                        prompt("npm start")
                        output("listening :8080", green)
                    }
                    Rectangle().fill(border).frame(width: 1)
                    VStack(spacing: 0) {
                        pane {
                            prompt("git status")
                            output("nothing to commit", dim)
                        }
                        Rectangle().fill(border).frame(height: 1)
                        pane { prompt("tail -f app.log") }
                    }
                }
                .font(mono(10)).background(model.terminalBackground)
            }
            dock(shown: nil)
        }
        .font(.system(size: 11)).frame(width: 374, height: 358)
        .background(card, in: RoundedRectangle(cornerRadius: 10)).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
    }

    private func sidebarRow(_ name: String, selected: Bool) -> some View {
        Text(name).fontWeight(selected ? .semibold : .regular).foregroundStyle(selected ? fg : muted).padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading).background(selected ? model.sidebarSelectionBackground : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    /// The right edge's dock (FR-SB01) in miniature: the real views' symbols, the shown one marked by an accent bar.
    private func dock(shown: SidebarView?, needsYou: Int = 0) -> some View {
        VStack(spacing: 2) {
            ForEach(SidebarView.allCases, id: \.self) { view in
                SidebarViewIcon(view: view, size: 11).foregroundStyle(view == shown ? fg : muted)
                    .frame(width: 28, height: 26)
                    .overlay(alignment: .leading) {
                        if view == shown { model.themeColor(.accent).frame(width: 2, height: 15).clipShape(Capsule()) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if view == .agents, needsYou > 0 {
                            Text("\(needsYou)").font(.system(size: 6.5, weight: .bold)).foregroundStyle(.black)
                                .frame(minWidth: 10, minHeight: 10).background(Capsule().fill(model.themeColor(.warning))).padding(.trailing, 3).padding(.bottom, 2)
                        }
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6).frame(width: 28).frame(maxHeight: .infinity)
        .background(model.themeColor(.sidebarBackground))
        .overlay(alignment: .leading) { border.opacity(0.6).frame(width: 0.5) }
    }

    private func pane<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) { content() }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sessions: some View {
        VStack(spacing: 28) {
            terminal("npm run build", width: 346, height: 170) {
                prompt("npm run build")
                output("transforming 1,284 modules…", dim)
                output("rendering chunks…", dim)
                output("✓ built in 4m 12s", green)
            }
            VStack(alignment: .leading, spacing: 0) {
                timeline(dim, "You quit Trellis", "The window closes. The build doesn’t notice.", last: false)
                timeline(model.themeColor(.accent), "Still running", "A small helper keeps the session alive.", last: false)
                timeline(green, "You come back", "Same process, with its output caught up.", last: true)
            }
            .frame(width: 346, alignment: .leading)
        }
    }

    private func timeline(_ color: Color, _ title: String, _ detail: String, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle().fill(color).frame(width: 10, height: 10).padding(.top, 3)
                if !last { Rectangle().fill(border).frame(width: 1).frame(maxHeight: .infinity) }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(fg)
                Text(detail).font(.system(size: 12.5)).foregroundStyle(muted)
            }
            .padding(.bottom, last ? 0 : 18)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func projectRow(_ name: String, _ detail: String, last: String?, launch: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).fontWeight(.semibold).foregroundStyle(fg)
                Text(detail).font(.system(size: 11)).foregroundStyle(muted)
                if let last { Text(last).font(.system(size: 11)).foregroundStyle(muted) }
            }
            Spacer()
            if launch {
                Text("Launch…").font(.system(size: 11, weight: .semibold)).foregroundStyle(model.accentForeground).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(model.themeColor(.accent), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12).background(launch ? model.sidebarSelectionBackground : .clear)
    }

    private var projects: some View {
        list("Projects") {
            projectRow("storefront", "3 panes · npm run dev, tests, claude", last: "Last: This Mac", launch: true)
            projectRow("billing-api", "2 panes · docker compose up, logs", last: "Last: build-box, This Mac")
            projectRow("docs-site", "1 pane · mkdocs serve", last: nil)
        }
    }

    private func hostRow(_ name: String, _ address: String, _ state: String, _ color: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).fontWeight(.semibold).foregroundStyle(fg)
                Text(address).font(mono(10.5)).foregroundStyle(muted)
            }
            Spacer()
            Text(state).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var remote: some View {
        VStack(spacing: 20) {
            list("Hosts") {
                hostRow("build-box", "dev@build.internal", "✓ Connected", green)
                hostRow("staging", "deploy@staging.internal", "↻ Reconnecting", yellow)
                hostRow("nas", "admin@nas.local", "– Offline", muted)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text("dev@build-box ❯ ").foregroundStyle(cyan); Text("make release").foregroundStyle(termText)
                }
                output("link dropped for 2m, nothing lost", dim)
                output("✓ release built", green)
            }
            .font(mono(11)).padding(14).frame(width: 358, alignment: .leading)
            .background(model.terminalBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border, lineWidth: 0.5))
        }
    }

    private func capsule(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9.5)).foregroundStyle(color).padding(.horizontal, 6).padding(.vertical, 2).overlay(Capsule().strokeBorder(color, lineWidth: 1))
    }

    /// A Launch row (name, Open) or a Running row (tab, "window · agent", state capsule), as in the Agents view (FR-AG16).
    private func agentRow<Trailing: View>(_ name: String, _ detail: String? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(fg).lineLimit(1)
                if let detail { Text(detail).font(.system(size: 9)).foregroundStyle(muted).lineLimit(1) }
            }
            Spacer(minLength: 0)
            trailing().fixedSize()
        }
        .padding(.vertical, 4)
    }

    private func launchRow(_ name: String) -> some View {
        agentRow(name) { Text("Open").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(model.themeColor(.accent)) }
    }

    /// A tab bar over the panes and the Agents view, with the dock on the right edge (FR-SB01–FR-SB03, FR-SB05).
    private var agents: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Text("checkout").fontWeight(.semibold).foregroundStyle(fg)
                        capsule("! Needs you", yellow)
                    }
                    .padding(.horizontal, 10).frame(maxHeight: .infinity).background(model.terminalBackground)
                    .overlay(alignment: .top) { model.themeColor(.accent).frame(height: 2) }
                    HStack(spacing: 6) {
                        Text("docs").foregroundStyle(muted)
                        capsule("✓ Done", green)
                    }
                    .padding(.horizontal, 10)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11)).frame(height: 34)
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        output("* Updated checkout.ts", purple)
                        output("* Ran the tests", purple)
                        output(" ", dim)
                        output("Run migration?", termText)
                        output("❯ Yes", cyan)
                        output("  No", dim)
                    }
                    .font(mono(10)).padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(model.terminalBackground)
                    Rectangle().fill(border.opacity(0.6)).frame(width: 0.5)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Agents").font(.system(size: 11, weight: .semibold)).foregroundStyle(fg).padding(.bottom, 8)
                        Text("Launch").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(muted)
                        launchRow("Claude Code"); launchRow("pi"); launchRow("Codex")
                        Rectangle().fill(border.opacity(0.6)).frame(height: 0.5).padding(.vertical, 6)
                        Text("Running").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(muted)
                        agentRow("checkout", "api · Claude Code") { capsule("! Needs you", yellow) }
                        agentRow("docs", "web · pi") { capsule("✓ Done", green) }
                        Spacer(minLength: 0)
                    }
                    .padding(10).frame(width: 150).frame(maxHeight: .infinity, alignment: .top)
                    .background(model.themeColor(.sidebarBackground))
                }
            }
            dock(shown: .agents, needsYou: 1)
        }
        .frame(width: 374, height: 320)
        .background(card, in: RoundedRectangle(cornerRadius: 10)).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
    }

    private func paletteRow(_ title: String, _ trailing: String, selected: Bool = false) -> some View {
        HStack {
            Text(title).fontWeight(selected ? .semibold : .regular).foregroundStyle(fg)
            Spacer()
            Text(trailing).foregroundStyle(muted)
        }
        .padding(.horizontal, 14).padding(.vertical, 10).background(selected ? model.sidebarSelectionBackground : .clear)
    }

    private var palettePreview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(muted)
                Text("spl").font(.system(size: 13)).foregroundStyle(fg)
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 44)
            Rectangle().fill(border.opacity(0.6)).frame(height: 0.5)
            paletteRow("Split Left/Right", model.welcomeTourChord(.splitLeftRight) ?? "", selected: true)
            paletteRow("Split Top/Bottom", model.welcomeTourChord(.splitTopBottom) ?? "")
            paletteRow("Theme: Tokyo Dark", "Theme")
            paletteRow("~/code/splash-page", "Directory")
            Rectangle().fill(border.opacity(0.6)).frame(height: 0.5)
            Text("↩ Run · esc Close").font(.system(size: 11)).foregroundStyle(muted).padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12)).frame(width: 366)
        .background(card, in: RoundedRectangle(cornerRadius: 12)).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
    }

    private var setup: some View {
        VStack(spacing: 28) {
            appIcon
            terminal("zsh", width: 346, height: 200, size: 11.5) {
                prompt("git status")
                output("On branch main", green)
                HStack(spacing: 0) {
                    Text("modified: ").foregroundStyle(yellow); Text("src/app.ts").foregroundStyle(red)
                }
                HStack(spacing: 0) {
                    Text("❯ ").foregroundStyle(cyan)
                    Rectangle().fill(termText).frame(width: 7, height: 14)
                }
            }
        }
    }
}

extension AppWorkspaceModel {
    /// The stage and chips: a tint of the text color stands off the dialog in any theme, where a system surface can match it.
    fileprivate var welcomeTourFill: Color { themeColor(.foreground).opacity(increaseContrast ? 0.12 : 0.07) }
}
