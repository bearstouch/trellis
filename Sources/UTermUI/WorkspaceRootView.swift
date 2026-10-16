import SwiftUI
import UTermCore
import UTermTerminal

public struct WorkspaceRootView: View {
    @ObservedObject private var model: AppWorkspaceModel
    @State private var windowToRename: ManagedWindow?
    @State private var windowName = ""
    @State private var editingTabID: UUID?
    @State private var tabDraft = ""
    @FocusState private var tabNameFocused: Bool
    public init(model: AppWorkspaceModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 205).disabled(model.isRestoring || model.recoveryMessage != nil)
                Divider()
                mainArea
            }
            Divider()
            HStack(spacing: 8) {
                Text(model.presentation.selectedWindow?.name ?? "uTerm")
                Spacer()
                if model.persistenceReadOnly { Text("Changes won’t be saved") }
                if let notice = model.appearanceNotice { Text(notice).lineLimit(1).help(notice) }
                Text(sessionStatus)
                Text("·  UTF-8  ·  Local")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 28)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .preferredColorScheme(model.appearance.chromeMode.colorScheme)
        .onChange(of: model.tabRenameRequest) { _, _ in
            if let tab = model.presentation.selectedTab { beginTabRename(tab) }
        }
        .onChange(of: model.snapshot.activeWindowID) { _, _ in editingTabID = nil }
        .onChange(of: model.presentation.selectedTab?.id) { _, selectedID in
            // Beginning a rename selects an inactive tab first. That selection
            // notification may arrive after the editor state has been installed.
            if editingTabID != selectedID { editingTabID = nil }
        }
        .onChange(of: editingTabID) { _, value in
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
                    .font(.caption).foregroundStyle(.secondary)
                if paste.plan.unsupportedShell {
                    Text("This shell is not supported for path escaping. POSIX quoting is shown below; check it before pasting as text.")
                        .font(.callout)
                }
                ScrollView {
                    Text(paste.plan.preview).font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.frame(height: 220).background(Color(nsColor: .textBackgroundColor))
                Text("Controls appear in ⟨brackets⟩. Changing panes discards this review.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelPaste() }.keyboardShortcut(.cancelAction)
                    Button(paste.plan.unsupportedShell ? "Paste Quoted Text" : "Paste") { model.confirmPaste(paste.id) }
                }
            }.padding(24).frame(width: 540)
        }
        .alert("uTerm", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var sessionStatus: String {
        guard let terminal = model.activeTerminal else { return "No session" }
        if terminal.sessionState == .exited, let code = terminal.exitCode { return "Exited (\(code))" }
        return terminal.sessionState.rawValue.capitalized
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("WINDOWS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await model.createWindow() } } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("New Window").accessibilityLabel("New Window")
            }.padding(.horizontal, 10).padding(.bottom, 8)
            ScrollView {
            VStack(spacing: 6) {
            ForEach(model.snapshot.windows) { window in
                Button { Task { await model.selectWindow(window.id) } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "macwindow").foregroundStyle(.secondary)
                        Text(window.name).lineLimit(1)
                        Spacer()
                        if model.activity[window.id]?.hasExit == true {
                            Image(systemName: "stop.circle").help("A session exited").accessibilityLabel("Session exited")
                        } else if model.activity[window.id]?.hasOutput == true {
                            Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("New terminal output").accessibilityLabel("New output")
                        }
                        Text("\(window.tabIDs.count)").foregroundStyle(.secondary).font(.system(size: 10))
                    }.padding(.horizontal, 10).padding(.vertical, 8)
                        .background(window.id == model.snapshot.activeWindowID ? Color.accentColor.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(window.name)
                    .accessibilityAddTraits(window.id == model.snapshot.activeWindowID ? [.isSelected] : [])
                    .contextMenu {
                        Button("Rename…") { windowName = window.name; windowToRename = window }
                        Button("Move Up") { Task { await model.moveWindow(window.id, offset: -1) } }
                            .disabled(model.snapshot.windows.first?.id == window.id)
                        Button("Move Down") { Task { await model.moveWindow(window.id, offset: 1) } }
                            .disabled(model.snapshot.windows.last?.id == window.id)
                        Divider()
                        Button("Delete Window…", role: .destructive) { Task { await model.deleteWindow(window.id) } }
                    }
            }
            }
            }
            Spacer(minLength: 0)
            Divider()
            Button { model.openSettings?() } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                .buttonStyle(.plain).padding(.horizontal, 10).padding(.top, 6)
        }
        .font(.system(size: 12)).padding(.horizontal, 10).padding(.top, 20).padding(.bottom, 14)
        .background(Color(nsColor: .windowBackgroundColor))
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
                Image(systemName: "terminal").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                Text("Your terminals, organized.").font(.system(size: 19, weight: .medium))
                Button("New Window") { Task { await model.createWindow() } }.keyboardShortcut("n")
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(model.presentation.visibleTabs) { tab in
                                tabLabel(tab)
                                Divider().frame(height: 20)
                            }
                        }
                    }.scrollIndicators(.hidden)
                    Button { Task { await model.createTab() } } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).padding(.horizontal, 14).help("New Tab (⌘T)").accessibilityLabel("New Tab")
                }.frame(height: 40).background(Color(nsColor: .windowBackgroundColor))
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(model.defaultDirectory.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    Spacer()
                    Text("Local")
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 31)
                Divider()
                terminalCanvas
            }
        }
    }

    private func tabLabel(_ tab: WorkspaceTab) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").font(.system(size: 10))
            if editingTabID == tab.id {
                TextField("Tab name", text: $tabDraft)
                    .textFieldStyle(.plain).focused($tabNameFocused)
                    .onAppear { tabNameFocused = true }
                    .onSubmit { commitTabRename(tab.id) }
                    .onExitCommand {
                        editingTabID = nil
                        Task { await model.finishTabRename(tab.id, draft: tabDraft, action: .cancel) }
                    }
            } else {
                Text(tab.title).lineLimit(1)
                    .onTapGesture(count: 2) { beginTabRename(tab) }
                    .onTapGesture { Task { await model.selectTab(tab.id) } }
            }
            Button { Task { await model.closeTab(tab.id) } } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain).help("Close Tab").accessibilityLabel("Close \(tab.title)")
        }.font(.system(size: 12)).padding(.horizontal, 14).frame(minWidth: 125, maxWidth: 220).frame(height: 40)
            .background(tab.id == model.presentation.selectedTab?.id ? Color(nsColor: .textBackgroundColor) : .clear)
            .overlay(alignment: .bottom) {
                if tab.id == model.presentation.selectedTab?.id { Rectangle().fill(Color.accentColor).frame(height: 2) }
            }
            .contentShape(Rectangle())
            .onTapGesture { if editingTabID != tab.id { Task { await model.selectTab(tab.id) } } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tab \(tab.title)")
            .accessibilityAddTraits(tab.id == model.presentation.selectedTab?.id ? [.isSelected] : [])
            .contextMenu {
                Button("Rename…") { beginTabRename(tab) }
                Button("Duplicate Tab") { Task { await model.createTab(windowID: tab.windowID, duplicate: tab.id) } }
                Button("Move Left") { Task { await model.moveTab(tab.id, offset: -1) } }
                    .disabled(model.presentation.visibleTabs.first?.id == tab.id)
                Button("Move Right") { Task { await model.moveTab(tab.id, offset: 1) } }
                    .disabled(model.presentation.visibleTabs.last?.id == tab.id)
                Divider()
                Button("Close Tab…") { Task { await model.closeTab(tab.id) } }
            }
    }

    private func beginTabRename(_ tab: WorkspaceTab) {
        Task {
            await model.selectTab(tab.id)
            guard model.presentation.selectedTab?.id == tab.id else { return }
            tabDraft = tab.title
            editingTabID = tab.id
        }
    }
    private func commitTabRename(_ id: UUID) {
        let draft = tabDraft
        editingTabID = nil
        Task { await model.finishTabRename(id, draft: draft, action: .commit) }
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
                }.background(Color(red: 0.082, green: 0.09, blue: 0.098))
                    .onAppear { model.setCanvasSize(fullSize, tabID: tab.id) }
                    .onChange(of: tab.id) { _, _ in model.setCanvasSize(fullSize, tabID: tab.id) }
                    .onChange(of: fullSize) { _, next in model.setCanvasSize(next, tabID: tab.id) }
            } else { Color(red: 0.082, green: 0.09, blue: 0.098) }
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
                      self.window?.isKeyWindow == true else { return }
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
            Text("Applies to new local sessions. Use absolute paths.").font(.caption).foregroundStyle(.secondary)
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
