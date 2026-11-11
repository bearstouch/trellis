import AppKit
import SwiftUI
import TrellisCore

/// Settings → Remote Control: the MCP server's switch, interface and port
/// (FR-RC01–FR-RC04). Edits are a draft until Apply; a non-loopback address
/// needs an explicit confirmation first.
struct RemoteControlSettingsView: View {
    @ObservedObject var model: AppWorkspaceModel
    var showAutomation: (() -> Void)?
    @State private var draft = RemoteControlSettings()
    @State private var port = Int(RemoteControlSettings.defaultPort)
    @State private var interfaces: [NetworkInterfaceAddress] = []
    @State private var confirmingNetwork = false
    @State private var message: String?

    private var candidate: RemoteControlSettings {
        var settings = draft
        settings.port = UInt16(clamping: port)
        return settings
    }
    /// A failed start (for example, port in use) can be retried with the same settings once the cause is fixed.
    private var retryable: Bool {
        if case .failed = model.remoteControlStatus { return true }
        return false
    }
    private var portValid: Bool { RemoteControlSettings.portRange.contains(UInt16(clamping: port)) && port <= 65_535 }

    var body: some View {
        Form {
            Section {
                Toggle(L("Enable MCP server"), isOn: $draft.mcpEnabled)
                Text(
                    L("Lets agents such as Claude Code control Trellis through the Model Context Protocol. Each agent signs in with an automation grant token, and the grant limits what it can do.")
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Listen on")) {
                Picker(L("Interface"), selection: $draft.bindAddress) {
                    ForEach(addressOptions, id: \.address) { Text($0.label).tag($0.address) }
                }
                .accessibilityHint(L("The network address the MCP server accepts connections on."))
                TextField(L("Port (1024–65535)"), value: $port, format: .number.grouping(.never))
                    .accessibilityLabel(L("Port"))
                if !portValid { Label(L("Use a port from 1024 to 65535."), systemImage: "exclamationmark.circle").font(.caption) }
                if draft.isLoopback {
                    Text(L("Only programs on this Mac can connect.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Label(
                        L("Other devices on the network can reach this server. Requests use plain HTTP, so grant tokens are sent unencrypted."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                }
            }
            Section(L("Status")) {
                statusRow
                HStack {
                    Button(L("Copy Endpoint URL")) { copy(clientURL(model.remoteControl)) }
                        .disabled(!model.remoteControl.mcpEnabled)
                    Button(L("Copy Claude Code Command")) {
                        copy("claude mcp add --transport http trellis \(clientURL(model.remoteControl)) --header \"Authorization: Bearer <TOKEN>\"")
                    }
                    .disabled(!model.remoteControl.mcpEnabled)
                    .help(L("Replace <TOKEN> with a grant token. Tokens are shown only once, when the grant is created."))
                }
                HStack(spacing: 4) {
                    Text(L("Agents need a grant token.")).font(.caption).foregroundStyle(.secondary)
                    if let showAutomation { Button(L("Create a grant in Automation…"), action: showAutomation).buttonStyle(.link).font(.caption) }
                }
            }
            if let message { Text(message).font(.caption) }
            HStack {
                Spacer()
                Button(L("Apply")) {
                    let settings = candidate
                    let alreadyExposed = model.remoteControl.mcpEnabled && model.remoteControl.bindAddress == settings.bindAddress
                    if settings.mcpEnabled, !settings.isLoopback, !alreadyExposed { confirmingNetwork = true } else { commit(settings) }
                }
                .disabled(!portValid || !candidate.isValid || (candidate == model.remoteControl && !retryable))
            }
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
        .onAppear {
            interfaces = model.networkInterfaces()
            reset(to: model.remoteControl)
        }
        .onChange(of: model.remoteControl) { _, value in reset(to: value) }
    }

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
        options += interfaces.map { ($0.address, "\($0.interface) — \($0.address)") }
        options += [("0.0.0.0", L("All IPv4 interfaces — 0.0.0.0")), ("::", L("All IPv6 interfaces — ::"))]
        if !options.contains(where: { $0.address == draft.bindAddress }) { options.append((draft.bindAddress, L("%@ (unavailable)", draft.bindAddress))) }
        return options
    }

    /// A wildcard bind is reached through loopback from this Mac.
    private func clientURL(_ settings: RemoteControlSettings) -> String {
        let address =
            switch settings.bindAddress {
            case "0.0.0.0": "127.0.0.1"
            case "::": "::1"
            default: settings.bindAddress
            }
        return RemoteControlSettings.endpointURL(address: address, port: settings.port)
    }

    private func reset(to settings: RemoteControlSettings) {
        draft = settings
        port = Int(settings.port)
    }

    private func commit(_ settings: RemoteControlSettings) {
        message = model.applyRemoteControl(settings) ? L("Remote control settings saved.") : L("Choose a valid interface and a port from 1024 to 65535.")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
