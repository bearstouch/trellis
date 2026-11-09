import AppKit
import SwiftUI
import TrellisCore

/// The dock on the window's right edge (FR-SB01): one icon per sidebar view, the shown one marked by an accent bar and the
/// selected trait, views the focused pane can't use dimmed with the reason, and counts in text badges (FR-SB05).
struct SidebarDock: View {
    @ObservedObject var model: AppWorkspaceModel

    var body: some View {
        VStack(spacing: 2) {
            ForEach(SidebarView.allCases, id: \.self) { view in icon(view) }
            Spacer(minLength: 0)
        }
        .padding(.top, 6).frame(width: 40).frame(maxHeight: .infinity)
        .background(model.chromeFill(.sidebarBackground))
        .overlay(alignment: .leading) { model.themeColor(.border).frame(width: 1).accessibilityHidden(true) }
        .accessibilityElement(children: .contain).accessibilityLabel("Sidebar views")
    }

    private func icon(_ view: SidebarView) -> some View {
        let shown = model.visibleSidebarView == view
        let reason = model.sidebarUnavailableReason(view)
        let badge = badge(view)
        let title = shown ? "Hide \(view.title)" : view.title
        return Button {
            model.toggleSidebarView(view)
        } label: {
            SidebarViewIcon(view: view, size: 15)
                .foregroundStyle(reason != nil ? model.themeColor(.mutedForeground).opacity(0.35) : shown ? model.themeColor(.foreground) : model.themeColor(.mutedForeground))
                .frame(width: 40, height: 38)
                .overlay(alignment: .leading) {
                    if shown { model.themeColor(.accent).frame(width: 2, height: 22).clipShape(Capsule()).accessibilityHidden(true) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let badge { badgeView(badge.count, tint: badge.tint, foreground: badge.foreground).padding(.trailing, 5).padding(.bottom, 4) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reason != nil)
        .help(reason ?? model.keyboard.shortcuts[view.shortcut].map { "\(title) (\($0))" } ?? title)
        .accessibilityLabel(view.title)
        .accessibilityValue(badge?.spoken ?? "")
        .accessibilityHint(reason ?? "")
        .accessibilityAddTraits(shown ? [.isSelected] : [])
    }

    private func badge(_ view: SidebarView) -> (count: Int, spoken: String, tint: Color, foreground: Color)? {
        switch view {
        case .files, .scratchpad: return nil
        case .changes:
            let count = model.changedFileCount
            return count > 0 ? (count, "\(count) changed", model.themeColor(.accent), model.accentForeground) : nil
        case .tasks:
            let count = model.activeTaskCount
            return count > 0 ? (count, "\(count) running", model.themeColor(.accent), model.accentForeground) : nil
        case .agents:
            let count = model.agentsNeedingYouCount
            return count > 0 ? (count, "\(count) needs you", model.themeColor(.warning), .black) : nil
        }
    }

    private func badgeView(_ count: Int, tint: Color, foreground: Color) -> some View {
        Text(count > 99 ? "99+" : "\(count)").font(.system(size: 9, weight: .bold)).monospacedDigit().foregroundStyle(foreground)
            .padding(.horizontal, 3).frame(minWidth: 14, minHeight: 14).background(Capsule().fill(tint)).fixedSize().accessibilityHidden(true)
    }
}

/// The shown view of the right sidebar (FR-SB02), for the focused pane.
struct RightSidebarPanel: View {
    @ObservedObject var model: AppWorkspaceModel
    let view: SidebarView

    var body: some View {
        switch view {
        case .files:
            if let paneID = model.presentation.activePane?.id { FilesSidebarView(model: model, paneID: paneID) }
        case .changes:
            if let paneID = model.presentation.activePane?.id { ChangesSidebarView(model: model, paneID: paneID) }
        case .scratchpad: ScratchpadPanel(model: model, buffer: model.scratchpadBuffer)
        case .tasks:
            if let paneID = model.presentation.activePane?.id { TasksSidebarView(model: model, paneID: paneID) }
        case .agents: AgentsSidebarView(model: model)
        }
    }
}

/// A sidebar view's title row: its name, its own buttons, then Close.
struct SidebarHeader<Accessory: View>: View {
    @ObservedObject var model: AppWorkspaceModel
    let view: SidebarView
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            SidebarViewIcon(view: view, size: 12).accessibilityHidden(true)
            Text(view.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(model.themeColor(.foreground)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            accessory
            Button {
                model.closeSidebar()
            } label: {
                Image(systemName: "xmark")
            }
            .help(closeHelp)
            .accessibilityLabel("Close \(view.title)")
        }
        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(model.themeColor(.mutedForeground))
        .padding(.leading, 12).padding(.trailing, 10).frame(height: 40)
    }

    private var closeHelp: String { model.keyboard.shortcuts[view.shortcut].map { "Close \(view.title) (\($0))" } ?? "Close \(view.title)" }
}

/// The sidebar's Agents view (FR-AG07, FR-AG16): where agents open for the focused pane, each agent with its status and
/// Open and Resume, and every agent pane in every space with its state in words.
struct AgentsSidebarView: View {
    @ObservedObject var model: AppWorkspaceModel

    var body: some View {
        let muted = model.themeColor(.mutedForeground)
        VStack(spacing: 0) {
            SidebarHeader(model: model, view: .agents) { EmptyView() }
            Divider().overlay(model.separatorOverlay)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    target
                    Text("Launch").font(.subheadline.weight(.semibold)).padding(.top, 4)
                    ForEach(model.agentCatalog.definitions) { agent in launchRow(agent) }
                    Divider().padding(.vertical, 2)
                    Text("Running").font(.subheadline.weight(.semibold))
                    let rows = model.agentSessionRows
                    if rows.isEmpty { Text("No agents are open.").font(.caption).foregroundStyle(muted) }
                    ForEach(rows) { row in runningRow(row) }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(model.separatorOverlay)
            HStack {
                Button("Add Agent Definition…") { model.revealAgentsFolder() }.disabled(model.agentsDirectory == nil)
                Spacer()
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(model.chromeFill(.surface))
        .accessibilityElement(children: .contain).accessibilityLabel("Agents")
        // The install status is for the focused pane's machine; a host's is learned when a launch finds it missing.
        .task(id: model.presentation.activePane?.id) {
            if let pane = model.presentation.activePane?.id, !model.isRemoteWorkspace(paneID: pane) { model.refreshAgentAvailability() }
        }
    }

    @ViewBuilder private var target: some View {
        let muted = model.themeColor(.mutedForeground)
        VStack(alignment: .leading, spacing: 6) {
            Text("Opens in").font(.caption).foregroundStyle(muted)
            if let target = model.agentTarget {
                HStack(spacing: 6) {
                    Image(systemName: "folder").accessibilityHidden(true)
                    Text(target.directory ?? "Home folder").font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    Text("· \(target.machine)").font(.system(size: 12)).foregroundStyle(muted).lineLimit(1).fixedSize()
                }.accessibilityElement(children: .combine)
            }
            // This Tab (FR-AG17) only while the focused tab has no agent; New Tab stands in for it meanwhile.
            let placement = Binding(get: { model.effectiveAgentPlacement }, set: { model.agentPlacement = $0 })
            Picker("Open agent in", selection: placement) {
                Text("New Tab").tag(AppWorkspaceModel.AgentPlacement.tab)
                if model.canLaunchAgentInFocusedTab { Text("This Tab").tag(AppWorkspaceModel.AgentPlacement.currentTab) }
                Text("Split").tag(AppWorkspaceModel.AgentPlacement.split)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            .help(
                "Where ▶ starts the agent: a new tab, this tab's focused pane in place of its idle shell, or a split beside it. ⌥-click ▶ for a split, or a new tab from Split")
        }
    }

    private func launchRow(_ agent: AgentDefinition) -> some View {
        let status = model.agentStatusText(agent)
        let missing = status?.hasPrefix("Not installed") == true
        return HStack(spacing: 10) {
            AgentIconView(icon: agent.icon, directory: model.agentCatalog.iconDirectories[agent.id], size: 13)
                .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 6).fill(model.themeColor(.accent).opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let status { Text(status).font(.caption2).foregroundStyle(model.themeColor(.mutedForeground)).lineLimit(1) }
            }.accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            Button {
                launch(agent.id, resume: false)
            } label: {
                // A missing agent keeps the word: a lone download icon wouldn't say an installer is offered.
                if missing { Text("Install…") } else { Image(systemName: "play.fill") }
            }
            .buttonStyle(.borderless).help(missing ? "Offer \(agent.name)'s installer" : "Open \(agent.name) (⌥-click for the other placement)")
            .accessibilityLabel(missing ? "Install \(agent.name)" : "Open \(agent.name)")
            if !agent.resumeArguments.isEmpty {
                Button {
                    launch(agent.id, resume: true)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless).help("Resume \(agent.name)'s last conversation").accessibilityLabel("Resume \(agent.name)")
            }
        }
    }

    private func runningRow(_ row: AgentSessionRow) -> some View {
        Button {
            Task { await model.revealPane(row.id) }
        } label: {
            HStack(spacing: 10) {
                AgentIconView(icon: row.agent.icon, directory: model.agentCatalog.iconDirectories[row.agent.id], size: 12).frame(width: 18).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.tabTitle).font(.system(size: 12)).lineLimit(1).foregroundStyle(model.themeColor(.foreground))
                    Text("\(row.spaceName) · \(row.agent.name)\(row.typed ? " · in a shell" : "")").font(.caption2).foregroundStyle(model.themeColor(.mutedForeground))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if row.state == .working {
                    BusyLabel(color: model.themeColor(.accent))
                } else if let state = row.state, state != .ready {
                    AgentTabBadge(state: state)
                } else {
                    Text(row.status).font(.caption).foregroundStyle(model.themeColor(.mutedForeground)).lineLimit(1)
                }
            }
            .padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show this agent's pane")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.agent.name)\(row.typed ? " in a shell" : ""), \(row.tabTitle), \(row.spaceName)")
        .accessibilityValue(row.status).accessibilityHint("Shows this pane").accessibilityAddTraits(.isButton)
    }

    private func launch(_ id: String, resume: Bool) {
        let flip = NSEvent.modifierFlags.contains(.option)
        Task { await model.launchAgentFromSidebar(id, resume: resume, flipPlacement: flip) }
    }
}

/// A dock view's icon: an SF Symbol, except Changes, whose git branch graph SF Symbols lacks (FR-GC01).
struct SidebarViewIcon: View {
    let view: SidebarView
    let size: CGFloat

    var body: some View {
        if view == .changes {
            GitBranchGlyph().stroke(style: StrokeStyle(lineWidth: max(1.2, size / 11), lineCap: .round)).frame(width: size, height: size)
        } else {
            Image(systemName: view.symbol).font(.system(size: size))
        }
    }
}

/// Two commits on a line and a branch curving into it, drawn in a 16-point box.
struct GitBranchGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 16
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale) }
        let radius = 2 * scale
        var path = Path()
        for (x, y) in [(4.5, 3.5), (4.5, 12.5), (11.5, 4.5)] as [(CGFloat, CGFloat)] {
            path.addEllipse(in: CGRect(x: rect.minX + x * scale - radius, y: rect.minY + y * scale - radius, width: radius * 2, height: radius * 2))
        }
        path.move(to: point(4.5, 5.5)); path.addLine(to: point(4.5, 10.5))
        path.move(to: point(11.5, 6.5)); path.addCurve(to: point(4.5, 10.5), control1: point(11.5, 9.5), control2: point(4.5, 8.5))
        return path
    }
}
