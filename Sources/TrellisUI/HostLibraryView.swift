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
    /// Typed only; a saved password is never read back into the editor.
    @State private var passwordDraft = ""
    @State private var replacingPassword = false
    @State private var requiresUserPresence = false
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
            Text(
                "Trellis’s saved details and any saved password in the Keychain are removed. SSH keys, ssh_config, and known_hosts are not changed, and open sessions keep running."
            )
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
            passwordSection
            Text("Trellis never stores key contents. Changes apply to future connections only.")
                .font(.caption).foregroundStyle(workspace.themeColor(.mutedForeground)).fixedSize(horizontal: false, vertical: true)
            if let message { Text(message).font(.caption).accessibilityIdentifier("hosts.result") }
            if let host = editing, let remote = model.remote {
                RemoteHelperSection(host: host, remote: remote, workspace: workspace, disabled: hasUnsavedChanges(host))
            }
            if let host = editing {
                HStack {
                    Button("Connect in New Tab") { model.onConnect?(host, .newTab) }
                        .accessibilityHint("Starts a new ssh process for \(host.name)")
                    Button("Connect in New Window") { model.onConnect?(host, .newWindow) }
                        .accessibilityHint("Opens a new window and starts a new ssh process for \(host.name)")
                    if model.remote != nil, let open = model.onOpenRemoteWorkspace {
                        Button("Open Remote Workspace") { open(host) }
                            .accessibilityHint("Opens a window whose sessions run on \(host.name) and keep running when the connection drops")
                    }
                }
                .disabled(model.onConnect == nil || hasUnsavedChanges(host))
                if hasUnsavedChanges(host) {
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

    private var hasSavedPassword: Bool { editing?.savedPassword != nil }

    private func hasUnsavedChanges(_ host: SavedHost) -> Bool {
        draft != host.draft || !passwordDraft.isEmpty || (host.savedPassword.map { $0.requiresUserPresence != requiresUserPresence } ?? false)
    }

    @ViewBuilder private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Password (optional)").font(.caption).foregroundStyle(workspace.themeColor(.mutedForeground))
            if hasSavedPassword && !replacingPassword {
                HStack {
                    Label("Saved in Keychain", systemImage: "key.fill").accessibilityLabel("Password saved in the Keychain")
                    Spacer()
                    Button("Replace…") { replacingPassword = true }.accessibilityLabel("Replace saved password")
                    Button("Remove", role: .destructive, action: removePassword).accessibilityLabel("Remove saved password").disabled(saving)
                }
            } else {
                HStack {
                    SecureField("Password", text: $passwordDraft, prompt: Text(hasSavedPassword ? "New password" : "Not saved"))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                        .accessibilityLabel(hasSavedPassword ? "New password" : "Password")
                        .accessibilityValue(errors[.password].map { "Error: \($0)" } ?? "")
                    if replacingPassword {
                        Button("Cancel") {
                            replacingPassword = false; passwordDraft = ""; errors[.password] = nil
                        }
                    }
                }
                if let error = errors[.password] {
                    Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).accessibilityHidden(true)
                }
            }
            if hasSavedPassword || !passwordDraft.isEmpty {
                Toggle("Require Touch ID or Mac password to use", isOn: $requiresUserPresence)
                    .accessibilityHint("Asks before each connection that uses the saved password")
            }
            Text(
                "Stored only in this Mac’s Keychain and given to ssh only when it asks for this host’s password. Host-key checks and passphrases stay in the terminal. Changing the destination, user, port, or identity file removes it."
            )
            .font(.caption).foregroundStyle(workspace.themeColor(.mutedForeground)).fixedSize(horizontal: false, vertical: true)
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
        passwordDraft = ""; replacingPassword = false
        requiresUserPresence = host?.savedPassword?.requiresUserPresence ?? false
        errors = [:]
        message = nil
    }

    private func save() {
        // Validate the password before any write, so a bad one never leaves a half-saved host.
        var password: Data?
        if !passwordDraft.isEmpty {
            do { password = try HostPassword.validated(passwordDraft) } catch {
                errors = error.fields; message = HostListModel.message(for: .invalid(error))
                return
            }
        }
        saving = true
        let current = editing, origin = selection, presence = requiresUserPresence
        Task {
            var result = await model.save(draft, editing: current)
            if case .success(let host) = result {
                if let password {
                    result = await model.setPassword(host, .save(password, requiresUserPresence: presence))
                } else if let policy = host.savedPassword, policy.requiresUserPresence != presence {
                    result = await model.setPassword(host, .policy(requiresUserPresence: presence))
                }
            }
            saving = false
            // The user moved to another host while saving; don't overwrite that editor.
            guard selection == origin else { return }
            switch result {
            case .success(let host):
                errors = [:]
                selection = host.id
                load(host)
                if current?.savedPassword != nil, host.savedPassword == nil {
                    message = "Changes saved. The saved password was removed because the connection changed."
                } else {
                    message = current == nil ? "Host added." : "Changes saved for future connections."
                }
            case .failure(let error):
                if case .invalid(let validation) = error { errors = validation.fields }
                // A created host stays selected even if its password could not be saved.
                if current == nil, let created = model.hosts.first(where: { $0.draft == draft }) { selection = created.id }
                message = HostListModel.message(for: error)
            }
        }
    }

    private func removePassword() {
        guard let host = editing else { return }
        saving = true
        Task {
            let result = await model.setPassword(host, .remove)
            saving = false
            guard selection == host.id else { return }
            switch result {
            case .success(let updated): load(updated); message = "Saved password removed from the Keychain."
            case .failure(let error): message = HostListModel.message(for: error)
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

/// FR-RW17: the helper's last observed status on this host, its actions, and the auto-install choice.
private struct RemoteHelperSection: View {
    let host: SavedHost
    @ObservedObject var remote: RemoteHostsModel
    @ObservedObject var workspace: AppWorkspaceModel
    let disabled: Bool

    var body: some View {
        let preferences = remote.preferences(host)
        let busy = remote.activity[host.id]
        VStack(alignment: .leading, spacing: 6) {
            Text("Remote helper").font(.caption).foregroundStyle(workspace.themeColor(.mutedForeground))
            HStack(spacing: 6) {
                Image(systemName: symbol(preferences.helper?.state)).accessibilityHidden(true)
                Text(preferences.helper?.summary ?? "Unknown (never checked)").accessibilityIdentifier("hosts.helperStatus")
                if let checked = preferences.helper?.checkedAt {
                    Text("· checked \(checked.formatted(.relative(presentation: .named)))").foregroundStyle(workspace.themeColor(.mutedForeground))
                }
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
            HStack {
                Group {
                    Button("Check Helper Status") { Task { await remote.check(host) } }.accessibilityHint("Connects to \(host.name) and reports the helper's status")
                    Button(preferences.helper?.state == .outdated ? "Update Helper…" : "Install Trellis Helper…") { Task { await remote.install(host) } }
                        .disabled(preferences.helper?.state == .current || preferences.helper?.state == .unsupported)
                    Button("Remove Helper…", role: .destructive) { Task { await remote.remove(host) } }
                        .disabled(!(preferences.helper?.state == .current || preferences.helper?.state == .outdated))
                }
                .disabled(disabled || !remote.isAvailable || busy != nil)
                // Outside the disabled group: a running action must stay cancellable.
                if busy != nil {
                    ProgressView().controlSize(.small).accessibilityLabel(label(busy))
                    Button("Cancel") { remote.cancel(host) }
                }
            }
            Toggle(
                "Install helper automatically when opening a remote workspace",
                isOn: Binding(get: { preferences.autoInstall }, set: { value in Task { await remote.setAutoInstall(host, value) } })
            ).accessibilityIdentifier("hosts.autoInstallHelper")
            if let message = remote.messages[host.id] { Text(message).font(.caption).accessibilityIdentifier("hosts.helperResult") }
            Text("The helper keeps sessions running on the host. It lives in ~/.trellis there and needs no administrator rights.")
                .font(.caption).foregroundStyle(workspace.themeColor(.mutedForeground)).fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $remote.console) { console in RemoteConsoleSheet(console: console, close: { remote.console = nil }) }
    }

    private func symbol(_ state: RemoteHelperRecord.State?) -> String {
        switch state {
        case .current: "checkmark.circle"
        case .outdated: "arrow.up.circle"
        case .missing: "minus.circle"
        case .unsupported: "exclamationmark.triangle"
        case nil: "questionmark.circle"
        }
    }

    private func label(_ activity: RemoteHostsModel.Activity?) -> String {
        switch activity {
        case .checking: "Checking the helper"
        case .installing: "Installing the helper"
        case .removing: "Removing the helper"
        case nil: ""
        }
    }
}

/// ssh's own terminal for a host: host-key questions, passwords and one-time codes are answered here (FR-H04).
private struct RemoteConsoleSheet: View {
    let console: RemoteHostsModel.Console
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connecting to \(console.hostName)").font(.headline)
            Text("This is ssh’s own terminal. Answer its questions here; Trellis never answers them for you.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            NativeTerminalSurface(terminal: console.terminal).frame(minWidth: 560, minHeight: 240)
                .accessibilityLabel("ssh connection console for \(console.hostName)")
            HStack {
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
    }
}
