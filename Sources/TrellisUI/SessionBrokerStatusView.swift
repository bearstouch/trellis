import SwiftUI
import TrellisCore
import TrellisTerminal

/// Settings → Session Broker: which session brokers hold this Trellis's sessions, and who may connect to them (FR-R07),
/// and how long an idle kept session lasts (FR-R08).
struct SessionBrokerStatusView: View {
    @ObservedObject var model: AppWorkspaceModel
    @State private var local: BrokerStatus?
    @State private var remote: [RemoteBrokerStatus] = []
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Kept sessions")).font(.headline).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 6) {
                // FR-R08: applies to this Mac's broker and to every connected host's.
                Picker(
                    L("End idle kept sessions after"),
                    selection: Binding(get: { model.keptSessionIdleTimeoutHours }, set: { model.setKeptSessionIdleTimeout(hours: $0) })
                ) {
                    ForEach(KeptSessionIdleTimeout.choices, id: \.self) { Text(KeptSessionIdleTimeout.label(hours: $0)).tag($0) }
                }
                .fixedSize().accessibilityIdentifier("settings.keptSessionIdleTimeout")
                caption(
                    model.keptSessionIdleTimeoutHours == 0
                        ? L("Sessions left running with Trellis closed or disconnected are kept until they end by themselves.")
                        : L("A session left running with Trellis closed or disconnected is ended once it has printed nothing for this long. Sessions shown in a pane are never ended.")
                ).accessibilityIdentifier("settings.keptSessionIdleTimeoutNote")
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 10)
            Rectangle().fill(model.themeColor(.border)).frame(height: 1).accessibilityHidden(true)
            Text(L("This Mac and connected hosts")).font(.headline).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 6) {
                switch local {
                case nil: Text(L("Checking…")).foregroundStyle(model.themeColor(.mutedForeground))
                case .notRunning?: Text(L("Not running. It starts with the next new session."))
                case .busy?: Label(L("Running, but another Trellis is connected to it."), systemImage: "exclamationmark.triangle")
                case .incompatible?: Label(L("Running an older or newer version this Trellis can't use."), systemImage: "exclamationmark.triangle")
                case .connected(let details)?:
                    Text(L("Running · PID %1$@ · protocol %2$@", String(details.processID), String(details.protocolVersion))).monospacedDigit()
                    Text(sessionCounts(running: details.running, ended: details.ended))
                    caption(L("Only this Trellis can connect: the broker checks every connection's user and executable (%@).", details.clientPath))
                    if let socket = details.socketPath {
                        Text(socket).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(model.themeColor(.mutedForeground))
                            .accessibilityLabel(L("Socket %@", socket))
                    }
                }
                if !remote.isEmpty {
                    Divider()
                    ForEach(remote) { host in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.hostName).fontWeight(.semibold)
                            Text(([host.platform, L("PID %@", String(host.processID)), L("protocol %@", String(host.protocolVersion))].compactMap { $0 }).joined(separator: " · ")).monospacedDigit()
                            Text(sessionCounts(running: host.running, ended: host.ended)).foregroundStyle(model.themeColor(.mutedForeground))
                        }
                        .accessibilityElement(children: .combine)
                    }
                    caption(L("Each host keeps a separate broker for this Mac; only its Trellis helper, reached through your ssh connection, can connect."))
                }
                HStack {
                    Spacer()
                    Button(L("Refresh"), action: refresh).disabled(loading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 10)
            // A single rule under the section instead of a box around it.
            Rectangle().fill(model.themeColor(.border)).frame(height: 1).accessibilityHidden(true)
        }
        // Not a Form, which insets itself: line up with the section title and divider like the other sections.
        .padding(.leading, 16)
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

    private func sessionCounts(running: Int, ended: Int) -> String {
        guard ended > 0 else { return running == 1 ? L("1 session running") : L("%d sessions running", running) }
        return running == 1 ? L("1 session running, %d ended", ended) : L("%1$d sessions running, %2$d ended", running, ended)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(model.themeColor(.mutedForeground)).fixedSize(horizontal: false, vertical: true)
    }
}
