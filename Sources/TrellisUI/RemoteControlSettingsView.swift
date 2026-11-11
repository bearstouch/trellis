import AppKit
import SwiftUI
import TrellisCore

/// Settings → Remote Control: the MCP server's switch, interface and port
/// (FR-RC01–FR-RC04), and sharing over Tailscale (FR-RC05–FR-RC09). Edits are a
/// draft until Apply; a non-loopback address or wider tailnet access needs an
/// explicit confirmation first.
struct RemoteControlSettingsView: View {
    @ObservedObject var model: AppWorkspaceModel
    var showAutomation: (() -> Void)?
    @State private var draft = RemoteControlSettings()
    @State private var port = Int(RemoteControlSettings.defaultPort)
    @State private var interfaces: [NetworkInterfaceAddress] = []
    @State private var confirmingNetwork = false
    @State private var confirmingTailnet = false
    @State private var message: String?
    /// nil while loading.
    @State private var tailscale: Result<TailscaleStatus, TailscaleError>?
    @State private var restrictDevices = false

    private var candidate: RemoteControlSettings {
        var settings = draft
        settings.port = UInt16(clamping: port)
        if !restrictDevices { settings.allowedDevices = [] }
        return settings
    }
    /// A failed start (for example, port in use) can be retried with the same settings once the cause is fixed.
    private var retryable: Bool {
        if case .failed = model.remoteControlStatus { return true }
        if case .failed = model.tailscaleShareState { return true }
        return false
    }
    private var portValid: Bool { RemoteControlSettings.portRange.contains(UInt16(clamping: port)) && port <= 65_535 }
    private var devicesValid: Bool { !restrictDevices || !draft.allowedDevices.isEmpty }

    var body: some View {
        Form {
            Section {
                Toggle(L("Enable MCP server"), isOn: $draft.mcpEnabled)
                Text(
                    L("Lets agents such as Claude Code control Trellis through the Model Context Protocol. Each agent signs in with an automation grant token, and the grant limits what it can do.")
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker(L("Interface"), selection: $draft.bindAddress) {
                    ForEach(addressOptions, id: \.address) { Text($0.label).tag($0.address) }
                }
                .accessibilityHint(L("The network address the MCP server accepts connections on."))
                TextField(L("Port (1024–65535)"), value: $port, format: .number.grouping(.never))
                    .accessibilityLabel(L("Port"))
                if !portValid { Label(L("Use a port from 1024 to 65535."), systemImage: "exclamationmark.circle").font(.caption) }
                if draft.isLoopback {
                    Text(L("Only programs on this Mac can connect.")).font(.caption).foregroundStyle(.secondary)
                } else if IPAddressLiteral(draft.bindAddress)?.isTailnet == true {
                    Label(
                        L("Devices in your tailnet can reach this server. Tailscale encrypts the traffic, but the server uses plain HTTP. Share over Tailscale below for HTTPS and an allowed-devices list."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                } else {
                    Label(
                        L("Other devices on the network can reach this server. Requests use plain HTTP, so grant tokens are sent unencrypted."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                }
            } header: {
                sectionHeader(L("Listen on"))
            }
            tailscaleSection
            Section {
                statusRow
                if let text = shareStatusText { shareStatusRow(text) }
                HStack {
                    Button(L("Copy Endpoint URL")) { copy(model.remoteControlClientURL) }
                        .disabled(!model.remoteControl.mcpEnabled)
                    Menu(L("Copy Client Setup")) {
                        Button(L("Claude Code command")) { copy(MCPClientSetup.claudeCode.snippet(url: model.remoteControlClientURL)) }
                        Button(L("Codex (config.toml)")) { copy(MCPClientSetup.codex.snippet(url: model.remoteControlClientURL)) }
                        Button(L("Generic MCP JSON")) { copy(MCPClientSetup.json.snippet(url: model.remoteControlClientURL)) }
                    }
                    .fixedSize()
                    .disabled(!model.remoteControl.mcpEnabled)
                    .help(L("Replace <TOKEN> with a grant token, or set TRELLIS_TOKEN for Codex. Tokens are shown only once, when the grant is created."))
                }
                HStack(spacing: 4) {
                    Text(L("Agents need a grant token.")).font(.caption).foregroundStyle(.secondary)
                    if let showAutomation { Button(L("Create a grant in Automation…"), action: showAutomation).buttonStyle(.link).font(.caption) }
                }
            } header: {
                sectionHeader(L("Status"))
            }
            if let message { Text(message).font(.caption).padding(.top, 8) }
            HStack {
                Spacer()
                Button(L("Apply")) {
                    let settings = candidate
                    let alreadyExposed = model.remoteControl.mcpEnabled && model.remoteControl.bindAddress == settings.bindAddress
                    if settings.mcpEnabled, !settings.isLoopback, !alreadyExposed {
                        confirmingNetwork = true
                    } else if settings.widensTailnetAccess(from: model.remoteControl) {
                        confirmingTailnet = true
                    } else {
                        commit(settings)
                    }
                }
                .disabled(!portValid || !devicesValid || !candidate.isValid || (candidate == model.remoteControl && !retryable))
            }
            .padding(.top, 12)
        }
        .padding(16)
        .alert(L("Allow connections from the network?"), isPresented: $confirmingNetwork) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Allow Network Access"), role: .destructive) { commit(candidate) }
        } message: {
            Text(
                L("Devices that can reach %@ will be able to connect. Anyone who obtains a grant token can then control terminals within that grant. Traffic is not encrypted.", draft.bindAddress)
            )
        }
        .alert(L("Share with your tailnet?"), isPresented: $confirmingTailnet) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Share"), role: .destructive) { commit(candidate) }
        } message: {
            Text(tailnetConfirmation)
        }
        .onAppear {
            interfaces = model.networkInterfaces()
            reset(to: model.remoteControl)
            refreshTailscale()
        }
        .onChange(of: model.remoteControl) { _, value in reset(to: value) }
    }

    // MARK: - Tailscale

    private var connectedStatus: TailscaleStatus? {
        guard case .success(let status)? = tailscale, status.backend == .connected else { return nil }
        return status
    }

    /// Turning sharing on needs the server on, a loopback bind and a connected tailnet with HTTPS; turning it off never waits.
    private var canShare: Bool { draft.tailscaleShare || (draft.mcpEnabled && draft.isLoopback && connectedStatus?.httpsEnabled == true) }

    @ViewBuilder private var tailscaleSection: some View {
        Section {
            HStack {
                tailscaleStatusRow
                Spacer()
                Button(L("Refresh")) { refreshTailscale() }
                    .accessibilityHint(L("Reads Tailscale's status and devices again."))
            }
            if connectedStatus != nil || draft.tailscaleShare {
                Toggle(L("Share over Tailscale"), isOn: $draft.tailscaleShare)
                    .disabled(!canShare)
                    .accessibilityHint(L("Publishes the MCP server to devices in your tailnet over HTTPS with tailscale serve."))
                if !draft.isLoopback {
                    Text(L("Sharing needs a loopback interface. Tailscale forwards requests to it.")).font(.caption).foregroundStyle(.secondary)
                } else if !draft.mcpEnabled {
                    Text(L("Turn on the MCP server to share it.")).font(.caption).foregroundStyle(.secondary)
                }
                if draft.tailscaleShare {
                    Picker(L("HTTPS port"), selection: $draft.tailscalePort) {
                        ForEach(RemoteControlSettings.tailscalePorts, id: \.self) { Text(verbatim: "\($0)").tag($0) }
                    }
                    Text(L("Devices in your tailnet can reach this. Tailscale encrypts the traffic. It is never shared publicly (no Funnel)."))
                        .font(.caption).foregroundStyle(.secondary)
                    Picker(L("Allowed devices"), selection: $restrictDevices) {
                        Text(L("Any device in my tailnet")).tag(false)
                        Text(L("Only these devices")).tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .padding(.top, 6)
                    if restrictDevices { deviceList }
                }
            }
        } header: {
            sectionHeader(L("Tailscale"))
        }
    }

    /// A plain macOS Form puts no space above a section title, so each group gets its own.
    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.headline).padding(.top, 14).padding(.bottom, 2).accessibilityAddTraits(.isHeader)
    }

    private var tailscaleStatusRow: some View {
        let (symbol, text): (String, String) =
            switch tailscale {
            case nil: ("ellipsis.circle", L("Checking Tailscale…"))
            case .failure(let error)?: ("exclamationmark.triangle.fill", Self.message(.tailscale(error)))
            case .success(let status)?:
                switch status.backend {
                case .notInstalled: ("circle", L("Tailscale isn't installed."))
                case .stopped: ("circle", L("Tailscale is stopped. Open Tailscale and connect."))
                case .needsLogin: ("exclamationmark.triangle.fill", L("Tailscale needs you to sign in."))
                case .connected:
                    status.httpsEnabled
                        ? ("checkmark.circle.fill", L("Connected as %1$@ (%2$@)", status.dnsName ?? "", status.addresses.first ?? ""))
                        : ("exclamationmark.triangle.fill", Self.message(.httpsDisabled))
                }
            }
        return HStack(spacing: 6) {
            Label(text, systemImage: symbol)
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L("Tailscale status: %@", text))
            if case .success(let status)? = tailscale {
                if status.backend == .notInstalled {
                    Link(L("Get Tailscale…"), destination: URL(string: "https://tailscale.com/download/mac")!).font(.caption)
                } else if status.backend == .connected, !status.httpsEnabled {
                    Link(L("Open DNS settings…"), destination: URL(string: "https://login.tailscale.com/admin/dns")!).font(.caption)
                }
            }
        }
    }

    /// The tailnet's devices, plus chosen ones Tailscale doesn't list right now.
    private var deviceOptions: [(device: TailnetDevice, os: String, online: Bool?)] {
        let peers = connectedStatus?.peers ?? []
        var rows = peers.map { (device: $0.device, os: $0.os, online: Optional($0.online)) }
        for saved in draft.allowedDevices where !peers.contains(where: { $0.id == saved.id }) { rows.append((saved, "", nil)) }
        return rows
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 4) {
            if deviceOptions.isEmpty { Text(L("No other devices in your tailnet.")).font(.caption).foregroundStyle(.secondary) }
            ForEach(deviceOptions, id: \.device.id) { row in
                let presence = row.online.map { $0 ? L("Online") : L("Offline") } ?? L("Not listed")
                Toggle(isOn: chosen(row.device)) {
                    HStack {
                        Text(row.device.name).frame(minWidth: 120, alignment: .leading)
                        Text(row.os).foregroundStyle(.secondary).frame(minWidth: 60, alignment: .leading)
                        Text(presence).foregroundStyle(row.online == true ? .primary : .secondary).frame(minWidth: 60, alignment: .leading)
                        Text(row.device.addresses.first ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(L("%1$@, %2$@, %3$@", row.device.name, presence, row.device.addresses.first ?? ""))
            }
            if draft.allowedDevices.isEmpty { Label(L("Choose at least one device."), systemImage: "exclamationmark.circle").font(.caption) }
        }
    }

    private func chosen(_ device: TailnetDevice) -> Binding<Bool> {
        Binding(
            get: { draft.allowedDevices.contains { $0.id == device.id } },
            set: { on in
                draft.allowedDevices.removeAll { $0.id == device.id }
                if on { draft.allowedDevices.append(device) }
            })
    }

    private var tailnetConfirmation: String {
        let names = candidate.allowedDevices.map(\.name)
        let who = names.isEmpty ? L("Every device in your tailnet will be able to connect.") : L("These devices will be able to connect: %@.", names.joined(separator: ", "))
        return who + " " + L("Anyone with a grant token on them can control terminals within that grant. Tailscale encrypts the traffic and it never leaves your tailnet.")
    }

    private var shareStatusText: (symbol: String, text: String)? {
        switch model.tailscaleShareState {
        case .off: nil
        case .starting: ("ellipsis.circle", L("Sharing over Tailscale…"))
        case .shared(let url): ("checkmark.circle.fill", L("Shared at %@", url))
        case .waiting: ("hourglass", L("Waiting for Tailscale…"))
        case .failed(let error): ("exclamationmark.triangle.fill", L("Not shared: %@", Self.message(error)))
        }
    }

    private func shareStatusRow(_ status: (symbol: String, text: String)) -> some View {
        HStack(spacing: 6) {
            Label(status.text, systemImage: status.symbol)
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L("Tailscale sharing: %@", status.text))
            if case .failed(.consentRequired(let url)) = model.tailscaleShareState {
                Link(L("Open Tailscale…"), destination: url).font(.caption)
            }
        }
    }

    static func message(_ error: TailscaleShareError) -> String {
        switch error {
        case .tailscale(.notInstalled), .notConnected(.notInstalled): L("Tailscale isn't installed.")
        case .tailscale(.notRunning), .notConnected(.stopped): L("Tailscale is stopped. Open Tailscale and connect.")
        case .notConnected(.needsLogin): L("Tailscale needs you to sign in.")
        case .notConnected(.connected): L("Tailscale isn't connected.")
        case .tailscale(.timedOut): L("Tailscale didn't answer in time.")
        case .tailscale(.malformed): L("Tailscale's answer couldn't be read.")
        case .tailscale(.failed(let detail)): L("Tailscale failed: %@", detail)
        case .httpsDisabled: L("HTTPS certificates are off for this tailnet. Turn on MagicDNS and HTTPS in the Tailscale admin console.")
        case .portInUse(let port): L("Port %d is already served by another app. Choose another port.", Int(port))
        case .funnelOn(let port): L("Funnel is on for port %d, so Trellis stopped sharing it. Trellis is never shared publicly.", Int(port))
        case .consentRequired: L("Tailscale needs HTTPS or Serve turned on for this tailnet first.")
        }
    }

    private func refreshTailscale() {
        tailscale = nil
        Task { tailscale = await model.tailscaleStatus() }
    }

    // MARK: - Server

    private var statusRow: some View {
        let (symbol, text): (String, String) =
            switch model.remoteControlStatus {
            case .stopped: ("stop.circle", L("Stopped"))
            case .running(let url): ("checkmark.circle.fill", L("Running at %@", url))
            case .failed(let reason): ("exclamationmark.triangle.fill", L("Not running: %@", reason))
            }
        return Label(text, systemImage: symbol)
            .textSelection(.enabled)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L("Server status: %@", text))
    }

    private var addressOptions: [(address: String, label: String)] {
        var options: [(address: String, label: String)] = [
            ("127.0.0.1", L("Loopback — 127.0.0.1 (this Mac only)")), ("::1", L("Loopback IPv6 — ::1 (this Mac only)"))
        ]
        options += interfaces.map {
            let tailnet = IPAddressLiteral($0.address)?.isTailnet == true
            return ($0.address, tailnet ? L("Tailscale — %1$@ (%2$@)", $0.address, $0.interface) : "\($0.interface) — \($0.address)")
        }
        options += [("0.0.0.0", L("All IPv4 interfaces — 0.0.0.0")), ("::", L("All IPv6 interfaces — ::"))]
        if !options.contains(where: { $0.address == draft.bindAddress }) { options.append((draft.bindAddress, L("%@ (unavailable)", draft.bindAddress))) }
        return options
    }

    private func reset(to settings: RemoteControlSettings) {
        draft = settings
        port = Int(settings.port)
        restrictDevices = !settings.allowedDevices.isEmpty
    }

    private func commit(_ settings: RemoteControlSettings) {
        message = model.applyRemoteControl(settings) ? L("Remote control settings saved.") : L("Choose a valid interface and a port from 1024 to 65535.")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
