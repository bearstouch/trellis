import SwiftUI
import TrellisCore

/// The machine a pane runs on, as the pane header and the bottom bar show it: a symbol, the name, and a link
/// that isn't connected in plain words (FR-RW05, FR-RW07).
struct PaneMachine: Equatable {
    enum Tone: Equatable { case local, remote, linkDown }
    let name: String
    /// " · Reconnecting (attempt 2)…"; empty while connected.
    let linkText: String
    let symbol: String
    let tone: Tone

    // Computed: a stored constant would keep the language it was first read in.
    static var local: PaneMachine { PaneMachine(name: L("Local"), linkText: "", symbol: "laptopcomputer", tone: .local) }
    /// An ssh session Trellis only knows from its command or the shell's own report (FR-SI09).
    static let ssh = PaneMachine(name: "SSH", linkText: "", symbol: "network", tone: .remote)
    static func host(_ name: String, link: RemoteLinkDisplay) -> PaneMachine {
        PaneMachine(
            name: name, linkText: link == .connected ? "" : " · " + link.label, symbol: link == .connected ? "server.rack" : link.symbol,
            tone: link.isUp ? .remote : .linkDown)
    }
}

/// The symbol and the name are never color alone: the words carry the machine and the link's state.
struct PaneMachineLabel: View {
    let machine: PaneMachine
    // Observed, not a plain `let`: with the same machine and model reference SwiftUI could skip this body and keep the old theme's colors.
    @ObservedObject var model: AppWorkspaceModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: machine.symbol).foregroundStyle(model.machineSymbolColor(machine.tone)).accessibilityHidden(true)
            HStack(spacing: 0) {
                Text(machine.name).fontWeight(.semibold).foregroundStyle(model.themeColor(.foreground)).lineLimit(1)
                // A narrow pane shortens the name, never the link's state (FR-RW07).
                Text(machine.linkText).lineLimit(1).fixedSize()
            }
        }.accessibilityElement(children: .combine)
    }
}

extension AppWorkspaceModel {
    func machineSymbolColor(_ tone: PaneMachine.Tone) -> Color {
        switch tone {
        case .local: themeColor(.mutedForeground)
        case .remote: themeColor(.accent)
        case .linkDown: themeColor(.warning)
        }
    }

    /// The bottom bar's machine: the focused pane's; a space with no pane yet is on this Mac.
    var focusedMachine: PaneMachine { presentation.selectedTab.map { paneContext($0.activePaneID).machine } ?? .local }

    func paneContext(_ id: UUID) -> (directory: String?, machine: PaneMachine) {
        let launch = snapshot.panes[id].flatMap { snapshot.sessions[$0.sessionID]?.launch }
        let directory: String
        // A remote workspace pane: its authenticated directory on the host, named after the host (FR-RW05).
        if case .remoteShell(let hostID, let path)? = launch {
            // FR-RW07: a pane on a host that isn't connected says so, in words.
            return (remoteWorkingDirectory(paneID: id) ?? path, .host(remoteHostName(hostID), link: remoteLinks[hostID] ?? .disconnected(nil)))
        }
        if case .agent(let agent)? = launch, let hostID = agent.hostID {
            return (agent.directory, .host(remoteHostName(hostID), link: remoteLinks[hostID] ?? .disconnected(nil)))
        }
        // A remote shell's own report, unverified and display-only (FR-SI09).
        if let launch, Self.isRemote(launch) { return (remoteDirectory(paneID: id), .ssh) }
        switch launch {
        case .host, .remoteShell: return (nil, .ssh)
        // Shell integration reports the live directory; otherwise show where the session started (INT-01).
        case .shell(let path), .process(_, _, let path): directory = currentDirectory(paneID: id) ?? path ?? defaultDirectory
        case .agent(let agent): directory = agent.directory ?? defaultDirectory
        case nil: directory = defaultDirectory
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let display = directory == home ? "~" : directory.hasPrefix(home + "/") ? "~" + directory.dropFirst(home.count) : directory
        return (display, .local)
    }
}
