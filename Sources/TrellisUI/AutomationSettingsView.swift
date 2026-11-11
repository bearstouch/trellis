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
        name: String, capabilities: Set<Capability>, spaceScope: SpaceScope, hostScope: HostScope, lifetime: TimeInterval
    ) async -> Result<String, GrantError> {
        defer { Task { await refresh() } }
        do {
            return .success(try await store.create(name: name, capabilities: capabilities, spaceScope: spaceScope, hostScope: hostScope, lifetime: lifetime).token)
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
        case .invalidName: L("Enter a name up to 100 characters.")
        case .noCapabilities: L("Choose at least one capability.")
        case .invalidExpiry: L("Choose an expiry between one minute and 90 days.")
        case .notFound: L("That grant no longer exists.")
        case .io: L("The grant could not be saved. Check disk space and permissions.")
        case .secretStore: L("The token could not be stored in the Keychain. Nothing was created.")
        case .readOnly: L("grants.json could not be read, so it was left untouched and no grant is active. Move it aside to manage grants.")
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
            Text(L("Scripts and agents connect through a local socket using a grant token. Each grant allows only the capabilities and spaces you choose."))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(L("Grants reduce accidental or unauthorized access, but any program running as your macOS user could still read your files or the Keychain item. Only grant access to software you trust."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                if grants.grants.isEmpty { Text(L("No grants yet.")).foregroundStyle(.secondary) }
                ForEach(grants.grants) { grant in row(grant) }
            }
            .frame(minHeight: 200).accessibilityLabel(L("Automation grants"))
            HStack {
                if let failure { Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                Spacer()
                Button(L("New Grant…")) { creating = true }
            }
        }
        .padding(16)
        .task { await grants.refresh() }
        .sheet(isPresented: $creating) { NewGrantView(grants: grants, workspace: workspace, hosts: hosts) }
        .confirmationDialog(L("Revoke “%@”?", revoking?.name ?? ""), isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            Button(L("Revoke Grant"), role: .destructive) {
                if let id = revoking?.id {
                    Task {
                        let error = await grants.revoke(id)
                        failure = error.map { L("Revoked for now, but not saved: %@ Revoke again before relaunching.", GrantListModel.message(for: $0)) }
                    }
                }
            }
        } message: {
            Text(L("Connected clients using this grant are disconnected immediately and the token stops working."))
        }
    }

    private func status(_ grant: AutomationGrant) -> String {
        if grant.revokedAt != nil { return L("Revoked") }
        if !grant.isActive(at: grants.now) { return L("Expired") }
        return L("Active until %@", grant.expiresAt.formatted(date: .abbreviated, time: .shortened))
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
                    Button(L("Revoke…")) { revoking = grant }.accessibilityLabel(L("Revoke %@", grant.name))
                }
            }
            Text(grant.capabilities.sorted().map(\.rawValue).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            Text(scopeText(grant)).font(.caption).foregroundStyle(.secondary)
            if !stale.isEmpty, grant.isActive(at: grants.now), case .approved(let approvals) = grant.hostScope {
                HStack {
                    Label(L("Changed since approval: %@", stale.map(\.name).joined(separator: ", ")), systemImage: "exclamationmark.triangle").font(.caption)
                    Button(L("Reapprove")) {
                        let current = hosts.hosts.filter { host in approvals.contains { $0.hostID == host.id } }
                        Task { failure = await grants.reapprove(grant.id, hosts: current).map(GrantListModel.message(for:)) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func scopeText(_ grant: AutomationGrant) -> String {
        let spaces: String
        switch grant.spaceScope {
        case .all: spaces = L("All spaces")
        case .spaces(let ids):
            let names = workspace.snapshot.spaces.filter { ids.contains($0.id) }.map(\.name)
            spaces = names.isEmpty ? L("No current spaces") : L("Spaces: %@", names.joined(separator: ", "))
        }
        let hostText: String
        switch grant.hostScope {
        case .all: hostText = L("all hosts")
        case .approved(let approvals): hostText = approvals.isEmpty ? L("no hosts") : L("%d approved host(s)", approvals.count)
        }
        return "\(spaces) · \(hostText)"
    }
}

private struct NewGrantView: View {
    @ObservedObject var grants: GrantListModel
    @ObservedObject var workspace: AppWorkspaceModel
    @ObservedObject var hosts: HostListModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var capabilities: Set<Capability> = [.metadataRead]
    @State private var allSpaces = true
    @State private var spaces = Set<UUID>()
    @State private var allHosts = false
    @State private var approvedHosts = Set<UUID>()
    @State private var lifetime: TimeInterval = 86_400
    @State private var token: String?
    @State private var message: String?
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let token {
                Text(L("Grant Created")).font(.headline)
                Text(L("Copy this token now. It is not shown again. The CLI can also read it from the Keychain item “%@”.", KeychainGrantSecretStore.service))
                    .fixedSize(horizontal: false, vertical: true)
                Text(token).font(.system(.body, design: .monospaced)).textSelection(.enabled).accessibilityLabel(L("Grant token"))
                HStack {
                    Button(L("Copy Token")) {
                        // Concealed: clipboard managers that honor the marker skip recording it.
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(token, forType: .string)
                        NSPasteboard.general.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                    }
                    Spacer()
                    Button(L("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                form
            }
        }
        .padding(20).frame(width: 520)
    }

    @ViewBuilder private var form: some View {
        Text(L("New Automation Grant")).font(.headline)
        TextField(L("Name"), text: $name, prompt: Text(L("Build agent"))).accessibilityLabel(L("Grant name"))
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Capability.allCases, id: \.self) { capability in
                    Toggle(isOn: Binding(get: { capabilities.contains(capability) }, set: { if $0 { capabilities.insert(capability) } else { capabilities.remove(capability) } })) {
                        VStack(alignment: .leading) {
                            Text(capability.rawValue).font(.system(.body, design: .monospaced))
                            Text(capability.localizedSummary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                Toggle(L("All spaces (needed to create spaces, apply layouts, or change themes)"), isOn: $allSpaces)
                if !allSpaces {
                    ForEach(workspace.snapshot.spaces) { space in
                        Toggle(space.name, isOn: Binding(get: { spaces.contains(space.id) }, set: { if $0 { spaces.insert(space.id) } else { spaces.remove(space.id) } }))
                            .padding(.leading, 16)
                    }
                }
                Toggle(L("All saved hosts"), isOn: $allHosts)
                if !allHosts {
                    Text(L("Approved hosts must be reapproved after their destination, user, port, or identity file changes.")).font(.caption).foregroundStyle(.secondary)
                    ForEach(hosts.hosts) { host in
                        Toggle(host.name, isOn: Binding(get: { approvedHosts.contains(host.id) }, set: { if $0 { approvedHosts.insert(host.id) } else { approvedHosts.remove(host.id) } }))
                            .padding(.leading, 16)
                    }
                }
            }
        }
        .frame(height: 260)
        Picker(L("Expires after"), selection: $lifetime) {
            Text(L("1 hour")).tag(TimeInterval(3_600))
            Text(L("1 day")).tag(TimeInterval(86_400))
            Text(L("7 days")).tag(TimeInterval(7 * 86_400))
            Text(L("30 days")).tag(TimeInterval(30 * 86_400))
            Text(L("90 days")).tag(TimeInterval(90 * 86_400))
        }
        if let message { Text(message).font(.caption) }
        HStack {
            Spacer()
            Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(L("Create Grant")) { create() }.keyboardShortcut(.defaultAction).disabled(submitting)
        }
    }

    private func create() {
        let spaceScope: SpaceScope = allSpaces ? .all : .spaces(spaces)
        let hostScope: HostScope =
            allHosts
            ? .all
            : .approved(Set(hosts.hosts.filter { approvedHosts.contains($0.id) }.map { HostApproval(hostID: $0.id, connectionRevision: $0.connectionRevision) }))
        submitting = true
        Task {
            defer { submitting = false }
            switch await grants.create(name: name, capabilities: capabilities, spaceScope: spaceScope, hostScope: hostScope, lifetime: lifetime) {
            case .success(let created): token = created
            case .failure(let error): message = GrantListModel.message(for: error)
            }
        }
    }
}

extension Capability {
    /// `summary` in the app's language; the API's copy stays English.
    var localizedSummary: String {
        switch self {
        case .metadataRead: L("List spaces, tabs, panes, and session states")
        case .layoutWrite: L("Create, rename, split, resize, and focus layout (new panes stay stopped)")
        case .sessionStart: L("Start stopped sessions with the default shell or an approved host")
        case .sessionInput: L("Type into terminals, including control keys (can run commands)")
        case .sessionExecute: L("Run arbitrary programs and shell commands")
        case .sessionOutputRead: L("Read terminal screens, scrollback, and output")
        case .sessionClose: L("Terminate running sessions")
        case .themeRead: L("Read themes and appearance (global)")
        case .themeWrite: L("Change themes and appearance for every space (global)")
        case .hostRead: L("Read saved hosts, aliases, and identity-file paths")
        case .hostWrite: L("Create, edit, and delete saved hosts")
        }
    }
}
