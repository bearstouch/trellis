import SwiftUI
import UTermCore
import UTermTerminal

public struct WorkspaceRootView: View {
    @ObservedObject private var model: AppWorkspaceModel
    @State private var windowToRename: ManagedWindow?
    @State private var windowName = ""
    public init(model: AppWorkspaceModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 205)
                Divider()
                mainArea
            }
            Divider()
            HStack(spacing: 8) {
                Text(model.presentation.selectedWindow?.name ?? "uTerm")
                Spacer()
                Text(model.activeTerminal?.sessionState.rawValue.capitalized ?? "No session")
                Text("·  UTF-8  ·  Local")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 28)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .preferredColorScheme(.light)
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
        .alert("uTerm", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
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
        if model.presentation.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "terminal").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                Text("Your terminals, organized.").font(.system(size: 19, weight: .medium))
                Button("New Window") { Task { await model.createWindow() } }.keyboardShortcut("n")
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(model.presentation.visibleTabs) { tab in
                        HStack(spacing: 8) {
                            Image(systemName: "terminal").font(.system(size: 10))
                            Text(tab.title).lineLimit(1)
                        }.font(.system(size: 12)).padding(.horizontal, 16).frame(height: 40)
                            .background(Color(nsColor: .textBackgroundColor))
                            .overlay(alignment: .bottom) { Rectangle().fill(Color.accentColor).frame(height: 2) }
                        Divider().frame(height: 20)
                    }
                    Spacer(minLength: 0)
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

    private var terminalCanvas: some View {
        GeometryReader { geometry in
            if let tab = model.presentation.selectedTab, let terminal = model.activeTerminal {
                let minimum = CanvasDimensions.minimum(for: tab.root)
                let size = minimum.fitting(width: geometry.size.width, height: geometry.size.height)
                ScrollView([.horizontal, .vertical]) {
                    NativeTerminalSurface(terminal: terminal).frame(width: size.width, height: size.height)
                }.background(Color(red: 0.082, green: 0.09, blue: 0.098))
                    .overlay(alignment: .center) {
                        if terminal.sessionState == .stopped, let pane = model.presentation.activePane {
                            Button("Start Session") { Task { await model.start(paneID: pane.id) } }.buttonStyle(.borderedProminent)
                        }
                    }
            } else { Color(red: 0.082, green: 0.09, blue: 0.098) }
        }
    }
}

private struct NativeTerminalSurface: NSViewRepresentable {
    let terminal: NativeTerminal
    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.display(terminal.view)
        return container
    }
    func updateNSView(_ view: TerminalContainerView, context: Context) { view.display(terminal.view) }
}

/// SwiftUI retains representables across selection changes. Keep a stable host,
/// but explicitly replace its terminal so input always reaches the selected pane.
final class TerminalContainerView: NSView {
    func display(_ terminal: NSView) {
        guard subviews.first !== terminal else { return }
        subviews.forEach { $0.removeFromSuperview() }
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
        DispatchQueue.main.async { [weak self, weak terminal] in
            guard let self, let terminal, terminal.superview === self,
                  self.window?.isKeyWindow == true else { return }
            self.window?.makeFirstResponder(terminal)
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
        }.padding(24).frame(width: 450).preferredColorScheme(.light)
    }
}
