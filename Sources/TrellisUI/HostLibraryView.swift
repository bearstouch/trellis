import AppKit
import SwiftUI
import TrellisCore

/// Saved-host list with search and a field-validated editor. Connecting is a
/// separate action; editing here only changes metadata for future connections.
public struct HostLibraryView: View {
    @ObservedObject private var model: HostListModel
    @State private var selection: UUID?
    @State private var draft = HostDraft()
    @State private var errors: [HostField: String] = [:]
    @State private var message: String?
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var discovering = false
    public init(model: HostListModel) { self.model = model }

    private var editing: SavedHost? { selection.flatMap { id in model.hosts.first { $0.id == id } } }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                TextField("Search hosts", text: $model.query)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Search hosts")
                    .accessibilityHint("Matches names, destinations, users, and tags")
                List(model.visibleHosts, selection: $selection) { host in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.name).lineLimit(1)
                        Text(summary(host)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(host.id)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Host \(host.name)")
                    .accessibilityValue(summary(host))
                }
                .accessibilityLabel("Saved hosts")
                .overlay {
                    if model.visibleHosts.isEmpty {
                        Text(model.hosts.isEmpty ? "No saved hosts" : "No matching hosts").foregroundStyle(.secondary)
                    }
                }
                Button {
                    selection = nil
                    load(nil)
                } label: {
                    Label("New Host", systemImage: "plus")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    discovering = true
                } label: {
                    Label("Discover SSH Aliases…", systemImage: "doc.text.magnifyingglass")
                }
                .frame(maxWidth: .infinity, alignment: .leading).disabled(model.loadFailed)
            }
            .padding(12).frame(width: 240)
            Divider()
            editor.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 640, minHeight: 420)
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
            Text(editing == nil ? "New Host" : "Edit Host").font(.headline)
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
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message { Text(message).font(.caption).accessibilityIdentifier("hosts.result") }
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

    private func field(_ title: String, text: Binding<String>, error: String?, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption)
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
