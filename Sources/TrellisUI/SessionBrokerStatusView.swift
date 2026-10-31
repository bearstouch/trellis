import SwiftUI
import TrellisTerminal

/// Settings → Sessions: which session brokers hold this Trellis's sessions, and who may connect to them (FR-R07).
struct SessionBrokerStatusView: View {
    @ObservedObject var model: AppWorkspaceModel
    @State private var local: BrokerStatus?
    @State private var remote: [RemoteBrokerStatus] = []
    @State private var loading = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                switch local {
                case nil: Text("Checking…").foregroundStyle(model.themeColor(.mutedForeground))
                case .notRunning?: Text("Not running. It starts with the next new session.")
                case .busy?: Label("Running, but another Trellis is connected to it.", systemImage: "exclamationmark.triangle")
                case .incompatible?: Label("Running an older or newer version this Trellis can't use.", systemImage: "exclamationmark.triangle")
                case .connected(let details)?:
                    Text("Running · PID \(details.processID) · protocol \(details.protocolVersion)").monospacedDigit()
                    Text("\(count(details.running, "session")) running" + (details.ended > 0 ? ", \(details.ended) ended" : ""))
                    caption("Only this Trellis can connect: the broker checks every connection's user and executable (\(details.clientPath)).")
                    if let socket = details.socketPath {
                        Text(socket).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(model.themeColor(.mutedForeground))
                            .accessibilityLabel("Socket \(socket)")
                    }
                }
                if !remote.isEmpty {
                    Divider()
                    ForEach(remote) { host in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.hostName).fontWeight(.semibold)
                            Text(([host.platform, "PID \(host.processID)", "protocol \(host.protocolVersion)"].compactMap { $0 }).joined(separator: " · ")).monospacedDigit()
                            Text("\(count(host.running, "session")) running" + (host.ended > 0 ? ", \(host.ended) ended" : "")).foregroundStyle(model.themeColor(.mutedForeground))
                        }
                        .accessibilityElement(children: .combine)
                    }
                    caption("Each host keeps a separate broker for this Mac; only its Trellis helper, reached through your ssh connection, can connect.")
                }
                HStack {
                    Spacer()
                    Button("Refresh", action: refresh).disabled(loading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(4)
        } label: {
            Text("Session broker")
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("settings.sessionBroker")
        .task { refresh() }
    }

    private func refresh() {
        loading = true
        Task {
            let status = await model.sessionBrokerStatus()
            local = status.local; remote = status.remote; loading = false
        }
    }

    private func count(_ value: Int, _ noun: String) -> String { "\(value) \(noun)\(value == 1 ? "" : "s")" }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(model.themeColor(.mutedForeground)).fixedSize(horizontal: false, vertical: true)
    }
}
