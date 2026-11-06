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
        .background(model.themeColor(.sidebarBackground))
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
            Image(systemName: view.symbol).font(.system(size: 15))
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
            Image(systemName: view.symbol).accessibilityHidden(true)
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
/// Open and Resume, and every agent pane in every window with its state in words.
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
        .background(model.themeColor(.surface))
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
            Picker("Open agent in", selection: $model.agentPlacement) {
                Text("New Tab").tag(AppWorkspaceModel.AgentPlacement.tab)
                Text("Split Beside Pane").tag(AppWorkspaceModel.AgentPlacement.split)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            .help("Where Open starts the agent; ⌥-click Open for the other")
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
            Button(missing ? "Install…" : "Open") { launch(agent.id, resume: false) }
                .controlSize(.small).help(missing ? "Offer \(agent.name)'s installer" : "Open \(agent.name) (⌥-click for the other placement)")
                .accessibilityLabel(missing ? "Install \(agent.name)" : "Open \(agent.name)")
            if !agent.resumeArguments.isEmpty {
                Button {
                    launch(agent.id, resume: true)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .controlSize(.small).help("Resume \(agent.name)'s last conversation").accessibilityLabel("Resume \(agent.name)")
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
                    Text("\(row.windowName) · \(row.agent.name)").font(.caption2).foregroundStyle(model.themeColor(.mutedForeground)).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let state = row.state, state != .ready {
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
        .accessibilityLabel("\(row.agent.name), \(row.tabTitle), \(row.windowName)")
        .accessibilityValue(row.status).accessibilityHint("Shows this pane").accessibilityAddTraits(.isButton)
    }

    private func launch(_ id: String, resume: Bool) {
        let flip = NSEvent.modifierFlags.contains(.option)
        Task { await model.launchAgentFromSidebar(id, resume: resume, flipPlacement: flip) }
    }
}
