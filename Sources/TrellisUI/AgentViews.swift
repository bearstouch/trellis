import AppKit
import SwiftUI
import TrellisCore

/// An agent's icon (FR-AG09): its SF Symbol, its monogram, or its image drawn as a template, all in the given tint.
/// A missing or unusable image falls back to the default symbol; it never blocks anything.
struct AgentIconView: View {
    let icon: AgentIcon
    var directory: URL?
    var size: CGFloat = 10

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? fallbackSymbol : name).font(.system(size: size))
        case .monogram(let text):
            Text(text).font(.system(size: size + 1, weight: .bold, design: .rounded)).lineLimit(1).fixedSize()
        case .image(let file, let fullColor):
            // Built-in definitions read their images from the bundle; a user's from their Agents folder.
            if let image = AgentIconImages.load(file, directory: directory ?? AgentCatalog.bundledDirectory, template: !fullColor) {
                Image(nsImage: image).renderingMode(fullColor ? .original : .template).resizable().aspectRatio(contentMode: .fit).frame(width: size + 2, height: size + 2)
            } else {
                Image(systemName: fallbackSymbol).font(.system(size: size))
            }
        }
    }

    private var fallbackSymbol: String { if case .symbol(let name) = AgentIcon.fallback { name } else { "sparkles" } }
}

/// User and registry icons: SVG, PNG or PDF beside the definition, at most 32 KB. An SVG that could run script or load
/// anything outside itself is refused.
@MainActor
enum AgentIconImages {
    static let maximumBytes = 32_768
    private static var cache: [String: NSImage?] = [:]

    static func load(_ file: String, directory: URL?, template: Bool = true) -> NSImage? {
        guard let directory else { return nil }
        let url = directory.appendingPathComponent(file)
        let key = (template ? "t:" : "c:") + url.path
        if let cached = cache[key] { return cached }
        let image = read(url, template: template)
        cache[key] = image
        return image
    }

    /// A reloaded catalog reads icon files again.
    static func clear() { cache = [:] }

    private static func read(_ url: URL, template: Bool) -> NSImage? {
        guard let data = try? DiskThemeLibraryFiles().read(url), data.count <= maximumBytes else { return nil }
        if url.pathExtension == "svg" {
            let text = String(decoding: data, as: UTF8.self).lowercased()
            guard !["<script", "foreignobject", "javascript:", "href=\"http", "href='http", "href=\"file", "href='file", "<!entity", "@import", "url(http", "url(file"].contains(where: text.contains) else { return nil }
        }
        guard let image = NSImage(data: data) else { return nil }
        image.isTemplate = template
        return image
    }
}

/// A spinning ring for a tab printing output, or a working agent, in sidebar lists. Shape and motion, not color, carry it;
/// "Busy" is its tooltip and what VoiceOver reads. With Reduce Motion it holds still.
struct BusyLabel: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A timeline rather than a repeating animation: inside lists, that one also animates the row's layout changes.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let turn = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            ZStack {
                Circle().stroke(color.opacity(0.25), lineWidth: 1.5)
                Circle().trim(from: 0, to: 0.3).stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
            }
        }
        .frame(width: 11, height: 11).padding(1)
        .help(L("Busy"))
        .accessibilityElement().accessibilityLabel(L("Busy"))
    }
}

enum AgentStateStyle {
    static func color(_ state: AgentState) -> Color {
        switch state {
        case .ready: .secondary
        case .working: .blue
        case .needsInput: .orange
        case .done: .green
        case .error: .red
        }
    }

    static func symbol(_ state: AgentState) -> String {
        switch state {
        case .ready: "circle"
        case .working: "circle.dotted"
        case .needsInput: "hand.raised.fill"
        case .done: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}

/// Which capsule a tab shows (FR-AG10). Working has none, and still outranks the generic Input capsule.
enum TabCapsuleKind: Equatable {
    case agent(AgentState), input

    static func resolve(agentState: AgentState?, waitingForInput: Bool) -> TabCapsuleKind? {
        if let agentState { return agentState == .working ? nil : .agent(agentState) }
        return waitingForInput ? .input : nil
    }
}

/// What a tab's top edge shows; only one at a time. Agents print constantly, so the thread stands in for their busy bar.
enum TabTopEdgeKind: Equatable {
    case progress, agentWorking, busy, label

    static func resolve(hasProgress: Bool, agentState: AgentState?, busy: Bool, hasLabel: Bool) -> TabTopEdgeKind? {
        if hasProgress { return .progress }
        if agentState == .working { return .agentWorking }
        if busy { return .busy }
        return hasLabel ? .label : nil
    }
}

/// A working agent's icon (FR-AG10): it breathes on the same 2.4 s cycle as the tab's thread. Only scales, so it suits symbols,
/// monograms and images alike; a steady halo with Reduce Motion on. Inserted only while working, so no animation lingers.
struct AgentBreathingMark<Content: View>: View {
    let tint: Color
    let animated: Bool
    @ViewBuilder let content: Content
    @State private var inhaled = false

    var body: some View {
        content
            .scaleEffect(animated && inhaled ? 1.14 : 1)
            .background {
                Circle().fill(RadialGradient(colors: [tint.opacity(0.6), tint.opacity(0)], center: .center, startRadius: 0, endRadius: 13))
                    .frame(width: 26, height: 26)
                    .scaleEffect(animated ? (inhaled ? 1.15 : 0.8) : 1)
                    .opacity(animated ? (inhaled ? 0.95 : 0.25) : 0.7)
                    .allowsHitTesting(false)
            }
            .onAppear { start(animated) }
            .onChange(of: animated) { _, next in start(next) }
    }

    private func start(_ animated: Bool) {
        inhaled = false
        guard animated else { return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { inhaled = true }
    }
}

/// The tab's capsule for an agent's state (FR-AG10): a word and a symbol, never color alone.
struct AgentTabBadge: View {
    let state: AgentState

    var body: some View {
        Label(state.label, systemImage: AgentStateStyle.symbol(state)).labelStyle(.titleAndIcon)
            .font(.system(size: 10, weight: .medium)).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(AgentStateStyle.color(state).opacity(0.18)))
            .overlay(Capsule().strokeBorder(AgentStateStyle.color(state).opacity(0.6), lineWidth: 1))
            .fixedSize().accessibilityHidden(true)
    }
}

/// FR-AG12: the agent wasn't found where it ran. Shows the machine, the vendor's command and what it needs; Install runs
/// it in the pane's login shell, visibly, then starts the agent.
struct AgentInstallSheet: View {
    @ObservedObject var model: AppWorkspaceModel
    let offer: AgentInstallOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(offer.afterInstall ? L("%1$@ still isn’t found on %2$@", offer.agent.name, offer.hostName) : L("Install %1$@ on %2$@?", offer.agent.name, offer.hostName))
                .font(.headline)
            Text(explanation).fixedSize(horizontal: false, vertical: true)
            if let recipe = offer.recipe {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Command that will run")).font(.subheadline.weight(.semibold))
                    Text(recipe.command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .accessibilityLabel(L("Command: %@", recipe.command))
                    if !recipe.requires.isEmpty {
                        Text(L("Needs %@ on the PATH.", recipe.requires.joined(separator: ", "))).font(.callout).foregroundStyle(.secondary)
                    }
                    if !offer.missingRequirements.isEmpty {
                        Label(L("Not found on this Mac: %@. Install it first.", offer.missingRequirements.joined(separator: ", ")), systemImage: "exclamationmark.triangle")
                            .font(.callout)
                    }
                }
            }
            HStack {
                if let homepage = offer.agent.homepage, let url = URL(string: homepage) { Link(L("About %@", offer.agent.name), destination: url) }
                Spacer()
                Button(L("Cancel"), role: .cancel) { model.agentInstallOffer = nil }.keyboardShortcut(.cancelAction)
                if offer.recipe != nil {
                    Button(offer.afterInstall ? L("Run Installer Again") : L("Install and Launch")) { Task { await model.installAgent(offer) } }
                        .keyboardShortcut(.defaultAction).disabled(!offer.missingRequirements.isEmpty)
                }
            }
        }
        .padding(20).frame(width: 520)
    }

    private var explanation: String {
        if offer.afterInstall {
            return L("The installer finished, but your login shell still can’t find %@. Check the installer’s output in the pane; you may need to add its folder to your PATH.", offer.agent.executable)
        }
        guard offer.recipe != nil else {
            return L("%@ isn’t on the PATH of your login shell there, and this agent has no installer for that system. Install it yourself, then choose Restart in the pane.", offer.agent.executable)
        }
        return L("%@ isn’t on the PATH of your login shell there. Trellis can run the vendor’s installer in this pane, as you, without sudo; you’ll see its output and any sign-in prompt.", offer.agent.executable)
    }
}

/// Settings → Agents (FR-AG02): every agent the Agents view offers, where it comes from, how it reports its state,
/// whether this Mac has it, and files in the Agents folder that couldn't be used.
struct AgentSettingsView: View {
    @ObservedObject var model: AppWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(L("Reveal Agents Folder")) { model.revealAgentsFolder() }.disabled(model.agentsDirectory == nil)
                Button(L("Reload")) {
                    model.reloadAgentCatalog()
                    model.refreshAgentAvailability()
                }
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text(L("Agent")); Text(L("Source")); Text(L("Live status")); Text(L("This Mac"))
                }.font(.caption.weight(.semibold)).foregroundStyle(model.themeColor(.mutedForeground))
                ForEach(model.agentCatalog.definitions) { agent in
                    GridRow {
                        HStack(spacing: 6) {
                            AgentIconView(icon: agent.icon, directory: model.agentCatalog.iconDirectories[agent.id], size: 12).accessibilityHidden(true)
                            Text(agent.name).fontWeight(.medium)
                        }
                        Text(agent.isBuiltIn ? L("Built-in") : L("Agents folder"))
                        Text(agent.integration.displayName)
                        Text(availability(agent))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if !model.agentCatalog.issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Files that couldn’t be used")).font(.subheadline.weight(.semibold))
                    ForEach(model.agentCatalog.issues, id: \.filename) { issue in
                        Label("\(issue.filename): \(issue.message)", systemImage: "exclamationmark.triangle").font(.callout).wrappingSettingsCaption()
                    }
                }
            }
            Toggle(L("Notify me when an agent needs me or finishes while its pane is out of view"), isOn: $model.agentNotificationsEnabled)
            Toggle(L("Connect agents typed in a shell"), isOn: $model.typedAgentWiringEnabled)
            Text(
                L(
                    "Typing an agent’s command in a zsh, bash or fish pane on this Mac runs it with the same hooks, so it shows its state and is listed under Running. Your own function or alias of the same name wins, and “command <agent>” runs it without hooks. Applies to shells started after the change."
                )
            )
            .font(.callout).foregroundStyle(model.themeColor(.mutedForeground)).wrappingSettingsCaption()
            Text(
                L(
                    "Trellis wires each agent’s own hooks at launch, without changing your agent settings. A hook can only set its own pane’s state; it gets no automation access, and nothing from the conversation reaches Trellis. Add an agent by dropping a <id>.agent.json file in the Agents folder."
                )
            )
            .font(.callout).foregroundStyle(model.themeColor(.mutedForeground)).wrappingSettingsCaption()
        }
        // Not a Form, which insets itself: line up with the section title and divider like the other sections.
        .padding(.top, 8).padding(.leading, 16)
        .onAppear { model.refreshAgentAvailability() }
    }

    private func availability(_ agent: AgentDefinition) -> String {
        switch model.agentAvailability[agent.id] {
        case .installed?: L("Installed")
        case .missing?: L("Not found on PATH")
        case .checking?: L("Checking…")
        case nil: L("Unknown")
        }
    }
}
