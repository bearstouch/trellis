import AppKit
import SwiftUI
import TrellisControl
import TrellisCore

/// Main-actor mirror of the grant store for Settings → Automation.
@MainActor
public final class GrantListModel: ObservableObject {
    @Published public private(set) var grants: [AutomationGrant] = []
    @Published public private(set) var now = Date()
    private let store: GrantStore
    public init(store: GrantStore) { self.store = store }

    public func refresh() async {
        grants = await store.grants.sorted { $0.createdAt > $1.createdAt }
        now = await store.currentDate()
    }

    public func create(
        name: String, capabilities: Set<Capability>, windowScope: WindowScope, hostScope: HostScope, lifetime: TimeInterval
    ) async -> Result<String, GrantError> {
        defer { Task { await refresh() } }
        do {
            return .success(try await store.create(name: name, capabilities: capabilities, windowScope: windowScope, hostScope: hostScope, lifetime: lifetime).token)
        } catch { return .failure(error) }
    }

    /// Revocation blocks the grant at once; a failed save is reported because the grant would return after relaunch.
    public func revoke(_ id: UUID) async -> GrantError? {
        defer { Task { await refresh() } }
        do { try await store.revoke(id) } catch { return error }
        return nil
    }

    public func reapprove(_ id: UUID, hosts: [SavedHost]) async -> GrantError? {
        defer { Task { await refresh() } }
        do {
            try await store.approveHosts(id, hosts: hosts.map { SavedHostApprovalInput(id: $0.id, connectionRevision: $0.connectionRevision) })
        } catch { return error }
        return nil
    }

    static func message(for error: GrantError) -> String {
        switch error {
        case .invalidName: "Enter a name up to 100 characters."
        case .noCapabilities: "Choose at least one capability."
        case .invalidExpiry: "Choose an expiry between one minute and 90 days."
        case .notFound: "That grant no longer exists."
        case .io: "The grant could not be saved. Check disk space and permissions."
        case .secretStore: "The token could not be stored in the Keychain. Nothing was created."
        case .readOnly: "grants.json could not be read, so it was left untouched and no grant is active. Move it aside to manage grants."
        }
    }
}

struct AutomationSettingsView: View {
    @ObservedObject var grants: GrantListModel
    @ObservedObject var workspace: AppWorkspaceModel
    @ObservedObject var hosts: HostListModel
    @State private var creating = false
    @State private var revoking: AutomationGrant?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scripts and agents connect through a local socket using a grant token. Each grant allows only the capabilities and windows you choose.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("Grants reduce accidental or unauthorized access, but any program running as your macOS user could still read your files or the Keychain item. Only grant access to software you trust.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                if grants.grants.isEmpty { Text("No grants yet.").foregroundStyle(.secondary) }
                ForEach(grants.grants) { grant in row(grant) }
            }
            .frame(minHeight: 200).accessibilityLabel("Automation grants")
            HStack {
                if let failure { Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                Spacer()
                Button("New Grant…") { creating = true }
            }
        }
        .padding(16)
        .task { await grants.refresh() }
        .sheet(isPresented: $creating) { NewGrantView(grants: grants, workspace: workspace, hosts: hosts) }
        .confirmationDialog("Revoke “\(revoking?.name ?? "")”?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            Button("Revoke Grant", role: .destructive) {
                if let id = revoking?.id {
                    Task {
                        let error = await grants.revoke(id)
                        failure = error.map { "Revoked for now, but not saved: \(GrantListModel.message(for: $0)) Revoke again before relaunching." }
                    }
                }
            }
        } message: {
            Text("Connected clients using this grant are disconnected immediately and the token stops working.")
        }
    }

    private func status(_ grant: AutomationGrant) -> String {
        if grant.revokedAt != nil { return "Revoked" }
        if !grant.isActive(at: grants.now) { return "Expired" }
        return "Active until \(grant.expiresAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func staleHosts(_ grant: AutomationGrant) -> [SavedHost] {
        guard case .approved(let approvals) = grant.hostScope else { return [] }
        return approvals.compactMap { approval in hosts.hosts.first { $0.id == approval.hostID && $0.connectionRevision != approval.connectionRevision } }
    }

    private func row(_ grant: AutomationGrant) -> some View {
        let stale = staleHosts(grant)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(grant.name).fontWeight(.semibold)
                Spacer()
                Text(status(grant)).font(.caption)
                if grant.isActive(at: grants.now) {
                    Button("Revoke…") { revoking = grant }.accessibilityLabel("Revoke \(grant.name)")
                }
            }
            Text(grant.capabilities.sorted().map(\.rawValue).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            Text(scopeText(grant)).font(.caption).foregroundStyle(.secondary)
            if !stale.isEmpty, grant.isActive(at: grants.now), case .approved(let approvals) = grant.hostScope {
                HStack {
                    Label("Changed since approval: \(stale.map(\.name).joined(separator: ", "))", systemImage: "exclamationmark.triangle").font(.caption)
                    Button("Reapprove") {
                        let current = hosts.hosts.filter { host in approvals.contains { $0.hostID == host.id } }
                        Task { failure = await grants.reapprove(grant.id, hosts: current).map(GrantListModel.message(for:)) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func scopeText(_ grant: AutomationGrant) -> String {
        let windows: String
        switch grant.windowScope {
        case .all: windows = "All windows"
        case .windows(let ids):
            let names = workspace.snapshot.windows.filter { ids.contains($0.id) }.map(\.name)
            windows = names.isEmpty ? "No current windows" : "Windows: " + names.joined(separator: ", ")
        }
        let hostText: String
        switch grant.hostScope {
        case .all: hostText = "all hosts"
        case .approved(let approvals): hostText = approvals.isEmpty ? "no hosts" : "\(approvals.count) approved host(s)"
        }
        return "\(windows) · \(hostText)"
    }
}

private struct NewGrantView: View {
    @ObservedObject var grants: GrantListModel
    @ObservedObject var workspace: AppWorkspaceModel
    @ObservedObject var hosts: HostListModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var capabilities: Set<Capability> = [.metadataRead]
    @State private var allWindows = true
    @State private var windows = Set<UUID>()
    @State private var allHosts = false
    @State private var approvedHosts = Set<UUID>()
    @State private var lifetime: TimeInterval = 86_400
    @State private var token: String?
    @State private var message: String?
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let token {
                Text("Grant Created").font(.headline)
                Text("Copy this token now. It is not shown again. The CLI can also read it from the Keychain item “\(KeychainGrantSecretStore.service)”.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(token).font(.system(.body, design: .monospaced)).textSelection(.enabled).accessibilityLabel("Grant token")
                HStack {
                    Button("Copy Token") {
                        // Concealed: clipboard managers that honor the marker skip recording it.
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(token, forType: .string)
                        NSPasteboard.general.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                    }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                form
            }
        }
        .padding(20).frame(width: 520)
    }

    @ViewBuilder private var form: some View {
        Text("New Automation Grant").font(.headline)
        TextField("Name", text: $name, prompt: Text("Build agent")).accessibilityLabel("Grant name")
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Capability.allCases, id: \.self) { capability in
                    Toggle(isOn: Binding(get: { capabilities.contains(capability) }, set: { if $0 { capabilities.insert(capability) } else { capabilities.remove(capability) } })) {
                        VStack(alignment: .leading) {
                            Text(capability.rawValue).font(.system(.body, design: .monospaced))
                            Text(capability.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                Toggle("All windows (needed to create windows, apply layouts, or change themes)", isOn: $allWindows)
                if !allWindows {
                    ForEach(workspace.snapshot.windows) { window in
                        Toggle(window.name, isOn: Binding(get: { windows.contains(window.id) }, set: { if $0 { windows.insert(window.id) } else { windows.remove(window.id) } }))
                            .padding(.leading, 16)
                    }
                }
                Toggle("All saved hosts", isOn: $allHosts)
                if !allHosts {
                    Text("Approved hosts must be reapproved after their destination, user, port, or identity file changes.").font(.caption).foregroundStyle(.secondary)
                    ForEach(hosts.hosts) { host in
                        Toggle(host.name, isOn: Binding(get: { approvedHosts.contains(host.id) }, set: { if $0 { approvedHosts.insert(host.id) } else { approvedHosts.remove(host.id) } }))
                            .padding(.leading, 16)
                    }
                }
            }
        }
        .frame(height: 260)
        Picker("Expires after", selection: $lifetime) {
            Text("1 hour").tag(TimeInterval(3_600))
            Text("1 day").tag(TimeInterval(86_400))
            Text("7 days").tag(TimeInterval(7 * 86_400))
            Text("30 days").tag(TimeInterval(30 * 86_400))
            Text("90 days").tag(TimeInterval(90 * 86_400))
        }
        if let message { Text(message).font(.caption) }
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Create Grant") { create() }.keyboardShortcut(.defaultAction).disabled(submitting)
        }
    }

    private func create() {
        let windowScope: WindowScope = allWindows ? .all : .windows(windows)
        let hostScope: HostScope =
            allHosts
            ? .all
            : .approved(Set(hosts.hosts.filter { approvedHosts.contains($0.id) }.map { HostApproval(hostID: $0.id, connectionRevision: $0.connectionRevision) }))
        submitting = true
        Task {
            defer { submitting = false }
            switch await grants.create(name: name, capabilities: capabilities, windowScope: windowScope, hostScope: hostScope, lifetime: lifetime) {
            case .success(let created): token = created
            case .failure(let error): message = GrantListModel.message(for: error)
            }
        }
    }
}
