import SwiftUI
import TrellisCore

/// The words for usage meters (FR-AG22).
enum AgentUsageText {
    static func title(_ kind: AgentUsageWindowKind) -> String {
        switch kind {
        case .session: L("Session")
        case .weekly: L("Weekly")
        case .monthly: L("Monthly")
        case .span(let minutes): minutes % 1440 == 0 ? L("%d-day window", minutes / 1440) : L("%d-hour window", max(1, minutes / 60))
        case .scoped(let model): L("%@ weekly", model)
        }
    }

    /// "Resets in 2 h 10 min" within a day, else the weekday and time, else the date.
    static func resets(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return L("Resetting now") }
        if seconds < 86_400 {
            let minutes = Int((seconds / 60).rounded(.up)), hours = minutes / 60
            return hours > 0 ? L("Resets in %1$d h %2$d min", hours, minutes % 60) : L("Resets in %d min", minutes)
        }
        let when = seconds < 7 * 86_400 ? date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) : date.formatted(.dateTime.month(.abbreviated).day())
        return L("Resets %@", when)
    }

    static func updated(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return L("Updated just now") }
        if minutes < 60 { return L("Updated %d min ago", minutes) }
        return L("Updated %@", date.formatted(date: Calendar.current.isDate(date, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened))
    }

    static func problem(_ problem: AgentUsageProblem, agent: String, stale: Bool) -> String {
        switch problem {
        case .notInstalled: L("%@ isn’t installed on this Mac.", agent)
        case .notSignedIn: L("Sign in to %@ to see its usage.", agent)
        case .signInExpired: L("Open %@ to refresh its sign-in. Trellis never signs in for it.", agent)
        case .noPlanLimits: L("No plan limits: %@ is signed in with an API key or a plan without limits.", agent)
        case .rateLimited: L("The usage service asked to wait. Trying again in 15 minutes.")
        case .failed: stale ? L("Couldn’t refresh. Trying again in 5 minutes.") : L("Couldn’t load usage. Trying again in 5 minutes.")
        }
    }
}

/// The Agents view's Usage section (FR-AG22): a card per opted-in agent, below Running.
struct AgentUsageSection: View {
    @ObservedObject var model: AppWorkspaceModel
    let agents: [AgentDefinition]

    var body: some View {
        let muted = model.themeColor(.mutedForeground)
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(L("Usage")).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 4)
                    if let updated = agents.compactMap({ model.agentUsage[$0.id]?.snapshot?.fetchedAt }).max() {
                        Text(AgentUsageText.updated(updated, now: context.date)).font(.caption2).foregroundStyle(muted).lineLimit(1)
                    }
                    if model.agentUsageRefreshing {
                        ProgressView().controlSize(.mini).accessibilityLabel(L("Refreshing usage"))
                    } else {
                        Button {
                            Task { await model.refreshAgentUsage(force: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11))
                        }
                        .buttonStyle(.borderless).foregroundStyle(muted).help(L("Refresh usage")).accessibilityLabel(L("Refresh usage"))
                    }
                }
                let colors = AgentUsageColors(model)
                ForEach(agents) { agent in AgentUsageCard(model: model, colors: colors, agent: agent, status: model.agentUsage[agent.id], now: context.date) }
            }
        }
    }
}

struct AgentUsageCard: View {
    /// Not observed: the section observes the model and redraws its cards.
    let model: AppWorkspaceModel
    let colors: AgentUsageColors
    let agent: AgentDefinition
    let status: AgentUsageStatus?
    let now: Date

    var body: some View {
        let muted = colors.muted
        let snapshot = status?.snapshot
        let problem: AgentUsageProblem? = if case .unavailable(let problem, _) = status { problem } else { nil }
        let stale = problem != nil && snapshot != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentTileIcon(agent: agent, directory: model.agentCatalog.iconDirectories[agent.id], side: 20).accessibilityHidden(true)
                Text(agent.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if stale { chip(L("Stale"), color: colors.warning) }
                if let plan = snapshot?.plan { chip(plan, color: muted) }
            }
            .accessibilityElement(children: .combine)
            if let snapshot {
                ForEach(Array(snapshot.windows.enumerated()), id: \.offset) { _, window in
                    if window.kind.isScoped {
                        AgentUsageScopedLine(colors: colors, agentName: agent.name, window: window, now: now, stale: stale)
                    } else {
                        AgentUsageMeter(colors: colors, agentName: agent.name, window: window, now: now, stale: stale)
                    }
                }
            } else if problem == nil {
                Text(L("Loading…")).font(.caption).foregroundStyle(muted)
            }
            if let problem {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if !stale { Image(systemName: "exclamationmark.triangle").foregroundStyle(colors.warning).accessibilityHidden(true) }
                    Text(AgentUsageText.problem(problem, agent: agent.name, stale: stale)).font(.caption2).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
                // Usage is this Mac's sign-in, so the agent opens only for a pane on this Mac.
                if problem == .signInExpired || problem == .notSignedIn, model.agentUsageCanOpenLocally {
                    Button(L("Open %@", agent.name)) { Task { await model.launchAgentFromSidebar(agent.id, resume: false) } }.controlSize(.small)
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(muted.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(muted.opacity(0.18), lineWidth: 1))
        .accessibilityElement(children: .contain).accessibilityLabel(L("%@ usage", agent.name))
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).lineLimit(1).fixedSize().foregroundStyle(color).padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.14)))
    }
}

/// The theme colors a meter needs, passed as values so meters don't redraw with every model change.
struct AgentUsageColors {
    let muted, accent, warning, error: Color

    @MainActor init(_ model: AppWorkspaceModel) {
        muted = model.themeColor(.mutedForeground); accent = model.themeColor(.accent); warning = model.themeColor(.warning); error = model.themeColor(.error)
    }

    /// Accent, then warning from 80% and error from 95%; the percentage is always written beside it.
    func tint(_ level: AgentUsageWindow.Level) -> Color {
        switch level {
        case .normal: accent
        case .high: warning
        case .critical: error
        }
    }
}

struct AgentUsageMeter: View {
    let colors: AgentUsageColors
    let agentName: String
    let window: AgentUsageWindow
    let now: Date
    let stale: Bool

    var body: some View {
        let muted = colors.muted
        let title = AgentUsageText.title(window.kind), resets = AgentUsageText.resets(window.resetsAt, now: now)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(muted)
                Spacer(minLength: 4)
                Text(window.usedPercent / 100, format: .percent.precision(.fractionLength(0))).font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            AgentUsageBar(fraction: window.usedPercent / 100, tint: colors.tint(window.level), track: muted.opacity(0.22), height: 5)
            if let resets { Text(resets).font(.caption2).foregroundStyle(muted).lineLimit(1) }
        }
        .opacity(stale ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("%1$@ usage: %2$@", agentName, title))
        .accessibilityValue(([L("%d percent", Int(window.usedPercent.rounded()))] + [resets, stale ? L("Stale") : nil].compactMap { $0 }).joined(separator: ", "))
    }
}

/// A model's own weekly limit: one small line under the main meters.
struct AgentUsageScopedLine: View {
    let colors: AgentUsageColors
    let agentName: String
    let window: AgentUsageWindow
    let now: Date
    let stale: Bool

    var body: some View {
        let muted = colors.muted
        let title = AgentUsageText.title(window.kind), resets = AgentUsageText.resets(window.resetsAt, now: now)
        HStack(spacing: 6) {
            Text(title).font(.caption2).foregroundStyle(muted).lineLimit(1)
            Spacer(minLength: 4)
            AgentUsageBar(fraction: window.usedPercent / 100, tint: colors.tint(window.level).opacity(0.8), track: muted.opacity(0.22), height: 3).frame(width: 64)
            Text(window.usedPercent / 100, format: .percent.precision(.fractionLength(0))).font(.caption2).monospacedDigit().frame(minWidth: 30, alignment: .trailing)
        }
        .opacity(stale ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("%1$@ usage: %2$@", agentName, title))
        .accessibilityValue(([L("%d percent", Int(window.usedPercent.rounded()))] + [resets, stale ? L("Stale") : nil].compactMap { $0 }).joined(separator: ", "))
    }
}

struct AgentUsageBar: View {
    let fraction: Double
    let tint: Color
    let track: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint).frame(width: max(fraction > 0 ? height : 0, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height).accessibilityHidden(true)
    }
}
