import SwiftUI
import TrellisBroker
import TrellisCore

struct PaneTreeView: View {
    @ObservedObject var model: AppWorkspaceModel
    let layout: PaneLayout
    let activePaneID: UUID
    let tabID: UUID
    @State private var dragStartRatio: Double?

    var body: some View {
        GeometryReader { geometry in
            switch layout {
            case .pane(let id): leaf(id, size: geometry.size)
            case .split(let id, let axis, let ratio, let children):
                if children.count == 2 {
                    if axis == .x {
                        HStack(spacing: 0) {
                            PaneTreeView(model: model, layout: children[0], activePaneID: activePaneID, tabID: tabID)
                                .frame(width: max(0, geometry.size.width - CanvasDimensions.dividerThickness) * ratio)
                            divider(id, axis: axis, ratio: ratio, size: geometry.size)
                            PaneTreeView(model: model, layout: children[1], activePaneID: activePaneID, tabID: tabID)
                        }
                    } else {
                        VStack(spacing: 0) {
                            PaneTreeView(model: model, layout: children[0], activePaneID: activePaneID, tabID: tabID)
                                .frame(height: max(0, geometry.size.height - CanvasDimensions.dividerThickness) * ratio)
                            divider(id, axis: axis, ratio: ratio, size: geometry.size)
                            PaneTreeView(model: model, layout: children[1], activePaneID: activePaneID, tabID: tabID)
                        }
                    }
                }
            }
        }.background(model.themeColor(.border))
            .coordinateSpace(name: layoutCoordinateSpace)
    }

    private var layoutCoordinateSpace: UUID {
        switch layout {
        case .pane(let id): return id;
        case .split(let id, _, _, _): return id
        }
    }

    @ViewBuilder private func leaf(_ id: UUID, size: CGSize) -> some View {
        if let terminal = model.terminals[id] {
            let focused = activePaneID == id
            let descriptor = model.accessibility.panes.first { $0.id == id }
            let context = sessionContext(id)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button(model.paneTitle(id)) { Task { await model.selectPane(id) } }
                        .buttonStyle(.plain).lineLimit(1).fontWeight(focused ? .semibold : .regular)
                        .accessibilityLabel(descriptor?.label ?? "Terminal")
                        .accessibilityValue(descriptor?.value ?? "")
                        .accessibilityHint("Focuses this pane")
                        .accessibilityAddTraits(focused ? [.isSelected] : [])
                    if let directory = context.directory {
                        Image(systemName: "folder").accessibilityHidden(true)
                        // The first thing to give way in a narrow pane: a title cut to "…" says nothing at all.
                        Text(directory).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                            .help(context.kind == "SSH" ? "\(directory) — reported by the remote shell, unverified" : directory)
                            .accessibilityHint(context.kind == "SSH" ? "Reported by the remote shell, unverified" : "")
                    }
                    Spacer(minLength: 0)
                    if let code = model.failedCommandExit(paneID: id) {
                        // Visible text and a symbol, not color alone (FR-SI04).
                        Label("Exit \(code)", systemImage: "exclamationmark.circle").lineLimit(1)
                            .help(WorkspaceAccessibility.commandFailureText(code))
                            .accessibilityLabel(WorkspaceAccessibility.commandFailureText(code))
                    }
                    if let wait = model.inputWaits[id] {
                        Label(wait == .password ? "Password" : "Needs input", systemImage: "keyboard").lineLimit(1)
                            .help(wait.text).accessibilityLabel(wait.text)
                    }
                    if let progress = model.progress[id] {
                        // Text with the symbol, never the tab bar's color alone (FR-T09).
                        Label(progress.visibleText, systemImage: progress.state == .error ? "exclamationmark.triangle" : "chart.bar.fill").lineLimit(1)
                            .monospacedDigit().help("Progress: \(progress.visibleText)").accessibilityLabel(progress.spokenText)
                    }
                    if let detected = model.detectedAgent(paneID: id) {
                        // FR-AG15: still a shell, so its tools stay below and no state is claimed.
                        AgentStateLabel(agent: detected, state: nil, directory: model.agentCatalog.iconDirectories[detected.id], iconOnly: !AgentStateLabel.fitsName(paneWidth: size.width))
                    }
                    if let agent = model.agentDefinition(paneID: id) {
                        // FR-AG10: an agent pane shows its agent and state instead of shell tools.
                        AgentStateLabel(
                            agent: agent, state: terminal.sessionState == .running ? model.agentStates[id]?.state ?? .ready : .ready,
                            directory: model.agentCatalog.iconDirectories[agent.id])
                        AgentDropdownButton(model: model, paneID: id)
                    } else if context.kind == "Local" {
                        scratchpadButton(id, pressed: model.scratchpadVisible && focused)
                        TaskDropdownButton(model: model, paneID: id)
                        AgentDropdownButton(model: model, paneID: id)
                    } else if model.isRemoteWorkspace(paneID: id) {
                        // FR-RW11: the host's tasks; the scratchpad stays local.
                        TaskDropdownButton(model: model, paneID: id)
                        AgentDropdownButton(model: model, paneID: id)
                    }
                    if let git = model.gitStatuses[id] {
                        // An icon in the header; the branch and counts are in its hover card and read by VoiceOver (FR-PL09).
                        GitStatusBadge(
                            text: AppWorkspaceModel.gitStatusText(git), spoken: AppWorkspaceModel.gitStatusSpoken(git),
                            foreground: model.themeColor(.foreground), background: model.themeColor(.surface))
                    }
                    // The machine this pane runs on stands out (Local, SSH or the host's name); a link's state stays in plain words beside it.
                    let machine = context.host ?? context.kind
                    HStack(spacing: 0) {
                        Text(machine).fontWeight(.bold).foregroundStyle(model.machineLabelColor).lineLimit(1)
                        // A narrow pane shortens the name, never the link's state (FR-RW07).
                        Text(context.kind.dropFirst(machine.count)).lineLimit(1).fixedSize()
                    }.accessibilityElement(children: .combine)
                    if terminal.sessionState != .running {
                        // Text, not only color, reports stopped/exited/failed panes.
                        Text(SessionStatusText.describe(terminal.sessionState, exitCode: terminal.exitCode)).accessibilityHidden(true)
                    }
                    if terminal.sessionState == .exited || terminal.sessionState == .failed, let agent = model.agentDefinition(paneID: id), !agent.resumeArguments.isEmpty {
                        Button("Resume") { Task { await model.restartAgent(paneID: id, resume: true) } }
                            .help("Start \(agent.name) again, continuing its last conversation here")
                            .accessibilityLabel("Resume \(agent.name)")
                    }
                    if terminal.sessionState == .exited || terminal.sessionState == .failed {
                        // Saved-host panes reconnect only when the user asks; there is no retry timer.
                        let isHost =
                            model.snapshot.panes[id].flatMap { model.snapshot.sessions[$0.sessionID] }.map {
                                if case .host = $0.launch { true } else { false }
                            } == true
                        Button(isHost ? "Reconnect" : "Restart") {
                            Task { if model.agentLaunch(paneID: id) != nil { await model.restartAgent(paneID: id, resume: false) } else { await model.restartPane(id) } }
                        }
                        .help(isHost ? "Start a new ssh connection in this pane" : "Start a fresh session in this pane")
                        .accessibilityLabel(isHost ? "Reconnect" : "Restart Session")
                    }
                    Button {
                        Task { await model.toggleMaximize(id) }
                    } label: {
                        Image(systemName: model.maximizedPanes[tabID] == id ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }.help(model.maximizedPanes[tabID] == id ? "Restore Panes" : "Maximize Pane")
                        .accessibilityLabel(model.maximizedPanes[tabID] == id ? "Restore Panes" : "Maximize Pane")
                    Button {
                        split(id, axis: .x, size: size)
                    } label: {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .help("Split Left/Right").accessibilityLabel("Split Left/Right").disabled(model.maximizedPanes[tabID] != nil)
                    Button {
                        split(id, axis: .y, size: size)
                    } label: {
                        Image(systemName: "rectangle.split.1x2")
                    }
                    .help("Split Top/Bottom").accessibilityLabel("Split Top/Bottom").disabled(model.maximizedPanes[tabID] != nil)
                    Button {
                        Task { await model.closePane(id) }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("Close Pane").accessibilityLabel("Close Pane")
                }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(model.themeColor(.mutedForeground))
                    .padding(.horizontal, 9).frame(height: 30).background(model.themeColor(.surface))
                // A tab rename may select another tab first; its terminal host must not
                // take first responder from the name field (its input is suspended).
                SearchableTerminalSurface(
                    terminal: terminal, isFocused: focused && model.editingTabID == nil,
                    background: model.terminalBackground
                )
                .overlay {
                    if terminal.sessionState == .stopped {
                        VStack(spacing: 8) {
                            if let agent = model.agentDefinition(paneID: id) {
                                // FR-AG06: a restored agent pane starts fresh unless asked to continue; nothing is replayed.
                                Button("Start \(agent.name)") { Task { await model.restartAgent(paneID: id, resume: false) } }.buttonStyle(.borderedProminent)
                                if !agent.resumeArguments.isEmpty {
                                    Button("Resume Last Conversation") { Task { await model.restartAgent(paneID: id, resume: true) } }
                                }
                            } else if model.unconfiguredPaneIDs.contains(id) {
                                Text("Custom process needs fresh configuration.").font(.caption).foregroundStyle(Color(themeRGB: model.effectiveTheme.terminal.foreground))
                                Button("Start Shell Instead") { Task { await model.startRestoredShell(id) } }.buttonStyle(.borderedProminent)
                            } else {
                                Button("Start Session") { Task { await model.start(paneID: id) } }.buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
            }
        } else {
            model.terminalBackground
        }
    }

    /// Opens the scratchpad for this pane (FR-SP01); pressed in the pane it runs in while it is open.
    private func scratchpadButton(_ id: UUID, pressed: Bool) -> some View {
        let title = pressed ? "Hide Scratchpad" : "Scratchpad"
        return Button {
            Task { await model.toggleScratchpad(paneID: id) }
        } label: {
            Image(systemName: "chevron.left.forwardslash.chevron.right").frame(width: 20, height: 18)
                .foregroundStyle(pressed ? model.themeColor(.accent) : model.themeColor(.mutedForeground))
                .background(RoundedRectangle(cornerRadius: 4).fill(pressed ? model.themeColor(.accent).opacity(0.14) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(pressed ? model.themeColor(.accent).opacity(0.4) : .clear))
                .contentShape(Rectangle())
        }
        .help(model.keyboard.shortcuts[.toggleScratchpad].map { "\(title) (\($0))" } ?? title)
        .accessibilityLabel("Scratchpad").accessibilityAddTraits(pressed ? [.isSelected] : [])
    }

    private func sessionContext(_ id: UUID) -> (directory: String?, kind: String, host: String?) {
        let launch = model.snapshot.panes[id].flatMap { model.snapshot.sessions[$0.sessionID]?.launch }
        let directory: String
        // A remote workspace pane: its authenticated directory on the host, named after the host (FR-RW05).
        if case .remoteShell(let hostID, let path)? = launch {
            // FR-RW07: a pane on a host that isn't connected says so, in words.
            let link = model.remoteLinks[hostID] ?? .disconnected(nil)
            let host = model.remoteHostName(hostID)
            return (model.remoteWorkingDirectory(paneID: id) ?? path, host + (link == .connected ? "" : " · " + link.label), host)
        }
        if case .agent(let agent)? = launch, let hostID = agent.hostID {
            let link = model.remoteLinks[hostID] ?? .disconnected(nil)
            let host = model.remoteHostName(hostID)
            return (agent.directory, host + (link == .connected ? "" : " · " + link.label), host)
        }
        // A remote shell's own report, unverified and display-only (FR-SI09).
        if let launch, AppWorkspaceModel.isRemote(launch) { return (model.remoteDirectory(paneID: id), "SSH", nil) }
        switch launch {
        case .host, .remoteShell: return (nil, "SSH", nil)
        // Shell integration reports the live directory; otherwise show where the session started (INT-01).
        case .shell(let path), .process(_, _, let path): directory = model.currentDirectory(paneID: id) ?? path ?? model.defaultDirectory
        case .agent(let agent): directory = agent.directory ?? model.defaultDirectory
        case nil: directory = model.defaultDirectory
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let display = directory == home ? "~" : directory.hasPrefix(home + "/") ? "~" + directory.dropFirst(home.count) : directory
        return (display, "Local", nil)
    }

    private func divider(_ id: UUID, axis: SplitAxis, ratio: Double, size: CGSize) -> some View {
        model.themeColor(.border)
            .frame(
                width: axis == .x ? CanvasDimensions.dividerThickness : nil,
                height: axis == .y ? CanvasDimensions.dividerThickness : nil
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(id)).onChanged { value in
                    if dragStartRatio == nil { dragStartRatio = ratio }
                    updateDivider(id, axis: axis, size: size, translation: value.translation)
                }.onEnded { value in
                    updateDivider(id, axis: axis, size: size, translation: value.translation)
                    dragStartRatio = nil
                }
            )
            .accessibilityLabel(axis == .x ? "Left/right divider" : "Top/bottom divider")
            .accessibilityValue("\(Int(ratio * 100)) percent")
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 0.05 : -0.05
                Task { await model.resizeSplit(id, ratio: ratio + delta, tabID: tabID) }
            }
    }

    private func updateDivider(_ id: UUID, axis: SplitAxis, size: CGSize, translation: CGSize) {
        guard let initial = dragStartRatio else { return }
        let length = (axis == .x ? size.width : size.height) - CanvasDimensions.dividerThickness
        guard length > 0 else { return }
        let delta = (axis == .x ? translation.width : translation.height) / length
        model.queueDividerResize(id, ratio: initial + delta, tabID: tabID)
    }

    private func split(_ id: UUID, axis: SplitAxis, size: CGSize) {
        Task { await model.splitPane(id, axis: axis, availableCanvas: CanvasDimensions(width: size.width, height: size.height)) }
    }
}
