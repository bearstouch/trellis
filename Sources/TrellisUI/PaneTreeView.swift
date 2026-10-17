import SwiftUI
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
                        Text(directory).lineLimit(1).truncationMode(.middle)
                            .help(directory)
                    }
                    Spacer(minLength: 0)
                    if let code = model.failedCommandExit(paneID: id) {
                        // Visible text and a symbol, not color alone (FR-SI04).
                        Label("Exit \(code)", systemImage: "exclamationmark.circle").lineLimit(1)
                            .help(WorkspaceAccessibility.commandFailureText(code))
                            .accessibilityLabel(WorkspaceAccessibility.commandFailureText(code))
                    }
                    Text(context.kind).lineLimit(1)
                    if terminal.sessionState != .running {
                        // Text, not only color, reports stopped/exited/failed panes.
                        Text(SessionStatusText.describe(terminal.sessionState, exitCode: terminal.exitCode)).accessibilityHidden(true)
                    }
                    if terminal.sessionState == .exited || terminal.sessionState == .failed {
                        // Saved-host panes reconnect only when the user asks; there is no retry timer.
                        let isHost =
                            model.snapshot.panes[id].flatMap { model.snapshot.sessions[$0.sessionID] }.map {
                                if case .host = $0.launch { true } else { false }
                            } == true
                        Button(isHost ? "Reconnect" : "Restart") { Task { await model.restartPane(id) } }
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
                            if model.unconfiguredPaneIDs.contains(id) {
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

    private func sessionContext(_ id: UUID) -> (directory: String?, kind: String) {
        let launch = model.snapshot.panes[id].flatMap { model.snapshot.sessions[$0.sessionID]?.launch }
        let directory: String
        switch launch {
        case .host: return (nil, "SSH")
        // Shell integration reports the live directory; otherwise show where the session started (INT-01).
        case .shell(let path), .process(_, _, let path): directory = model.currentDirectory(paneID: id) ?? path ?? model.defaultDirectory
        case nil: directory = model.defaultDirectory
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let display = directory == home ? "~" : directory.hasPrefix(home + "/") ? "~" + directory.dropFirst(home.count) : directory
        return (display, "Local")
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
