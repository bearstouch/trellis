import SwiftUI
import TrellisBroker
import TrellisCore

struct PaneTreeView: View {
    @ObservedObject var model: AppWorkspaceModel
    let layout: PaneLayout
    let activePaneID: UUID
    let tabID: UUID
    @State private var dragStartRatio: Double?
    /// The divider's position while it is dragged. Kept here, not in the store, so a mouse step redraws this split
    /// alone instead of publishing a snapshot to the whole window; the store gets the final ratio on release.
    @State private var liveRatio: Double?
    @State private var dividerHovered = false
    /// Whether the resize cursor is pushed, so it is popped exactly once, also when the split goes away under the mouse.
    @State private var cursorPushed = false
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        GeometryReader { geometry in
            switch layout {
            case .pane(let id): leaf(id, size: geometry.size)
            case .split(let id, let axis, let stored, let children):
                if children.count == 2 {
                    let ratio = liveRatio ?? stored
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
        }.background(model.panesTranslucent ? .clear : model.themeColor(.border))
            .transformEnvironment(\.terminalRowsHeld) { if rowsHeld { $0 = true } }
            .coordinateSpace(name: layoutCoordinateSpace)
            .onDisappear { if cursorPushed { cursorPushed = false; NSCursor.pop() } }
            // This view outlives its split (a pane closes, one is maximized, another tab is selected), and a drag cut
            // short that way gets no `onEnded`: without this the next split shown here would keep the dragged ratio.
            .onChange(of: layoutCoordinateSpace) { _, _ in
                dragStartRatio = nil; liveRatio = nil; dividerHovered = false
                if cursorPushed { cursorPushed = false; NSCursor.pop() }
            }
    }

    /// A top/bottom drag changes the height of every pane below this split.
    private var rowsHeld: Bool {
        if case .split(_, .y, _, _) = layout { return dragStartRatio != nil }
        return false
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
            let context = model.paneContext(id)
            let focusStyle = model.paneFocusStyle(paneID: id, tabID: tabID, windowActive: controlActiveState != .inactive, increasedContrast: colorSchemeContrast == .increased)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button(model.paneTitle(id)) { Task { await model.selectPane(id) } }
                        .buttonStyle(.plain).lineLimit(1).fontWeight(focused ? .semibold : .regular)
                        .foregroundStyle(focusStyle.header == .focused ? model.themeColor(.foreground) : model.themeColor(.mutedForeground))
                        .accessibilityLabel(descriptor?.label ?? L("Terminal"))
                        .accessibilityValue(descriptor?.value ?? "")
                        .accessibilityHint(L("Focuses this pane"))
                        .accessibilityAddTraits(focused ? [.isSelected] : [])
                    if let directory = context.directory {
                        Image(systemName: "folder").accessibilityHidden(true)
                        // The first thing to give way in a narrow pane: a title cut to "…" says nothing at all.
                        Text(directory).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                            .help(context.machine == .ssh ? L("%@ — reported by the remote shell, unverified", directory) : directory)
                            .accessibilityHint(context.machine == .ssh ? L("Reported by the remote shell, unverified") : "")
                    }
                    Spacer(minLength: 0)
                    if let code = model.failedCommandExit(paneID: id) {
                        // Visible text and a symbol, not color alone (FR-SI04).
                        Label(L("Exit %d", Int(code)), systemImage: "exclamationmark.circle").lineLimit(1)
                            .help(WorkspaceAccessibility.commandFailureText(code))
                            .accessibilityLabel(WorkspaceAccessibility.commandFailureText(code))
                    }
                    if let wait = model.inputWaits[id] {
                        Label(wait == .password ? L("Password") : L("Needs input"), systemImage: "keyboard").lineLimit(1)
                            .help(wait.text).accessibilityLabel(wait.text)
                    }
                    if let progress = model.progress[id] {
                        // Text with the symbol, never the tab bar's color alone (FR-T09).
                        Label(progress.visibleText, systemImage: progress.state == .error ? "exclamationmark.triangle" : "chart.bar.fill").lineLimit(1)
                            .monospacedDigit().help(L("Progress: %@", progress.visibleText)).accessibilityLabel(progress.spokenText)
                    }
                    // FR-AG09/FR-AG10: an agent's icon and state are on its tab, not repeated here.
                    // FR-SB06: the scratchpad, tasks, agents and git changes live in the right sidebar, for the focused pane.
                    PaneMachineLabel(machine: context.machine, model: model)
                    if terminal.sessionState != .running {
                        // Text, not only color, reports stopped/exited/failed panes.
                        Text(SessionStatusText.describe(terminal.sessionState, exitCode: terminal.exitCode)).accessibilityHidden(true)
                    }
                    if terminal.sessionState == .exited || terminal.sessionState == .failed, let agent = model.agentDefinition(paneID: id), !agent.resumeArguments.isEmpty {
                        Button(L("Resume")) { Task { await model.restartAgent(paneID: id, resume: true) } }
                            .help(L("Start %@ again, continuing its last conversation here", agent.name))
                            .accessibilityLabel(L("Resume %@", agent.name))
                    }
                    if terminal.sessionState == .exited || terminal.sessionState == .failed {
                        // Saved-host panes reconnect only when the user asks; there is no retry timer.
                        let isHost =
                            model.snapshot.panes[id].flatMap { model.snapshot.sessions[$0.sessionID] }.map {
                                if case .host = $0.launch { true } else { false }
                            } == true
                        Button(isHost ? L("Reconnect") : L("Restart")) {
                            Task { if model.agentLaunch(paneID: id) != nil { await model.restartAgent(paneID: id, resume: false) } else { await model.restartPane(id) } }
                        }
                        .help(isHost ? L("Start a new ssh connection in this pane") : L("Start a fresh session in this pane"))
                        .accessibilityLabel(isHost ? L("Reconnect") : L("Restart Session"))
                    }
                    Button {
                        Task { await model.toggleMaximize(id) }
                    } label: {
                        Image(systemName: model.maximizedPanes[tabID] == id ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }.buttonStyle(iconStyle).help(model.maximizedPanes[tabID] == id ? L("Restore Panes") : L("Maximize Pane"))
                        .accessibilityLabel(model.maximizedPanes[tabID] == id ? L("Restore Panes") : L("Maximize Pane"))
                    Button {
                        split(id, axis: .x, size: size)
                    } label: {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .buttonStyle(iconStyle).help(L("Split Left/Right")).accessibilityLabel(L("Split Left/Right")).disabled(model.maximizedPanes[tabID] != nil)
                    Button {
                        split(id, axis: .y, size: size)
                    } label: {
                        Image(systemName: "rectangle.split.1x2")
                    }
                    .buttonStyle(iconStyle).help(L("Split Top/Bottom")).accessibilityLabel(L("Split Top/Bottom")).disabled(model.maximizedPanes[tabID] != nil)
                    Button {
                        Task { await model.closePane(id) }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(iconStyle).help(L("Close Pane")).accessibilityLabel(L("Close Pane"))
                }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(model.themeColor(.mutedForeground))
                    // No chrome fill: the header sits on the terminal's own background, so the pane reads as one surface (FR-P05, FR-TH10).
                    .padding(.horizontal, 9).frame(height: 30)
                    .background(model.terminalBackground.opacity(model.effectiveBackgroundOpacity))
                    // On the bottom edge: along the top it would stack against the selected tab's underline.
                    .overlay(alignment: .bottom) {
                        if focusStyle.header == .focused { model.themeColor(.focusRing).frame(height: 3).allowsHitTesting(false).accessibilityHidden(true) }
                    }
                // A tab rename may select another tab first; its terminal host must not
                // take first responder from the name field (its input is suspended).
                SearchableTerminalSurface(
                    terminal: terminal, isFocused: focused && model.editingTabID == nil && !model.welcomeTourVisible,
                    background: model.terminalBackground, dim: focusStyle.dim, opacity: model.effectiveBackgroundOpacity
                )
                .overlay {
                    if terminal.sessionState == .stopped {
                        VStack(spacing: 8) {
                            if let agent = model.agentDefinition(paneID: id) {
                                // FR-AG06: a restored agent pane starts fresh unless asked to continue; nothing is replayed.
                                Button(L("Start %@", agent.name)) { Task { await model.restartAgent(paneID: id, resume: false) } }.buttonStyle(.borderedProminent)
                                if !agent.resumeArguments.isEmpty {
                                    Button(L("Resume Last Conversation")) { Task { await model.restartAgent(paneID: id, resume: true) } }
                                }
                            } else if model.unconfiguredPaneIDs.contains(id) {
                                Text(L("Custom process needs fresh configuration.")).font(.caption).foregroundStyle(Color(themeRGB: model.effectiveTheme.terminal.foreground))
                                Button(L("Start Shell Instead")) { Task { await model.startRestoredShell(id) } }.buttonStyle(.borderedProminent)
                            } else {
                                Button(L("Start Session")) { Task { await model.start(paneID: id) } }.buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
            }
        } else {
            model.terminalBackground.opacity(model.effectiveBackgroundOpacity)
        }
    }

    private var iconStyle: PaneHeaderIconStyle { PaneHeaderIconStyle(rest: model.themeColor(.mutedForeground), hover: model.themeColor(.foreground)) }

    private func divider(_ id: UUID, axis: SplitAxis, ratio: Double, size: CGSize) -> some View {
        // A 1-point line in the layout, with a wider invisible grab area over the panes' own margins.
        model.themeColor(.border)
            .frame(
                width: axis == .x ? CanvasDimensions.dividerThickness : nil,
                height: axis == .y ? CanvasDimensions.dividerThickness : nil
            )
            .padding(axis == .x ? .horizontal : .vertical, 3).contentShape(Rectangle()).padding(axis == .x ? .horizontal : .vertical, -3).zIndex(1)
            .onHover {
                dividerHovered = $0; syncCursor(axis)
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(id)).onChanged { value in
                    if dragStartRatio == nil { dragStartRatio = ratio; syncCursor(axis) }
                    updateDivider(axis: axis, size: size, translation: value.translation)
                }.onEnded { value in
                    updateDivider(axis: axis, size: size, translation: value.translation)
                    dragStartRatio = nil
                    syncCursor(axis)
                    guard let final = liveRatio else { return }
                    Task {
                        await model.resizeSplit(id, ratio: final, tabID: tabID, quietly: true)
                        // In the same turn as the published snapshot, so the divider never shows the old ratio in between.
                        if dragStartRatio == nil { liveRatio = nil }
                    }
                }
            )
            .accessibilityLabel(axis == .x ? L("Left/right divider") : L("Top/bottom divider"))
            .accessibilityValue(L("%d percent", Int(ratio * 100)))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 0.05 : -0.05
                Task { await model.resizeSplit(id, ratio: ratio + delta, tabID: tabID) }
            }
    }

    /// The resize cursor shows under the pointer and for the whole drag, which leaves the grab area when a pane reaches its minimum.
    private func syncCursor(_ axis: SplitAxis) {
        let wanted = dividerHovered || dragStartRatio != nil
        guard wanted != cursorPushed else { return }
        cursorPushed = wanted
        if wanted { (axis == .x ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
    }

    private func updateDivider(axis: SplitAxis, size: CGSize, translation: CGSize) {
        guard let initial = dragStartRatio else { return }
        let length = axis == .x ? size.width : size.height
        guard length > CanvasDimensions.dividerThickness else { return }
        let delta = (axis == .x ? translation.width : translation.height) / (length - CanvasDimensions.dividerThickness)
        guard let next = CanvasDimensions.dividerRatio(nearest: initial + delta, in: layout, length: length), next != liveRatio else { return }
        liveRatio = next
    }

    private func split(_ id: UUID, axis: SplitAxis, size: CGSize) {
        Task { await model.splitPane(id, axis: axis, availableCanvas: CanvasDimensions(width: size.width, height: size.height)) }
    }
}

/// The pane header's icon buttons: muted at rest, the full foreground color under the pointer.
private struct PaneHeaderIconStyle: ButtonStyle {
    let rest: Color
    let hover: Color

    func makeBody(configuration: Configuration) -> some View { HoverLabel(configuration: configuration, rest: rest, hover: hover) }

    private struct HoverLabel: View {
        let configuration: Configuration
        let rest: Color
        let hover: Color
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label.foregroundStyle(hovering && isEnabled ? hover : rest).opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle()).onHover { hovering = $0 }
        }
    }
}
