import SwiftUI
import TrellisCore

/// Launching a library project (FR-PL06–FR-PL08): where it runs, what the target holds, and the setup terminal.
struct ProjectLaunchSheet: View {
    @ObservedObject var model: AppWorkspaceModel
    @ObservedObject var session: ProjectLaunchSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Launch “%@”", session.project.name)).font(.headline)
            if showsChoice {
                Picker(L("Target"), selection: Binding(get: { session.target }, set: { model.setProjectLaunchTarget(session, $0) })) {
                    Label(L("This Mac"), systemImage: "desktopcomputer").tag(ProjectTarget.local)
                    ForEach(model.commandPaletteHosts()) { host in Label(host.name, systemImage: "server.rack").tag(ProjectTarget.host(host.id)) }
                }
                .frame(width: 360).accessibilityLabel(L("Target"))
                VStack(alignment: .leading, spacing: 3) {
                    Text(folderTitle).font(.caption).foregroundStyle(model.themeColor(.mutedForeground))
                    HStack {
                        TextField(folderTitle, text: $session.folder).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                            .accessibilityLabel(folderTitle).onSubmit(check)
                        Button(L("Check"), action: check)
                    }
                }
            }
            stageView
            HStack {
                Spacer()
                Button(L("Cancel")) { model.cancelProjectLaunch(session) }.keyboardShortcut(.cancelAction)
                switch session.stage {
                case .ready(let launch):
                    // A folder edited after the check runs nothing until it is checked again.
                    Button(launch.needsSetup ? L("Set Up & Open") : L("Open")) { proceed(launch) }.keyboardShortcut(.defaultAction).disabled(!session.isCurrent)
                        .help(session.isCurrent ? "" : L("Check the new folder first"))
                case .failed(let launch, _):
                    Button(L("Open Anyway")) { Task { await model.openProjectLaunch(session, launch) } }
                    Button(L("Retry")) { Task { await model.runProjectSetup(session) } }.keyboardShortcut(.defaultAction)
                default: EmptyView()
                }
            }
        }
        .padding(24).frame(width: 700).fixedSize(horizontal: false, vertical: true)
    }

    private var showsChoice: Bool {
        switch session.stage {
        case .checking, .ready, .invalid: true
        default: false
        }
    }

    private var folderTitle: String { hostName.map { L("Folder in your home folder on %@", $0) } ?? L("Folder on this Mac") }

    /// The saved host the project runs on; nil on this Mac, which each sentence names itself.
    private var hostName: String? {
        switch session.target {
        case .local: nil
        case .host(let id): model.remoteHostName(id)
        }
    }

    @ViewBuilder private var stageView: some View {
        switch session.stage {
        case .checking:
            HStack {
                ProgressView().controlSize(.small); Text(hostName.map { L("Checking %@…", $0) } ?? L("Checking this Mac…"))
            }.accessibilityElement(children: .combine)
        case .invalid(let message):
            Label(message, systemImage: "xmark.octagon").fixedSize(horizontal: false, vertical: true)
        case .ready(let launch):
            plan(launch)
        case .settingUp:
            setupTerminal(
                status: hostName.map { L("Setting up on %@. Answer git's questions in the terminal; Trellis never answers them for you.", $0) }
                    ?? L("Setting up on this Mac. Answer git's questions in the terminal; Trellis never answers them for you."))
        case .failed(_, let message):
            if session.terminal != nil { setupTerminal(status: message) } else { Label(message, systemImage: "xmark.octagon").fixedSize(horizontal: false, vertical: true) }
        case .opening:
            HStack {
                ProgressView().controlSize(.small); Text(L("Opening the workspace…"))
            }.accessibilityElement(children: .combine)
        }
    }

    private func setupTerminal(status: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status).font(.callout).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.updatesFrequently)
            if let terminal = session.terminal {
                // The same inset and background as a pane's terminal.
                NativeTerminalSurface(terminal: terminal).padding(.horizontal, 8).padding(.top, 8).background(model.terminalBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6)).frame(width: 650, height: 280).accessibilityLabel(hostName.map { L("Setup terminal on %@", $0) } ?? L("Setup terminal on this Mac"))
            }
        }
    }

    private func plan(_ launch: ProjectLaunch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hostName.map { L("On %@", $0) } ?? L("On this Mac")).font(.subheadline.weight(.semibold))
            step(
                launch.rootExists ? "checkmark.circle" : "folder.badge.plus",
                launch.rootExists ? L("%@ exists", display(launch)) : L("Create %@", display(launch)))
            ForEach(Array(launch.checkouts.enumerated()), id: \.offset) { _, checkout in
                let name = GitRepository.shortName(checkout.repository.url) + (checkout.repository.branch.map { " (\($0))" } ?? "")
                let folder = checkout.folder
                switch checkout.state {
                case .present: step("checkmark.circle", folder.isEmpty ? L("the project folder is already a checkout, left as it is") : L("%@ is already a checkout, left as it is", folder))
                case .clone: step("arrow.down.circle", folder.isEmpty ? L("Set up the project folder from %@", name) : L("Clone %1$@ → %2$@", name, folder))
                case .blocked:
                    step("exclamationmark.triangle", folder.isEmpty ? L("the project folder exists but isn't a checkout, so it isn't touched") : L("%@ exists but isn't a checkout, so it isn't touched", folder))
                }
            }
            let tabs = launch.project.tabs.count, panes = launch.project.paneCount, commands = launch.project.commandCount
            let parts: [String?] = [
                tabs == 1 ? L("Open 1 tab") : L("Open %d tabs", tabs), panes == 1 ? L("1 pane") : L("%d panes", panes),
                commands == 0 ? nil : commands == 1 ? L("run 1 command") : L("run %d commands", commands)
            ]
            step("rectangle.on.rectangle", parts.compactMap { $0 }.joined(separator: ", "))
            if launch.needsSetup {
                Text(hostName.map { L("Setup uses %@'s own git and credentials.", $0) } ?? L("Setup uses this Mac's own git and credentials.")).font(.caption).foregroundStyle(model.themeColor(.mutedForeground))
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(model.themeColor(.sidebarBackground), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain).accessibilityLabel(L("What will happen"))
    }

    private func step(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).fixedSize(horizontal: false, vertical: true)
    }

    private func display(_ launch: ProjectLaunch) -> String {
        switch launch.target {
        case .local:
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return launch.root.hasPrefix(home + "/") ? "~" + launch.root.dropFirst(home.count) : launch.root
        case .host: return "~/" + launch.folder
        }
    }

    private func check() { Task { await model.checkProjectLaunch(session) } }

    private func proceed(_ launch: ProjectLaunch) {
        Task { if launch.needsSetup { await model.runProjectSetup(session) } else { await model.openProjectLaunch(session, launch) } }
    }
}
