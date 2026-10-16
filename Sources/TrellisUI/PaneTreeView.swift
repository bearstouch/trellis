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
        switch layout { case .pane(let id): return id; case .split(let id, _, _, _): return id }
    }

    @ViewBuilder private func leaf(_ id: UUID, size: CGSize) -> some View {
        if let terminal = model.terminals[id] {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button(model.snapshot.panes[id]?.title ?? "Terminal") { Task { await model.selectPane(id) } }
                        .buttonStyle(.plain).lineLimit(1)
                    Spacer(minLength: 0)
                    if terminal.sessionState == .exited || terminal.sessionState == .failed {
                        Button("Restart") { Task { await model.restartPane(id) } }
                            .help("Start a fresh session in this pane").accessibilityLabel("Restart Session")
                    }
                    Button { Task { await model.toggleMaximize(id) } } label: {
                        Image(systemName: model.maximizedPanes[tabID] == id ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }.help(model.maximizedPanes[tabID] == id ? "Restore Panes" : "Maximize Pane")
                        .accessibilityLabel(model.maximizedPanes[tabID] == id ? "Restore Panes" : "Maximize Pane")
                    Button { split(id, axis: .x, size: size) } label: { Image(systemName: "rectangle.split.2x1") }
                        .help("Split Left/Right").accessibilityLabel("Split Left/Right").disabled(model.maximizedPanes[tabID] != nil)
                    Button { split(id, axis: .y, size: size) } label: { Image(systemName: "rectangle.split.1x2") }
                        .help("Split Top/Bottom").accessibilityLabel("Split Top/Bottom").disabled(model.maximizedPanes[tabID] != nil)
                    Button { Task { await model.closePane(id) } } label: { Image(systemName: "xmark") }
                        .help("Close Pane").accessibilityLabel("Close Pane")
                }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(model.themeColor(.mutedForeground))
                    .padding(.horizontal, 9).frame(height: 26).background(model.themeColor(.surface))
                SearchableTerminalSurface(terminal: terminal, isFocused: activePaneID == id)
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
            }.overlay { Rectangle().strokeBorder(activePaneID == id ? model.themeColor(.focusRing) : .clear, lineWidth: 1).allowsHitTesting(false) }
        } else {
            model.terminalBackground
        }
    }

    private func divider(_ id: UUID, axis: SplitAxis, ratio: Double, size: CGSize) -> some View {
        model.themeColor(.surface)
            .overlay { Rectangle().fill(model.themeColor(.border)).frame(width: axis == .x ? 1 : nil, height: axis == .y ? 1 : nil).allowsHitTesting(false) }
            .frame(width: axis == .x ? CanvasDimensions.dividerThickness : nil,
                   height: axis == .y ? CanvasDimensions.dividerThickness : nil)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(id)).onChanged { value in
                if dragStartRatio == nil { dragStartRatio = ratio }
                updateDivider(id, axis: axis, size: size, translation: value.translation)
            }.onEnded { value in
                updateDivider(id, axis: axis, size: size, translation: value.translation)
                dragStartRatio = nil
            })
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
