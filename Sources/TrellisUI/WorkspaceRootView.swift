import SwiftUI
import TrellisCore
import TrellisTerminal

public struct WorkspaceRootView: View {
    @ObservedObject private var model: AppWorkspaceModel
    @State private var windowToRename: ManagedWindow?
    @State private var windowName = ""
    @FocusState private var tabNameFocused: Bool
    public init(model: AppWorkspaceModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 205).disabled(model.isRestoring || model.recoveryMessage != nil)
                Divider().overlay(model.separatorOverlay)
                mainArea
            }
            Divider().overlay(model.separatorOverlay)
            HStack(spacing: 8) {
                Text(model.presentation.selectedWindow?.name ?? "Trellis")
                Spacer()
                if model.persistenceReadOnly { Text("Changes won’t be saved") }
                if let notice = model.themeNotice { Text(notice).lineLimit(1).help(notice) }
                if let notice = model.appearanceNotice { Text(notice).lineLimit(1).help(notice) }
                Text(model.accessibility.status).foregroundStyle(sessionStatusColor).accessibilityLabel("Session status \(model.accessibility.status)")
                Text("·  UTF-8  ·  Local")
            }
            .font(.system(size: 11)).foregroundStyle(model.themeColor(.mutedForeground)).padding(.horizontal, 12).frame(height: 28)
            .background(model.themeColor(.surface))
        }
        .foregroundStyle(model.themeColor(.foreground))
        .background(model.usesNativeChrome ? model.themeColor(.surface) : model.themeColor(.background))
        .tint(model.chromeTint)
        .preferredColorScheme(model.effectiveChromeMode.colorScheme)
        .onChange(of: model.tabRenameRequest) { _, _ in
            if let tab = model.presentation.selectedTab { beginTabRename(tab) }
        }
        .onChange(of: model.windowRenameRequest) { _, _ in
            if let window = model.presentation.selectedWindow { beginWindowRename(window) }
        }
        .onChange(of: model.editingTabID) { _, value in
            if value == nil, let terminal = model.activeTerminal {
                DispatchQueue.main.async { terminal.view.window?.makeFirstResponder(terminal.view) }
            }
        }
        .sheet(item: $windowToRename) { window in
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename Window").font(.headline)
                TextField("Window name", text: $windowName).onSubmit { rename(window) }
                HStack {
                    Spacer()
                    Button("Cancel") { windowToRename = nil }.keyboardShortcut(.cancelAction)
                    Button("Rename") { rename(window) }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 330)
        }
        .sheet(item: Binding(get: { model.pendingPaste }, set: { if $0 == nil { model.cancelPaste() } })) { paste in
            VStack(alignment: .leading, spacing: 14) {
                Text(paste.plan.isPath ? "Review Escaped Path" : "Review Paste").font(.headline)
                Text("Target: \(paste.targetName)").font(.subheadline)
                Text("\(paste.plan.lineCount) line(s) · \(paste.plan.text.utf8.count) bytes · No newline added")
                    .font(.caption).foregroundStyle(model.themeColor(.mutedForeground))
                if paste.plan.unsupportedShell {
                    Text("This shell is not supported for path escaping. POSIX quoting is shown below; check it before pasting as text.")
                        .font(.callout)
                }
                ScrollView {
                    Text(paste.plan.preview).font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.frame(height: 220).background(model.themeColor(.background))
                Text("Controls appear in ⟨brackets⟩. Changing panes discards this review.")
                    .font(.caption).foregroundStyle(model.themeColor(.mutedForeground))
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelPaste() }.keyboardShortcut(.cancelAction)
                    Button(paste.plan.unsupportedShell ? "Paste Quoted Text" : "Paste") { model.confirmPaste(paste.id) }
                }
            }.padding(24).frame(width: 540)
        }
        .alert("Trellis", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var sessionStatusColor: Color {
        if model.usesNativeChrome { return .secondary }
        guard let terminal = model.activeTerminal else { return model.themeColor(.mutedForeground) }
        if terminal.sessionState == .failed || (terminal.sessionState == .exited && terminal.exitCode != 0) { return model.themeColor(.error) }
        return model.themeColor(terminal.sessionState == .running ? .success : .mutedForeground)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("WINDOWS").font(.system(size: 10, weight: .semibold)).foregroundStyle(model.themeColor(.mutedForeground))
                    .accessibilityHidden(true)
                Spacer()
                Button {
                    Task { await model.createWindow() }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain).help(shortcutHelp("New Window", .newWindow)).accessibilityLabel("New Window")
            }.padding(.horizontal, 10).padding(.bottom, 8)
            ScrollView {
                let descriptors = model.accessibility.windows
                VStack(spacing: 6) {
                    ForEach(model.snapshot.windows) { window in
                        windowRow(window, descriptor: descriptors.first { $0.id == window.id })
                    }
                }.accessibilityElement(children: .contain).accessibilityLabel("Windows")
            }
            Spacer(minLength: 0)
            Divider().overlay(model.separatorOverlay)
            Button {
                model.openSettings?()
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.plain).help("Settings (⌘,)").padding(.horizontal, 10).padding(.top, 6)
        }
        .font(.system(size: 12)).padding(.horizontal, 10).padding(.top, 20).padding(.bottom, 14)
        .background(model.themeColor(.sidebarBackground))
    }

    private func windowRow(_ window: ManagedWindow, descriptor: AccessibilityDescriptor?) -> some View {
        let selected = window.id == model.snapshot.activeWindowID
        return Button {
            Task { await model.selectWindow(window.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "macwindow").foregroundStyle(model.themeColor(.mutedForeground))
                Text(window.name).lineLimit(1).fontWeight(selected ? .semibold : .regular)
                Spacer()
                if model.activity[window.id]?.hasExit == true {
                    Image(systemName: "stop.circle").help("A session exited")
                } else if model.activity[window.id]?.hasOutput == true {
                    Circle().fill(model.themeColor(.accent)).frame(width: 6, height: 6).help("New terminal output")
                }
                Text("\(window.tabIDs.count)").foregroundStyle(model.themeColor(.mutedForeground)).font(.system(size: 10))
            }.padding(.horizontal, 10).padding(.vertical, 8)
                .background(selected ? model.sidebarSelectionBackground : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(descriptor?.label ?? window.name)
        .accessibilityValue(descriptor?.value ?? "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityAction(named: "Rename") { beginWindowRename(window) }
        .contextMenu {
            Button("Rename…") { beginWindowRename(window) }
            Button("Move Up") { Task { await model.moveWindow(window.id, offset: -1) } }
                .disabled(model.snapshot.windows.first?.id == window.id)
            Button("Move Down") { Task { await model.moveWindow(window.id, offset: 1) } }
                .disabled(model.snapshot.windows.last?.id == window.id)
            Divider().overlay(model.separatorOverlay)
            Button("Delete Window…", role: .destructive) { Task { await model.deleteWindow(window.id) } }
        }
    }

    private func beginWindowRename(_ window: ManagedWindow) {
        windowName = window.name
        windowToRename = window
    }

    private func rename(_ window: ManagedWindow) {
        let name = windowName
        windowToRename = nil
        Task { await model.renameWindow(window.id, name: name) }
    }

    @ViewBuilder private var mainArea: some View {
        if model.isRestoring {
            ProgressView("Restoring workspace…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = model.recoveryMessage {
            VStack(spacing: 16) {
                Text("Recover Workspace").font(.title2)
                Text(message).multilineTextAlignment(.center).frame(maxWidth: 430)
                if model.backupAvailable {
                    Button("Use Backup") { Task { await model.recoverWorkspace(useBackup: true) } }
                }
                Button("Start Empty") { Task { await model.recoverWorkspace(useBackup: false) } }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.presentation.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "terminal").font(.system(size: 34, weight: .light)).foregroundStyle(model.themeColor(.mutedForeground))
                Text("Your terminals, organized.").font(.system(size: 19, weight: .medium))
                Button("New Window") { Task { await model.createWindow() } }.keyboardShortcut("n")
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(model.themeColor(.background))
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(model.presentation.visibleTabs) { tab in
                                tabLabel(tab)
                                Divider().overlay(model.separatorOverlay).frame(height: 20)
                            }
                        }.accessibilityElement(children: .contain).accessibilityLabel("Tabs")
                    }.scrollIndicators(.hidden)
                    Button {
                        Task { await model.createTab() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain).padding(.horizontal, 14).help(shortcutHelp("New Tab", .newTab)).accessibilityLabel("New Tab")
                }.frame(height: 40).background(model.themeColor(.surface))
                Divider().overlay(model.separatorOverlay)
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(model.defaultDirectory.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    Spacer()
                    Text("Local")
                }.font(.system(size: 11)).foregroundStyle(model.themeColor(.mutedForeground)).padding(.horizontal, 14).frame(height: 31)
                Divider().overlay(model.separatorOverlay)
                terminalCanvas
            }
        }
    }

    private func tabLabel(_ tab: WorkspaceTab) -> some View {
        let selected = tab.id == model.presentation.selectedTab?.id
        let descriptor = model.accessibility.tabs.first { $0.id == tab.id }
        return HStack(spacing: 8) {
            Image(systemName: "terminal").font(.system(size: 10)).accessibilityHidden(true)
            if model.editingTabID == tab.id {
                TextField("Tab name", text: $model.tabRenameDraft)
                    .textFieldStyle(.plain).focused($tabNameFocused)
                    .accessibilityLabel("Tab name")
                    .accessibilityHint("Return saves, Escape cancels")
                    .onAppear { tabNameFocused = true }
                    .onSubmit { commitTabRename(tab.id) }
                    .onExitCommand {
                        Task { await model.finishTabRename(tab.id, draft: model.tabRenameDraft, action: .cancel) }
                    }
            } else {
                Text(tab.title).lineLimit(1)
                    .onTapGesture(count: 2) { beginTabRename(tab) }
                    .onTapGesture { Task { await model.selectTab(tab.id) } }
            }
            Button {
                Task { await model.closeTab(tab.id) }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain).help("Close Tab").accessibilityLabel("Close \(tab.title)")
        }.foregroundStyle(selected ? model.themeColor(.activeTabForeground) : model.themeColor(.foreground))
            .font(.system(size: 12, weight: selected ? .semibold : .regular)).padding(.horizontal, 14).frame(minWidth: 125, maxWidth: 220).frame(height: 40)
            .background(selected ? model.themeColor(.activeTabBackground) : .clear)
            .overlay(alignment: .bottom) {
                if selected { Rectangle().fill(model.themeColor(.accent)).frame(height: model.increaseContrast ? 3 : 2) }
            }
            .contentShape(Rectangle())
            .onTapGesture { if model.editingTabID != tab.id { Task { await model.selectTab(tab.id) } } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(descriptor?.label ?? "Tab \(tab.title)")
            .accessibilityValue(descriptor?.value ?? "")
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
            .accessibilityAction { Task { await model.selectTab(tab.id) } }
            .accessibilityAction(named: "Rename") { beginTabRename(tab) }
            .contextMenu {
                Button("Rename…") { beginTabRename(tab) }
                Button("Duplicate Tab") { Task { await model.createTab(windowID: tab.windowID, duplicate: tab.id) } }
                Button("Move Left") { Task { await model.moveTab(tab.id, offset: -1) } }
                    .disabled(model.presentation.visibleTabs.first?.id == tab.id)
                Button("Move Right") { Task { await model.moveTab(tab.id, offset: 1) } }
                    .disabled(model.presentation.visibleTabs.last?.id == tab.id)
                Divider().overlay(model.separatorOverlay)
                Button("Close Tab…") { Task { await model.closeTab(tab.id) } }
            }
    }

    private func beginTabRename(_ tab: WorkspaceTab) {
        Task { await model.beginTabRename(tab.id) }
    }
    private func commitTabRename(_ id: UUID) {
        let draft = model.tabRenameDraft
        Task { await model.finishTabRename(id, draft: draft, action: .commit) }
    }
    private func shortcutHelp(_ title: String, _ action: ShortcutAction) -> String {
        model.keyboard.shortcuts[action].map { "\(title) (\($0))" } ?? title
    }

    private var terminalCanvas: some View {
        GeometryReader { geometry in
            if let tab = model.presentation.selectedTab {
                let fullSize = CanvasDimensions.minimum(for: tab.root).fitting(width: geometry.size.width, height: geometry.size.height)
                let visible = model.maximizedPanes[tab.id].map(PaneLayout.pane) ?? tab.root
                let size = CanvasDimensions.minimum(for: visible).fitting(width: geometry.size.width, height: geometry.size.height)
                ScrollView([.horizontal, .vertical]) {
                    PaneTreeView(model: model, layout: visible, activePaneID: tab.activePaneID, tabID: tab.id)
                        .frame(width: size.width, height: size.height)
                }.background(model.terminalBackground)
                    .onAppear { model.setCanvasSize(fullSize, tabID: tab.id) }
                    .onChange(of: tab.id) { _, _ in model.setCanvasSize(fullSize, tabID: tab.id) }
                    .onChange(of: fullSize) { _, next in model.setCanvasSize(next, tabID: tab.id) }
            } else {
                model.terminalBackground
            }
        }
    }
}

struct NativeTerminalSurface: NSViewRepresentable {
    let terminal: NativeTerminal
    var isFocused = true
    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.display(terminal.view, focused: isFocused)
        return container
    }
    func updateNSView(_ view: TerminalContainerView, context: Context) { view.display(terminal.view, focused: isFocused) }
}

/// SwiftUI retains representables across selection changes. Keep a stable host,
/// but explicitly replace its terminal so input always reaches the selected pane.
final class TerminalContainerView: NSView {
    private var wasFocused = false
    private var desiredTerminal: NSView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcileAfterTreeUpdate()
    }

    func display(_ terminal: NSView, focused: Bool = true) {
        desiredTerminal = terminal
        let changed = subviews.first !== terminal
        if changed {
            subviews.forEach { $0.removeFromSuperview() }
            terminal.frame = bounds
            terminal.autoresizingMask = [.width, .height]
            addSubview(terminal)
        }
        if focused && (changed || !wasFocused) {
            DispatchQueue.main.async { [weak self, weak terminal] in
                guard let self, let terminal, self.wasFocused, terminal.superview === self,
                    self.window?.isKeyWindow == true
                else { return }
                self.window?.makeFirstResponder(terminal)
            }
        }
        wasFocused = focused
        reconcileAfterTreeUpdate()
    }

    private func reconcileAfterTreeUpdate() {
        // Collapsing a recursive SwiftUI split replaces several representable
        // hosts in one transaction. An old host can update after the new host
        // and temporarily reclaim its cached terminal. Reattach only from the
        // surviving native host once that transaction has finished.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, let terminal = self.desiredTerminal else { return }
            if terminal.superview !== self {
                self.subviews.forEach { $0.removeFromSuperview() }
                terminal.frame = self.bounds
                terminal.autoresizingMask = [.width, .height]
                self.addSubview(terminal)
                if self.wasFocused, self.window?.isKeyWindow == true {
                    self.window?.makeFirstResponder(terminal)
                }
            }
        }
    }
}

public struct LaunchSettingsView: View {
    @ObservedObject private var model: AppWorkspaceModel
    @State private var shell: String
    @State private var directory: String
    @State private var message = ""
    @State private var saving = false
    public init(model: AppWorkspaceModel) {
        self.model = model
        _shell = State(initialValue: model.defaultShell)
        _directory = State(initialValue: model.defaultDirectory)
    }
    public var body: some View {
        Form {
            TextField("Shell executable", text: $shell)
            TextField("Working directory", text: $directory)
            Text("Applies to new local sessions. Use absolute paths.").font(.caption).foregroundStyle(model.themeColor(.mutedForeground))
            if !message.isEmpty { Text(message).font(.caption).accessibilityIdentifier("settings.result") }
            HStack {
                Spacer()
                Button("Save") {
                    saving = true
                    Task {
                        let saved = await model.saveLaunchSettings(shell: shell, directory: directory)
                        message = saved ? "Saved for new sessions." : "Check that the shell is executable and the directory is accessible."
                        saving = false
                    }
                }.disabled(saving)
            }
        }.padding(24).frame(width: 450)
    }
}
