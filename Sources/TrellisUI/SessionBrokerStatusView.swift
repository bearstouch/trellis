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
        Form {
            Section(L("Kept sessions")) {
                // FR-R08: applies to this Mac's broker and to every connected host's.
                Picker(selection: Binding(get: { model.keptSessionIdleTimeoutHours }, set: { model.setKeptSessionIdleTimeout(hours: $0) })) {
                    ForEach(KeptSessionIdleTimeout.choices, id: \.self) { Text(KeptSessionIdleTimeout.label(hours: $0)).tag($0) }
                } label: {
                    SettingsLabel(
                        L("End idle kept sessions after"),
                        help: model.keptSessionIdleTimeoutHours == 0
                            ? L("Sessions left running with Trellis closed or disconnected are kept until they end by themselves.")
                            : L("A session left running with Trellis closed or disconnected is ended once it has printed nothing for this long. Sessions shown in a pane are never ended."))
                }
                .accessibilityIdentifier("settings.keptSessionIdleTimeout")
            }
            Section {
                localStatus
                ForEach(remote) { host in
                    LabeledContent {
                        Text(sessionCounts(running: host.running, ended: host.ended)).foregroundStyle(.secondary)
                    } label: {
                        SettingsLabel(
                            host.hostName,
                            help: ([host.platform, L("PID %@", String(host.processID)), L("protocol %@", String(host.protocolVersion))].compactMap { $0 }).joined(separator: " · "))
                    }
                    .accessibilityElement(children: .combine)
                }
                if !remote.isEmpty {
                    SettingsNote(text: L("Each host keeps a separate broker for this Mac; only its Trellis helper, reached through your ssh connection, can connect."))
                }
            } header: {
                HStack {
                    Text(L("This Mac and connected hosts"))
                    Spacer()
                    Button(L("Refresh"), action: refresh).disabled(loading)
                }
            }
        }
        .settingsFormStyle()
        .accessibilityElement(children: .contain).accessibilityIdentifier("settings.sessionBroker")
        .task { refresh() }
    }

    @ViewBuilder private var localStatus: some View {
        switch local {
        case nil: Text(L("Checking…")).foregroundStyle(.secondary)
        case .notRunning?: Text(L("Not running. It starts with the next new session."))
        case .busy?: Label(L("Running, but another Trellis is connected to it."), systemImage: "exclamationmark.triangle")
        case .incompatible?: Label(L("Running an older or newer version this Trellis can't use."), systemImage: "exclamationmark.triangle")
        case .connected(let details)?:
            LabeledContent {
                Text(sessionCounts(running: details.running, ended: details.ended)).foregroundStyle(.secondary)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Running · PID %1$@ · protocol %2$@", String(details.processID), String(details.protocolVersion))).monospacedDigit()
                    SettingsNote(text: L("Only this Trellis can connect: the broker checks every connection's user and executable (%@).", details.clientPath))
                }
            }
        }
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
}
