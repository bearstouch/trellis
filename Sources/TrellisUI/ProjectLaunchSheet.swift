import SwiftUI
import TrellisCore

/// Launching a library project (FR-PL06–FR-PL08): where it runs, what the target holds, and the setup terminal.
struct ProjectLaunchSheet: View {
    @ObservedObject var model: AppWorkspaceModel
    @ObservedObject var session: ProjectLaunchSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Launch “\(session.project.name)”").font(.headline)
            if showsChoice {
                Picker("Target", selection: Binding(get: { session.target }, set: { model.setProjectLaunchTarget(session, $0) })) {
                    Label("This Mac", systemImage: "desktopcomputer").tag(ProjectTarget.local)
                    ForEach(model.commandPaletteHosts()) { host in Label(host.name, systemImage: "server.rack").tag(ProjectTarget.host(host.id)) }
                }
                .frame(width: 360).accessibilityLabel("Target")
                VStack(alignment: .leading, spacing: 3) {
                    Text(folderTitle).font(.caption).foregroundStyle(model.themeColor(.mutedForeground))
                    HStack {
                        TextField(folderTitle, text: $session.folder).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                            .accessibilityLabel(folderTitle).onSubmit(check)
                        Button("Check", action: check)
                    }
                }
            }
            stageView
            HStack {
                Spacer()
                Button("Cancel") { model.cancelProjectLaunch(session) }.keyboardShortcut(.cancelAction)
                switch session.stage {
                case .ready(let launch):
                    // A folder edited after the check runs nothing until it is checked again.
                    Button(launch.needsSetup ? "Set Up & Open" : "Open") { proceed(launch) }.keyboardShortcut(.defaultAction).disabled(!session.isCurrent)
                        .help(session.isCurrent ? "" : "Check the new folder first")
                case .failed(let launch, _):
                    Button("Open Anyway") { Task { await model.openProjectLaunch(session, launch) } }
                    Button("Retry") { Task { await model.runProjectSetup(session) } }.keyboardShortcut(.defaultAction)
                default: EmptyView()
                }
            }
        }
        .padding(24).frame(width: 700)
    }

    private var showsChoice: Bool {
        switch session.stage {
        case .checking, .ready, .invalid: true
        default: false
        }
    }

    private var folderTitle: String { session.target == .local ? "Folder on this Mac" : "Folder in your home folder on \(targetName)" }

    private var targetName: String {
        switch session.target {
        case .local: "this Mac"
        case .host(let id): model.remoteHostName(id)
        }
    }

    @ViewBuilder private var stageView: some View {
        switch session.stage {
        case .checking:
            HStack {
                ProgressView().controlSize(.small); Text("Checking \(targetName)…")
            }.accessibilityElement(children: .combine)
        case .invalid(let message):
            Label(message, systemImage: "xmark.octagon").fixedSize(horizontal: false, vertical: true)
        case .ready(let launch):
            plan(launch)
        case .settingUp:
            setupTerminal(status: "Setting up on \(targetName). Answer git's questions in the terminal; Trellis never answers them for you.")
        case .failed(_, let message):
            if session.terminal != nil { setupTerminal(status: message) } else { Label(message, systemImage: "xmark.octagon").fixedSize(horizontal: false, vertical: true) }
        case .opening:
            HStack {
                ProgressView().controlSize(.small); Text("Opening the workspace…")
            }.accessibilityElement(children: .combine)
        }
    }

    private func setupTerminal(status: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status).font(.callout).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.updatesFrequently)
            if let terminal = session.terminal {
                // The same inset and background as a pane's terminal.
                NativeTerminalSurface(terminal: terminal).padding(.horizontal, 8).padding(.top, 8).background(model.terminalBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6)).frame(width: 650, height: 280).accessibilityLabel("Setup terminal on \(targetName)")
            }
        }
    }

    private func plan(_ launch: ProjectLaunch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On \(targetName)").font(.subheadline.weight(.semibold))
            step(
                launch.rootExists ? "checkmark.circle" : "folder.badge.plus",
                launch.rootExists ? "\(display(launch)) exists" : "Create \(display(launch))")
            ForEach(Array(launch.checkouts.enumerated()), id: \.offset) { _, checkout in
                let name = GitRepository.shortName(checkout.repository.url) + (checkout.repository.branch.map { " (\($0))" } ?? "")
                let folder = checkout.folder.isEmpty ? "the project folder" : checkout.folder
                switch checkout.state {
                case .present: step("checkmark.circle", "\(folder) is already a checkout, left as it is")
                case .clone: step("arrow.down.circle", checkout.folder.isEmpty ? "Set up the project folder from \(name)" : "Clone \(name) → \(folder)")
                case .blocked: step("exclamationmark.triangle", "\(folder) exists but isn't a checkout, so it isn't touched")
                }
            }
            let project = launch.project
            step(
                "rectangle.on.rectangle",
                "Open \(project.tabs.count) tab\(project.tabs.count == 1 ? "" : "s"), \(project.paneCount) pane\(project.paneCount == 1 ? "" : "s")"
                    + (project.commandCount == 0 ? "" : ", run \(project.commandCount) command\(project.commandCount == 1 ? "" : "s")"))
            if launch.needsSetup {
                Text("Setup uses \(targetName)'s own git and credentials.").font(.caption).foregroundStyle(model.themeColor(.mutedForeground))
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(model.themeColor(.sidebarBackground), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain).accessibilityLabel("What will happen")
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
