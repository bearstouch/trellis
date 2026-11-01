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
        case .image(let file):
            if let image = AgentIconImages.load(file, directory: directory) {
                Image(nsImage: image).renderingMode(.template).resizable().aspectRatio(contentMode: .fit).frame(width: size + 2, height: size + 2)
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

    static func load(_ file: String, directory: URL?) -> NSImage? {
        guard let directory else { return nil }
        let url = directory.appendingPathComponent(file)
        if let cached = cache[url.path] { return cached }
        let image = read(url)
        cache[url.path] = image
        return image
    }

    /// A reloaded catalog reads icon files again.
    static func clear() { cache = [:] }

    private static func read(_ url: URL) -> NSImage? {
        guard let data = try? DiskThemeLibraryFiles().read(url), data.count <= maximumBytes else { return nil }
        if url.pathExtension == "svg" {
            let text = String(decoding: data, as: UTF8.self).lowercased()
            guard !["<script", "foreignobject", "javascript:", "href=\"http", "href='http", "href=\"file", "href='file", "<!entity", "@import", "url(http", "url(file"].contains(where: text.contains) else { return nil }
        }
        guard let image = NSImage(data: data) else { return nil }
        image.isTemplate = true
        return image
    }
}

/// FR-AG07: launches an agent in a new tab, in this pane's directory and on its host. ⌥ opens it in a split beside the pane.
struct AgentDropdownButton: View {
    @ObservedObject var model: AppWorkspaceModel
    let paneID: UUID

    var body: some View {
        Menu {
            Section("Open in a New Tab (⌥ Beside This Pane)") {
                ForEach(model.agentCatalog.definitions) { agent in
                    Button {
                        launch(agent.id, resume: false)
                    } label: {
                        Label(title(agent), systemImage: symbol(agent))
                    }
                }
            }
            Menu("Resume Last Conversation") {
                ForEach(model.agentCatalog.definitions.filter { !$0.resumeArguments.isEmpty }) { agent in
                    Button(agent.name) { launch(agent.id, resume: true) }
                }
            }
            Divider()
            Button("Add Agent Definition…") { model.revealAgentsFolder() }.disabled(model.agentsDirectory == nil)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                Text("Agent").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).accessibilityHidden(true)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
        }
        // Plain, like the Tasks button beside it, so it takes the header's font and color.
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Launch a coding agent in a new tab (⌥ beside this pane)")
        .accessibilityLabel("Launch agent")
        .onAppear { if !model.isRemoteWorkspace(paneID: paneID) { model.refreshAgentAvailability() } }
    }

    private func launch(_ id: String, resume: Bool) {
        let placement: AppWorkspaceModel.AgentPlacement = NSEvent.modifierFlags.contains(.option) ? .split : .tab
        Task { await model.launchAgent(id, from: paneID, placement: placement, resume: resume) }
    }

    /// Install status for the machine this pane runs on, in words (FR-AG07).
    private func title(_ agent: AgentDefinition) -> String {
        if model.isRemoteWorkspace(paneID: paneID) {
            let host = model.snapshot.panes[paneID].flatMap { model.snapshot.sessions[$0.sessionID]?.launch.remoteHostID }
            return host.flatMap { model.remoteMissingAgents[$0]?.contains(agent.id) == true ? "\(agent.name) — not installed there, Install…" : nil } ?? agent.name
        }
        switch model.agentAvailability[agent.id] {
        case .missing?: return "\(agent.name) — not installed, Install…"
        case .checking?: return "\(agent.name) — checking…"
        default: return agent.name
        }
    }

    /// Menus show SF Symbols only; a monogram or image agent gets the default symbol here.
    private func symbol(_ agent: AgentDefinition) -> String {
        if case .symbol(let name) = agent.icon, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil { return name }
        return "sparkles"
    }
}

/// The agent's state in the pane header (FR-AG10), as words plus a symbol. A nil state is an agent typed in a shell
/// (FR-AG15): its state is unknown, so only its name is claimed.
struct AgentStateLabel: View {
    let agent: AgentDefinition
    let state: AgentState?
    var directory: URL?
    /// A narrow pane's typed agent (FR-AG15): the automatic title already names it, and the header's tools can't shrink.
    var iconOnly = false

    static func fitsName(paneWidth: CGFloat) -> Bool { paneWidth >= 640 }

    var body: some View {
        let shown = state ?? .ready
        HStack(spacing: 4) {
            AgentIconView(icon: agent.icon, directory: directory)
            if !iconOnly { Text(shown == .ready ? agent.name : "\(agent.name) · \(shown.label)").lineLimit(1) }
        }
        .help(iconOnly ? agent.name : "")
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(Capsule().fill(AgentStateStyle.color(shown).opacity(shown == .ready ? 0 : 0.18)))
        .overlay(Capsule().strokeBorder(AgentStateStyle.color(shown).opacity(shown == .ready ? 0 : 0.6), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.map { "\(agent.name) \($0.spokenText)" } ?? agent.name)
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
            Text(offer.afterInstall ? "\(offer.agent.name) still isn’t found on \(offer.hostName)" : "Install \(offer.agent.name) on \(offer.hostName)?")
                .font(.headline)
            Text(explanation).fixedSize(horizontal: false, vertical: true)
            if let recipe = offer.recipe {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command that will run").font(.subheadline.weight(.semibold))
                    Text(recipe.command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .accessibilityLabel("Command: \(recipe.command)")
                    if !recipe.requires.isEmpty {
                        Text("Needs \(recipe.requires.joined(separator: ", ")) on the PATH.").font(.callout).foregroundStyle(.secondary)
                    }
                    if !offer.missingRequirements.isEmpty {
                        Label("Not found on this Mac: \(offer.missingRequirements.joined(separator: ", ")). Install it first.", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                    }
                }
            }
            HStack {
                if let homepage = offer.agent.homepage, let url = URL(string: homepage) { Link("About \(offer.agent.name)", destination: url) }
                Spacer()
                Button("Cancel", role: .cancel) { model.agentInstallOffer = nil }.keyboardShortcut(.cancelAction)
                if offer.recipe != nil {
                    Button(offer.afterInstall ? "Run Installer Again" : "Install and Launch") { Task { await model.installAgent(offer) } }
                        .keyboardShortcut(.defaultAction).disabled(!offer.missingRequirements.isEmpty)
                }
            }
        }
        .padding(20).frame(width: 520)
    }

    private var explanation: String {
        if offer.afterInstall {
            return "The installer finished, but your login shell still can’t find \(offer.agent.executable). Check the installer’s output in the pane; you may need to add its folder to your PATH."
        }
        guard offer.recipe != nil else {
            return "\(offer.agent.executable) isn’t on the PATH of your login shell there, and this agent has no installer for that system. Install it yourself, then choose Restart in the pane."
        }
        return "\(offer.agent.executable) isn’t on the PATH of your login shell there. Trellis can run the vendor’s installer in this pane, as you, without sudo; you’ll see its output and any sign-in prompt."
    }
}

/// Settings → Agents (FR-AG02): every agent the Agent button offers, where it comes from, how it reports its state,
/// whether this Mac has it, and files in the Agents folder that couldn't be used.
struct AgentSettingsView: View {
    @ObservedObject var model: AppWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Reveal Agents Folder") { model.revealAgentsFolder() }.disabled(model.agentsDirectory == nil)
                Button("Reload") {
                    model.reloadAgentCatalog()
                    model.refreshAgentAvailability()
                }
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("Agent"); Text("Source"); Text("Live status"); Text("This Mac")
                }.font(.caption.weight(.semibold)).foregroundStyle(model.themeColor(.mutedForeground))
                ForEach(model.agentCatalog.definitions) { agent in
                    GridRow {
                        HStack(spacing: 6) {
                            AgentIconView(icon: agent.icon, directory: model.agentCatalog.iconDirectories[agent.id], size: 12).accessibilityHidden(true)
                            Text(agent.name).fontWeight(.medium)
                        }
                        Text(agent.isBuiltIn ? "Built-in" : "Agents folder")
                        Text(agent.integration.displayName)
                        Text(availability(agent))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if !model.agentCatalog.issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Files that couldn’t be used").font(.subheadline.weight(.semibold))
                    ForEach(model.agentCatalog.issues, id: \.filename) { issue in
                        Label("\(issue.filename): \(issue.message)", systemImage: "exclamationmark.triangle").font(.callout).wrappingSettingsCaption()
                    }
                }
            }
            Toggle("Notify me when an agent needs me or finishes while its pane is out of view", isOn: $model.agentNotificationsEnabled)
            Text(
                "Trellis wires each agent’s own hooks at launch, without changing your agent settings. A hook can only set its own pane’s state; it gets no automation access, and nothing from the conversation reaches Trellis. Add an agent by dropping a <id>.agent.json file in the Agents folder."
            )
            .font(.callout).foregroundStyle(model.themeColor(.mutedForeground)).wrappingSettingsCaption()
        }
        // Not a Form, which insets itself: line up with the section title and divider like the other sections.
        .padding(.top, 8).padding(.leading, 16)
        .onAppear { model.refreshAgentAvailability() }
    }

    private func availability(_ agent: AgentDefinition) -> String {
        switch model.agentAvailability[agent.id] {
        case .installed?: "Installed"
        case .missing?: "Not found on PATH"
        case .checking?: "Checking…"
        case nil: "Unknown"
        }
    }
}
