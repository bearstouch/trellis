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

    public enum EditOutcome: Equatable, Sendable {
        case saved
        /// The edit widens the grant: nothing changed; ask the user, then edit again with `confirmed`.
        case needsConfirmation
        /// `applied`: a narrowing edit took effect but couldn't be saved, so it is lost on relaunch.
        case failed(GrantError, applied: Bool)
    }

    public func refresh() async {
        grants = await store.grants.sorted { $0.createdAt > $1.createdAt }
        now = await store.currentDate()
    }

    public func create(_ settings: GrantSettings, lifetime: TimeInterval) async -> Result<String, GrantError> {
        defer { Task { await refresh() } }
        do { return .success(try await store.create(settings, lifetime: lifetime).token) } catch { return .failure(error) }
    }

    /// Saves an edit. Narrowing applies at once; widening returns `needsConfirmation` unless `confirmed`, which the sheet
    /// passes only after the user agreed, so Cancel leaves the grant exactly as it was.
    public func edit(_ grant: AutomationGrant, to settings: GrantSettings, lifetime: TimeInterval?, confirmed: Bool) async -> EditOutcome {
        defer { Task { await refresh() } }
        do {
            try await store.update(grant.id, to: settings, lifetime: lifetime, expectedRevision: grant.revision, confirmedWidening: confirmed)
            return .saved
        } catch .confirmationRequired {
            return .needsConfirmation
        } catch .io {
            // A narrowing applies before it is saved; report it so the user knows it won't survive a relaunch.
            let current = await store.grants.first { $0.id == grant.id }
            return .failed(.io, applied: (current?.revision ?? 0) > grant.revision)
        } catch {
            return .failed(error, applied: false)
        }
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
        case .confirmationRequired: L("This change gives the grant more access and needs your confirmation.")
        case .conflict: L("The grant changed while you were editing it. Close the sheet and edit it again.")
        }
    }
}

struct AutomationSettingsView: View {
    @ObservedObject var grants: GrantListModel
    @ObservedObject var workspace: AppWorkspaceModel
    @ObservedObject var hosts: HostListModel
    @State private var creating = false
    @State private var editing: AutomationGrant?
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
        .sheet(isPresented: $creating) { GrantSheet(grants: grants, workspace: workspace, hosts: hosts, editing: nil) }
        .sheet(item: $editing) { grant in GrantSheet(grants: grants, workspace: workspace, hosts: hosts, editing: grant) }
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
        let active = grant.isActive(at: grants.now)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(grant.name).fontWeight(.semibold)
                Spacer()
                Text(status(grant)).font(.caption)
                if active {
                    Button(L("Edit…")) { editing = grant }.accessibilityLabel(L("Edit %@", grant.name))
                    Button(L("Revoke…")) { revoking = grant }.accessibilityLabel(L("Revoke %@", grant.name))
                }
            }
            Text(presetText(grant)).font(.caption).foregroundStyle(.secondary)
            Text(scopeText(grant)).font(.caption).foregroundStyle(.secondary)
            if !stale.isEmpty, active, case .approved(let approvals) = grant.hostScope {
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

    private func presetText(_ grant: AutomationGrant) -> String {
        grant.preset == .custom ? L("Custom · %d capabilities", grant.capabilitiesV2.count) : grant.preset.localizedName
    }

    private func scopeText(_ grant: AutomationGrant) -> String {
        let spaces: String
        switch grant.spaceScope {
        case .all: spaces = L("All spaces")
        case .created: spaces = L("Spaces it creates (%d)", grant.createdSpaces.count)
        case .spaces(let ids):
            let names = workspace.snapshot.spaces.filter { ids.contains($0.id) }.map(\.name)
            spaces = names.isEmpty ? L("No current spaces") : L("Spaces: %@", names.joined(separator: ", "))
        }
        let projects: String
        switch grant.projectScope {
        case .all: projects = L("all projects")
        case .projects(let ids): projects = L("%d chosen project(s)", ids.count)
        }
        let hostText: String
        switch grant.hostScope {
        case .all: hostText = L("all hosts")
        case .approved(let approvals): hostText = approvals.isEmpty ? L("no hosts") : L("%d approved host(s)", approvals.count)
        }
        let agents: String
        switch grant.agentScope {
        case .all: agents = L("all agents")
        case .agents(let ids): agents = L("%d chosen agent(s)", ids.count)
        }
        return [spaces, projects, hostText, agents].joined(separator: " · ")
    }
}

/// New and Edit share this form: name, role, spaces and expiry; capabilities and the other scopes wait under Advanced.
private struct GrantSheet: View {
    @ObservedObject var grants: GrantListModel
    @ObservedObject var workspace: AppWorkspaceModel
    @ObservedObject var hosts: HostListModel
    let editing: AutomationGrant?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = GrantDraft()
    @State private var token: String?
    @State private var message: String?
    @State private var submitting = false
    @State private var confirmingWidening = false
    @State private var showsAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let token {
                created(token)
            } else {
                Text(editing == nil ? L("New Automation Grant") : L("Edit “%@”", editing?.name ?? "")).font(.headline).accessibilityAddTraits(.isHeader)
                ScrollView { form.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 12) }
                if let message { Text(message).font(.caption).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Spacer()
                    Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(editing == nil ? L("Create Grant") : L("Save")) { submit(confirmed: false) }.keyboardShortcut(.defaultAction).disabled(submitting)
                }
            }
        }
        // Width before padding: the form's ideal width is wider than the sheet, and padding outside a fixed frame
        // would let it run to the sheet's edges.
        .frame(width: 540, height: token == nil ? 600 : nil).padding(20)
        .onAppear { if let editing { draft = GrantDraft(grant: editing); showsAdvanced = draft.needsAdvanced } }
        .alert(L("Give “%@” more access?", draft.name), isPresented: $confirmingWidening) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Allow More Access"), role: .destructive) { submit(confirmed: true) }
        } message: {
            Text(L("Clients using this grant can do more as soon as you save: new capabilities, a wider scope or a later expiry. Only allow this for software you trust."))
        }
    }

    private func created(_ token: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField(L("Name"), text: $draft.name, prompt: Text(L("Build agent"))).accessibilityLabel(L("Grant name"))
            }
            Section {
                ForEach(GrantPreset.allCases.filter { $0 != .custom }, id: \.self) { preset in presetRow(preset) }
                if draft.preset == .custom { customRow }
            } header: {
                sectionHeader(L("Role"))
            }
            Section {
                spaceScope
            } header: {
                sectionHeader(L("Spaces"))
            }
            Section {
                Picker(L("Expires after"), selection: $draft.lifetime) {
                    if let editing {
                        Text(L("Keep current expiry (%@)", editing.expiresAt.formatted(date: .abbreviated, time: .shortened))).tag(TimeInterval?.none)
                    }
                    Text(L("1 hour")).tag(TimeInterval?.some(3_600))
                    Text(L("1 day")).tag(TimeInterval?.some(86_400))
                    Text(L("7 days")).tag(TimeInterval?.some(7 * 86_400))
                    Text(L("30 days")).tag(TimeInterval?.some(30 * 86_400))
                    Text(L("90 days")).tag(TimeInterval?.some(90 * 86_400))
                }
                // The Expiry heading names it; a label column here would sit at the sheet's edge.
                .labelsHidden().frame(width: 220, alignment: .leading)
                if editing != nil { caption(L("A new expiry counts from now.")) }
            } header: {
                sectionHeader(L("Expiry"))
            }
            Section {
                DisclosureGroup(L("Show capabilities and other scopes"), isExpanded: $showsAdvanced) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Capabilities")).font(.headline).padding(.top, 8).accessibilityAddTraits(.isHeader)
                        caption(L("Changing any capability makes the grant Custom."))
                        ForEach(CapabilityV2.Area.allCases, id: \.self) { area in
                            Text(area.localizedName).font(.subheadline.weight(.semibold)).padding(.top, 6).accessibilityAddTraits(.isHeader)
                            ForEach(CapabilityV2.allCases.filter { $0.area == area }, id: \.self) { capability in capabilityToggle(capability) }
                        }
                        Text(L("Scope")).font(.headline).padding(.top, 14).accessibilityAddTraits(.isHeader)
                        otherScopes
                    }
                }
            } header: {
                sectionHeader(L("Advanced"))
            }
        }
    }

    /// Custom isn't picked: it appears once a capability in Advanced no longer matches a role.
    private var customRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(GrantPreset.custom.localizedName).fontWeight(.semibold)
                caption(L("The capabilities were changed in Advanced and no longer match a role."))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isSelected)
    }

    /// A plain macOS Form puts no space above a section title, so each group gets its own.
    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.headline).padding(.top, 14).padding(.bottom, 2).accessibilityAddTraits(.isHeader)
    }

    private func presetRow(_ preset: GrantPreset) -> some View {
        let selected = draft.preset == preset
        return Button {
            draft.choose(preset)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : .secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.localizedName).fontWeight(selected ? .semibold : .regular)
                    Text(preset.localizedSummary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preset.localizedName)
        .accessibilityValue(selected ? L("Selected") : "")
        .accessibilityHint(preset.localizedSummary)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func capabilityToggle(_ capability: CapabilityV2) -> some View {
        Toggle(isOn: Binding(get: { draft.capabilities.contains(capability) }, set: { draft.set(capability, $0) })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(capability.localizedSummary).fixedSize(horizontal: false, vertical: true)
                Text(capability.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(capability.localizedSummary)
        .accessibilityHint(L("Capability %@", capability.rawValue))
    }

    @ViewBuilder private var spaceScope: some View {
        Picker(L("Spaces"), selection: $draft.spaceChoice) {
            Text(L("All spaces")).tag(GrantDraft.SpaceChoice.all)
            Text(L("Only spaces this grant creates")).tag(GrantDraft.SpaceChoice.created)
            Text(L("Chosen spaces")).tag(GrantDraft.SpaceChoice.chosen)
        }
        .pickerStyle(.radioGroup)
        switch draft.spaceChoice {
        case .all: caption(L("Needed to reorder spaces, apply layouts or change themes."))
        case .created:
            caption(L("The grant can create spaces and sees only those. Spaces you create in Trellis never join it."))
        case .chosen:
            ForEach(workspace.snapshot.spaces) { space in choice(space.name, $draft.spaces, space.id) }
        }
    }

    @ViewBuilder private var otherScopes: some View {
        Picker(L("Projects"), selection: $draft.allProjects) {
            Text(L("All projects")).tag(true)
            Text(L("Chosen projects")).tag(false)
        }
        .pickerStyle(.radioGroup)
        if !draft.allProjects {
            let projects = workspace.commandPaletteProjects()
            if projects.isEmpty { caption(L("No projects in the library.")) }
            ForEach(projects) { project in choice(project.name, $draft.projects, project.id) }
        }
        Divider()
        Picker(L("Hosts"), selection: $draft.allHosts) {
            Text(L("All saved hosts")).tag(true)
            Text(L("Approved hosts")).tag(false)
        }
        .pickerStyle(.radioGroup)
        if !draft.allHosts {
            caption(L("Approved hosts must be reapproved after their destination, user, port, or identity file changes."))
            ForEach(hosts.hosts) { host in choice(host.name, $draft.hosts, host.id) }
        }
        Divider()
        Picker(L("Agents"), selection: $draft.allAgents) {
            Text(L("All agents")).tag(true)
            Text(L("Chosen agents")).tag(false)
        }
        .pickerStyle(.radioGroup)
        if !draft.allAgents {
            caption(L("Limits which agents the grant can start or install; it can still read every agent's runs."))
            ForEach(workspace.agentCatalog.definitions) { agent in choice(agent.name, $draft.agents, agent.id) }
        }
    }

    /// A caption that wraps: without it a Form lays the text out on one line and widens itself past the sheet.
    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func choice<ID: Hashable>(_ title: String, _ set: Binding<Set<ID>>, _ id: ID) -> some View {
        Toggle(title, isOn: Binding(get: { set.wrappedValue.contains(id) }, set: { if $0 { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } }))
            .padding(.leading, 16)
    }

    private func submit(confirmed: Bool) {
        let settings = draft.settings(savedHosts: hosts.hosts, existing: editing?.hostScope)
        let lifetime = draft.lifetime
        submitting = true
        Task {
            defer { submitting = false }
            if let editing {
                switch await grants.edit(editing, to: settings, lifetime: lifetime, confirmed: confirmed) {
                case .saved: dismiss()
                case .needsConfirmation: confirmingWidening = true
                case .failed(let error, let applied):
                    message =
                        applied
                        ? L("Applied for now, but not saved: %@ Edit the grant again before relaunching.", GrantListModel.message(for: error)) : GrantListModel.message(for: error)
                }
            } else {
                switch await grants.create(settings, lifetime: lifetime ?? GrantDraft.defaultLifetime) {
                case .success(let created): token = created
                case .failure(let error): message = GrantListModel.message(for: error)
                }
            }
        }
    }
}

extension GrantPreset {
    var localizedName: String {
        switch self {
        case .observer: L("Observer")
        case .operator: L("Operator")
        case .agentOrchestrator: L("Agent orchestrator")
        case .fullControl: L("Full control")
        case .custom: L("Custom")
        }
    }

    var localizedSummary: String {
        switch self {
        case .observer: L("Read the workspace, terminal output, hosts, projects and tasks. Can't change anything.")
        case .operator: L("Observer, plus arrange the workspace, start and stop sessions, type into terminals and run tasks. Hosts must be approved.")
        case .agentOrchestrator:
            L("Operator, plus start and answer agents, launch projects and open remote workspaces, only in the spaces it creates. Hosts must be approved.")
        case .fullControl: L("Every capability, for every space, project, host and agent.")
        case .custom: L("Choose the capabilities and scopes yourself.")
        }
    }
}

extension CapabilityV2.Area {
    var localizedName: String {
        switch self {
        case .workspace: L("Workspace")
        case .sessions: L("Sessions")
        case .agents: L("Agents")
        case .hosts: L("Hosts and remote workspaces")
        case .projects: L("Projects and tasks")
        case .appearance: L("Appearance")
        }
    }
}

extension CapabilityV2 {
    /// Plain-language descriptions in the app's language; the raw name is shown beside them.
    var localizedSummary: String {
        switch self {
        case .workspaceRead: L("See spaces, tabs, panes, sessions and agent states")
        case .workspaceWrite: L("Create, rename, arrange and close spaces, tabs and panes (new panes stay stopped)")
        case .sessionStart: L("Start panes with their saved command, the default shell or an approved host")
        case .sessionExecute: L("Choose what runs: any program, folder, environment or command")
        case .sessionInput: L("Type into terminals, including control keys (the same as running commands)")
        case .sessionOutputRead: L("Read terminal screens, scrollback and output")
        case .sessionClose: L("Stop running sessions")
        case .agentControl: L("Start, restart and resume coding agents")
        case .agentRespond: L("Approve, reject or answer an agent that is waiting")
        case .agentInstall: L("Install coding agents on a machine")
        case .hostRead: L("See saved hosts, their addresses and identity-file paths")
        case .hostWrite: L("Add, edit and delete saved hosts")
        case .remoteConnect: L("Open and reconnect remote workspaces")
        case .remoteManage: L("Install, update and remove the remote helper on hosts")
        case .projectRead: L("See projects and their launch plans")
        case .projectWrite: L("Create, edit, capture and delete projects")
        case .projectLaunch: L("Open projects into spaces")
        case .taskRead: L("See tasks and their runs")
        case .taskRun: L("Run and stop trusted tasks")
        case .themeRead: L("Read themes and appearance (every space)")
        case .themeWrite: L("Change themes and appearance for every space")
        }
    }
}
