import AppKit
import SwiftUI
import TrellisCore

/// Saved-host list with search and a field-validated editor. Connecting is a
/// separate action; editing here only changes metadata for future connections.
public struct HostLibraryView: View {
    @ObservedObject private var model: HostListModel
    @ObservedObject private var workspace: AppWorkspaceModel
    @State private var selection: UUID?
    @State private var draft = HostDraft()
    @State private var errors: [HostField: String] = [:]
    @State private var message: String?
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var discovering = false
    @FocusState private var listFocused: Bool
    public init(model: HostListModel, workspace: AppWorkspaceModel) { self.model = model; self.workspace = workspace }

    private var editing: SavedHost? { selection.flatMap { id in model.hosts.first { $0.id == id } } }

    public var body: some View {
        // Mirrors AppSettingsView: themed sidebar, 1 px border, titled content pane.
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("HOSTS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(workspace.themeColor(.mutedForeground))
                    .padding(.horizontal, 12).padding(.top, 24).padding(.bottom, 6)
                TextField("Search hosts", text: $model.query)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Search hosts")
                    .accessibilityHint("Matches names, destinations, users, and tags")
                    .padding(.bottom, 6)
                // Plain-button rows aren't in the key loop without Full Keyboard Access, so the
                // list itself takes focus and moves the selection with the arrow keys like a List.
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.visibleHosts) { host in hostRow(host) }
                        }
                    }
                    .focusable().focused($listFocused)
                    .onKeyPress(.upArrow) { moveSelection(-1, proxy) }
                    .onKeyPress(.downArrow) { moveSelection(1, proxy) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Saved hosts")
                .overlay {
                    if model.visibleHosts.isEmpty {
                        Text(model.hosts.isEmpty ? "No saved hosts" : "No matching hosts").foregroundStyle(workspace.themeColor(.mutedForeground))
                    }
                }
                sidebarAction("New Host", symbol: "plus") {
                    selection = nil
                    load(nil)
                }
                sidebarAction("Discover SSH Aliases…", symbol: "doc.text.magnifyingglass") { discovering = true }
                    .disabled(model.loadFailed)
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
            .frame(width: 240)
            .background(workspace.themeColor(.sidebarBackground))
            Rectangle().fill(workspace.themeColor(.border)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(editing == nil ? "New Host" : "Edit Host").font(.system(size: 22, weight: .semibold))
                    Text(editing == nil ? "Save an SSH destination for quick connections." : "Edit saved details for future connections.")
                        .font(.callout).foregroundStyle(workspace.themeColor(.mutedForeground))
                }
                .padding(28)
                Divider().padding(.horizontal, 28)
                ScrollView { editor.padding(28) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(workspace.themeColor(.foreground))
            .background(workspace.themeColor(.background))
        }
        .tint(workspace.chromeTint)
        .preferredColorScheme(workspace.effectiveChromeMode.colorScheme)
        .frame(minWidth: 700, minHeight: 480)
        .onChange(of: selection) { _, id in
            let host = id.flatMap { id in model.hosts.first { $0.id == id } }
            // A save that just selected its own result already shows it; keep its message.
            if host == nil || host?.draft != draft { load(host) }
        }
        .task { await model.load() }
        .sheet(isPresented: $discovering) { AliasDiscoveryView(model: model) }
        .confirmationDialog("Delete “\(editing?.name ?? "")”?", isPresented: $confirmingDelete) {
            Button("Delete Host", role: .destructive) { delete() }
        } message: {
            Text("Only Trellis’s saved details are removed. SSH keys, ssh_config, and known_hosts are not changed, and open sessions keep running.")
        }
    }

    @ViewBuilder private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.loadFailed {
                VStack(alignment: .leading, spacing: 6) {
                    Text(HostListModel.message(for: .readOnly)).font(.callout)
                    Button("Reset Host Library") {
                        Task { message = await model.resetUnreadable() ? "The unreadable file was kept beside the new library." : "The host library could not be reset." }
                    }
                }
            }
            field("Name", text: $draft.name, error: errors[.name], prompt: "Production API")
            field("SSH alias or hostname", text: $draft.destination, error: errors[.destination], prompt: "prod-api or api.example.com")
            HStack(alignment: .top) {
                field("User (optional)", text: $draft.user, error: errors[.user], prompt: "deploy")
                field("Port (optional)", text: $draft.port, error: errors[.port], prompt: "22").frame(width: 130)
            }
            HStack(alignment: .bottom) {
                field("Identity file (optional)", text: $draft.identityFile, error: errors[.identityFile], prompt: "/Users/you/.ssh/id_ed25519")
                Button("Choose…", action: chooseIdentity).accessibilityLabel("Choose identity file")
            }
            field("Tags (comma-separated)", text: $draft.tags, error: errors[.tags], prompt: "prod, api")
            Text("Trellis stores no passwords or key contents. Changes apply to future connections only.")
                .font(.caption).foregroundStyle(workspace.themeColor(.mutedForeground)).fixedSize(horizontal: false, vertical: true)
            if let message { Text(message).font(.caption).accessibilityIdentifier("hosts.result") }
            if let host = editing {
                HStack {
                    Button("Connect in New Tab") { model.onConnect?(host, .newTab) }
                        .accessibilityHint("Starts a new ssh process for \(host.name)")
                    Menu("Connect in Split") {
                        Button("Left/Right") { model.onConnect?(host, .split(.x)) }
                        Button("Top/Bottom") { model.onConnect?(host, .split(.y)) }
                    }
                    .fixedSize()
                }
                .disabled(model.onConnect == nil || draft != host.draft)
                if draft != host.draft {
                    Text("Save or revert your changes before connecting.").font(.caption).foregroundStyle(workspace.themeColor(.mutedForeground))
                }
            }
            HStack {
                if editing != nil {
                    Button("Delete…", role: .destructive) { confirmingDelete = true }.disabled(saving)
                }
                Spacer()
                Button(editing == nil ? "Add Host" : "Save Changes", action: save)
                    .keyboardShortcut(.defaultAction).disabled(saving || model.loadFailed)
            }
        }
    }

    private func hostRow(_ host: SavedHost) -> some View {
        let selected = selection == host.id
        return Button {
            selection = host.id; listFocused = true
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).lineLimit(1).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(workspace.themeColor(selected ? .activeTabForeground : .foreground))
                Text(summary(host)).font(.caption).foregroundStyle(workspace.themeColor(.mutedForeground)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(selected ? workspace.themeColor(.activeTabBackground) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Host \(host.name)")
        .accessibilityValue(summary(host))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func moveSelection(_ step: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = model.visibleHosts.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let index = selection.flatMap { ids.firstIndex(of: $0) }.map { min(max($0 + step, 0), ids.count - 1) } ?? (step > 0 ? 0 : ids.count - 1)
        selection = ids[index]; proxy.scrollTo(ids[index])
        return .handled
    }

    private func sidebarAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
            .foregroundStyle(workspace.themeColor(.foreground))
        }
        .buttonStyle(.plain)
    }

    private func field(_ title: String, text: Binding<String>, error: String?, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(workspace.themeColor(.mutedForeground))
            TextField(title, text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder).labelsHidden()
                .accessibilityLabel(title)
                .accessibilityValue(error.map { "\(text.wrappedValue). Error: \($0)" } ?? text.wrappedValue)
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).accessibilityHidden(true)
            }
        }
    }

    private func summary(_ host: SavedHost) -> String {
        var text = (host.user.map { "\($0)@" } ?? "") + host.destination
        if let port = host.port { text += ":\(port)" }
        if !host.tags.isEmpty { text += " · " + host.tags.joined(separator: ", ") }
        return text
    }

    private func load(_ host: SavedHost?) {
        draft = host?.draft ?? HostDraft()
        errors = [:]
        message = nil
    }

    private func save() {
        saving = true
        let current = editing, origin = selection
        Task {
            let result = await model.save(draft, editing: current)
            saving = false
            // The user moved to another host while saving; don't overwrite that editor.
            guard selection == origin else { return }
            switch result {
            case .success(let host):
                errors = [:]
                selection = host.id
                draft = host.draft
                message = current == nil ? "Host added." : "Changes saved for future connections."
            case .failure(let error):
                if case .invalid(let validation) = error { errors = validation.fields }
                message = HostListModel.message(for: error)
            }
        }
    }

    private func delete() {
        guard let host = editing else { return }
        Task {
            let failure = await model.delete(host)
            guard selection == host.id else { return }
            if let failure {
                message = HostListModel.message(for: failure)
            } else {
                selection = nil
                load(nil)
                message = "Host deleted. SSH files and open sessions were not changed."
            }
        }
    }

    private func chooseIdentity() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        panel.message = "Choose a private key file. Trellis stores only its path."
        // Only the path is recorded; the key file is never opened by Trellis.
        if panel.runModal() == .OK, let url = panel.url { draft.identityFile = url.path }
    }
}
