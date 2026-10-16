import SwiftUI
import UTermCore

struct PaneTreeView: View {
    @ObservedObject var model: AppWorkspaceModel
    let layout: PaneLayout
    let activePaneID: UUID

    var body: some View {
        GeometryReader { geometry in
            switch layout {
            case .pane(let id): leaf(id, size: geometry.size)
            case .split(_, let axis, let ratio, let children):
                if children.count == 2 {
                    if axis == .x {
                        HStack(spacing: 1) {
                            PaneTreeView(model: model, layout: children[0], activePaneID: activePaneID)
                                .frame(width: max(0, geometry.size.width - 1) * ratio)
                            PaneTreeView(model: model, layout: children[1], activePaneID: activePaneID)
                        }
                    } else {
                        VStack(spacing: 1) {
                            PaneTreeView(model: model, layout: children[0], activePaneID: activePaneID)
                                .frame(height: max(0, geometry.size.height - 1) * ratio)
                            PaneTreeView(model: model, layout: children[1], activePaneID: activePaneID)
                        }
                    }
                }
            }
        }.background(Color(nsColor: .separatorColor))
    }

    @ViewBuilder private func leaf(_ id: UUID, size: CGSize) -> some View {
        if let terminal = model.terminals[id] {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button(model.snapshot.panes[id]?.title ?? "Terminal") { Task { await model.selectPane(id) } }
                        .buttonStyle(.plain).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { split(id, axis: .x, size: size) } label: { Image(systemName: "rectangle.split.2x1") }
                        .help("Split Left/Right").accessibilityLabel("Split Left/Right")
                    Button { split(id, axis: .y, size: size) } label: { Image(systemName: "rectangle.split.1x2") }
                        .help("Split Top/Bottom").accessibilityLabel("Split Top/Bottom")
                    Button { Task { await model.closePane(id) } } label: { Image(systemName: "xmark") }
                        .help("Close Pane").accessibilityLabel("Close Pane")
                }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 9).frame(height: 26).background(Color(nsColor: .windowBackgroundColor))
                NativeTerminalSurface(terminal: terminal, isFocused: activePaneID == id)
                    .overlay {
                        if terminal.sessionState == .stopped {
                            Button("Start Session") { Task { await model.start(paneID: id) } }.buttonStyle(.borderedProminent)
                        }
                    }
            }.overlay { Rectangle().strokeBorder(activePaneID == id ? Color.accentColor.opacity(0.65) : .clear, lineWidth: 1) }
        } else {
            Color(red: 0.082, green: 0.09, blue: 0.098)
        }
    }

    private func split(_ id: UUID, axis: SplitAxis, size: CGSize) {
        Task { await model.splitPane(id, axis: axis, availableCanvas: CanvasDimensions(width: size.width, height: size.height)) }
    }
}
