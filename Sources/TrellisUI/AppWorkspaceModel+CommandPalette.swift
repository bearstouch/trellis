import AppKit
import Foundation
import TrellisCore

/// A second Return-like key on a host row (FR-CP07).
public enum CommandPaletteModifier: Sendable { case none, command, option }

/// What a palette search depends on; the same inputs give the same sections.
struct CommandPaletteSearchKey: Equatable {
    let items: [CommandPaletteItem]
    let query: String
    let scope: CommandPaletteScope?
    let recents: [String]
}

/// The command palette (FR-CP01–FR-CP08): one searchable list of actions and places. Every row runs through the path
/// its menu item or control uses, so the palette adds no mutation of its own.
extension AppWorkspaceModel {
    public func toggleCommandPalette() { commandPaletteVisible ? closeCommandPalette() : openCommandPalette() }

    public func openCommandPalette() {
        guard !commandPaletteVisible, !welcomeTourVisible, !isRestoring, recoveryMessage == nil, !shuttingDown else { return }
        // Read now: some actions are enabled only while a terminal, not the palette's field, has focus.
        // Jump to Directory is listed as its scope, whose row only needs a remembered directory.
        commandPaletteActions = ShortcutAction.allCases.filter { $0 != .commandPalette && $0 != .jumpToDirectory && $0.tabIndex == nil && canPerformShortcutAction?($0) == true }
        commandPaletteOpenedAt = activityNow()
        // The scratchpad editor gets its focus back; a terminal's is the active pane's, which may change meanwhile.
        let focused = (activeTerminal?.view.window ?? NSApp.keyWindow)?.firstResponder as? NSView
        let isFieldEditor = (focused as? NSText)?.isFieldEditor ?? false
        commandPaletteReturnFocus = isFieldEditor || terminals.values.contains { $0.view === focused } ? nil : focused
        commandPaletteQuery = ""
        commandPaletteScope = nil
        commandPaletteVisible = true
        commandPaletteFocusRequest &+= 1
        terminals.values.forEach { $0.inputSuspended = true }
        // Opening is not moving the selection: a recent theme on top must not repaint the workspace (FR-CP08).
        commandPaletteSelection = commandPaletteSections.first?.matches.first?.item.id
        if let paneID = presentation.activePane?.id { Task { await refreshTaskCatalog(paneID: paneID) } }
    }

    /// Esc, the backdrop, the shortcut again, or a row that ran: focus goes back to what had it (the scratchpad
    /// editor), else to the (now) active pane.
    public func closeCommandPalette() {
        guard commandPaletteVisible else { return }
        commandPaletteSearchCache = nil
        endCommandPalettePreview()
        commandPaletteVisible = false
        commandPaletteSelection = nil
        terminals.values.forEach { $0.inputSuspended = terminalInputBlocked }
        let previous = commandPaletteReturnFocus
        commandPaletteReturnFocus = nil
        guard let previous, previous.window != nil else {
            // A tab rename's field editor isn't kept as `previous`, and terminals stay suspended until it ends.
            if editingTabID != nil { tabRenameFocusRequest &+= 1; return }
            return focusActiveTerminal()
        }
        let terminal = activeTerminal
        DispatchQueue.main.async {
            if let window = previous.window, !previous.isHiddenOrHasHiddenAncestor, window.makeFirstResponder(previous) { return }
            if let terminal { terminal.view.window?.makeFirstResponder(terminal.view) }
        }
    }

    public func setCommandPaletteQuery(_ query: String) {
        guard commandPaletteVisible, query != commandPaletteQuery else { return }
        commandPaletteQuery = query
        selectFirstCommandPaletteItem()
    }

    public func enterCommandPaletteScope(_ scope: CommandPaletteScope) {
        guard commandPaletteVisible else { return }
        commandPaletteScope = scope
        commandPaletteQuery = ""
        selectFirstCommandPaletteItem()
    }

    /// ⌫ in an empty field; false when there is no scope to leave, so the key edits the field as usual.
    @discardableResult public func leaveCommandPaletteScope() -> Bool {
        guard commandPaletteVisible, commandPaletteScope != nil, commandPaletteQuery.isEmpty else { return false }
        commandPaletteScope = nil
        selectFirstCommandPaletteItem()
        return true
    }

    /// Asked for several times per keystroke (selection, preview, the view), so the search runs once per input.
    public var commandPaletteSections: [CommandPaletteSection] {
        let key = CommandPaletteSearchKey(items: commandPaletteItems, query: commandPaletteQuery, scope: commandPaletteScope, recents: commandPaletteRecents.ids)
        if let cached = commandPaletteSearchCache, cached.key == key { return cached.sections }
        let sections = CommandPaletteSearch.sections(items: key.items, query: key.query, scope: key.scope, recents: key.recents)
        commandPaletteSearchCache = (key, sections)
        return sections
    }

    /// The highlighted row: the chosen one while it is still listed, else the first.
    public func commandPaletteSelectedMatch(in sections: [CommandPaletteSection]) -> CommandPaletteMatch? {
        let matches = sections.lazy.flatMap(\.matches)
        return matches.first { $0.item.id == commandPaletteSelection } ?? matches.first
    }

    public func selectCommandPaletteItem(_ id: String?) {
        guard commandPaletteVisible else { return }
        commandPaletteSelection = id
        updateCommandPalettePreview()
    }

    /// ↑/↓ and ⌃P/⌃N; wraps at both ends.
    public func moveCommandPaletteSelection(by offset: Int) {
        let sections = commandPaletteSections
        let ids = sections.flatMap { $0.matches.map(\.item.id) }
        guard !ids.isEmpty else { return }
        let current = commandPaletteSelectedMatch(in: sections).flatMap { ids.firstIndex(of: $0.item.id) } ?? 0
        selectCommandPaletteItem(ids[((current + offset) % ids.count + ids.count) % ids.count])
    }

    /// Return (or a click): a scope row enters its scope; any other row closes the palette and then runs.
    public func runCommandPaletteItem(_ id: String? = nil, modifier: CommandPaletteModifier = .none) {
        guard commandPaletteVisible else { return }
        // A clicked row that is no longer listed runs nothing, never the highlighted row instead.
        let picked = id.map { id in commandPaletteItems.first { $0.id == id } } ?? commandPaletteSelectedMatch(in: commandPaletteSections)?.item
        guard let item = picked else { return }
        if case .scope(let scope) = item.target {
            enterCommandPaletteScope(scope)
            return
        }
        commandPaletteRecents.record(item.id)
        closeCommandPalette()
        // After the focus change queued by closing, so an action that moves focus (Find, the scratchpad) keeps it.
        DispatchQueue.main.async { Task { await self.performCommandPaletteTarget(item.target, modifier: modifier) } }
    }

    func performCommandPaletteTarget(_ target: CommandPaletteTarget, modifier: CommandPaletteModifier) async {
        switch target {
        // Listed when the palette opened; the workspace may have changed since, so ask the menu again.
        case .action(let action): if canPerformShortcutAction?(action) ?? true { performShortcutAction?(action) }
        case .settings: openSettings?()
        case .welcomeTour: openWelcomeTour()
        case .scope: break
        case .space(let id):
            await selectSpace(id)
            focusActiveTerminal()
        case .tab(let spaceID, let tabID):
            await selectSpaceTab(spaceID: spaceID, tabID: tabID)
            focusActiveTerminal()
        case .pane(let id):
            await revealPane(id)
            focusActiveTerminal()
        case .host(let id):
            guard let host = commandPaletteHosts().first(where: { $0.id == id }) else { return }
            let placement: HostPlacement =
                switch modifier {
                case .none: .newTab
                case .command: .newSpace
                case .option: .split(.x)
                }
            await connect(host: host, placement: placement)
        case .remoteWorkspace(let id):
            guard let host = commandPaletteHosts().first(where: { $0.id == id }) else { return }
            await openRemoteWorkspace(host: host)
        case .project(let id):
            guard let project = commandPaletteProjects().first(where: { $0.id == id }) else { return }
            beginProjectLaunch(project)
        case .task(let name, let detected):
            guard let catalog = taskCatalog else { return }
            let task = detected ? catalog.detected.first { $0.task.name == name }?.task : catalog.tasks.first { $0.name == name }
            if let task { runTask(task, fromFile: !detected) }
        case .theme(let id): useTheme(id)
        case .agent(let id):
            guard let paneID = presentation.activePane?.id else { return }
            await launchAgent(id, from: paneID, placement: modifier == .option ? .split : .tab)
        case .directory(let machine, let path):
            await jumpToDirectory(path: path, machine: machine, modifier: modifier)
            focusActiveTerminal()
        }
    }

    private func selectFirstCommandPaletteItem() {
        selectCommandPaletteItem(commandPaletteSections.first?.matches.first?.item.id)
    }

    func focusActiveTerminal() {
        guard let terminal = activeTerminal else { return }
        DispatchQueue.main.async { terminal.view.window?.makeFirstResponder(terminal.view) }
    }

    // MARK: Theme preview (FR-CP08)

    private func updateCommandPalettePreview() {
        guard case .theme(let id)? = commandPaletteSelectedMatch(in: commandPaletteSections)?.item.target else {
            endCommandPalettePreview()
            return
        }
        // A preview that Settings started is the user's; the palette never replaces or cancels it.
        guard commandPalettePreviewing || previewedTheme == nil, let theme = allThemes.first(where: { $0.id == id }),
            let document = try? ThemeValidator.validate(theme.encoded())
        else { return }
        previewThemeInWorkspace(document)
        commandPalettePreviewing = previewedTheme != nil
    }

    private func endCommandPalettePreview() {
        guard commandPalettePreviewing else { return }
        commandPalettePreviewing = false
        cancelThemePreview()
    }

    // MARK: Items (FR-CP03)

    var commandPaletteItems: [CommandPaletteItem] {
        let spaces = snapshot.spaces
        // The current space's tabs and panes are listed first.
        let ordered = spaces.filter { $0.id == snapshot.activeSpaceID } + spaces.filter { $0.id != snapshot.activeSpaceID }
        var actions = commandPaletteActions.map { action in
            CommandPaletteItem(
                target: .action(action), kind: .action, title: commandPaletteTitle(action), subtitle: Self.menuTitle(action.menu),
                keywords: action.paletteKeywords, shortcut: keyboard.shortcuts[action])
        }
        if openSettings != nil {
            actions.append(CommandPaletteItem(target: .settings, kind: .action, title: L("Settings…"), subtitle: "Trellis", keywords: ["preferences"], shortcut: KeyChord(",")))
        }
        actions.append(CommandPaletteItem(target: .welcomeTour, kind: .action, title: L("Welcome Tour"), subtitle: L("Help"), keywords: ["onboarding", "introduction", "getting started"]))
        let spaceItems = spaces.map { space in
            let current = space.id == snapshot.activeSpaceID ? " · " + L("current") : ""
            return CommandPaletteItem(target: .space(space.id), kind: .space, title: space.name, subtitle: Self.plural(space.tabIDs.count, L("1 tab"), L("%d tabs", space.tabIDs.count)) + current)
        }
        var tabItems: [CommandPaletteItem] = [], paneItems: [CommandPaletteItem] = []
        for space in ordered {
            let tabs = space.tabIDs.compactMap { snapshot.tabs[$0] }
            for (index, tab) in tabs.enumerated() {
                let title = displayTitle(tab)
                tabItems.append(
                    CommandPaletteItem(
                        target: .tab(spaceID: space.id, tabID: tab.id), kind: .tab, title: title,
                        subtitle: "\(space.name) › " + L("%1$d of %2$d", index + 1, tabs.count) + " · \(commandPaletteStatus(tab.activePaneID))",
                        groupID: space.id.uuidString, groupTitle: space.name))
                for paneID in tab.root.paneIDs {
                    paneItems.append(
                        CommandPaletteItem(
                            target: .pane(paneID), kind: .pane, title: paneTitle(paneID), subtitle: "\(space.name) › \(title) · \(commandPaletteStatus(paneID))",
                            groupID: space.id.uuidString, groupTitle: space.name))
                }
            }
        }
        let hostItems = commandPaletteHosts().flatMap { host in
            let destination = (host.user.map { "\($0)@" } ?? "") + host.destination + (host.port.map { " · " + L("port %d", $0) } ?? "")
            let connect = CommandPaletteItem(target: .host(host.id), kind: .host, title: host.name, subtitle: destination, keywords: host.tags + ["ssh"])
            // FR-RW01: each host can also open as a remote workspace whose sessions keep running there.
            guard remoteHosts != nil else { return [connect] }
            return [
                connect,
                CommandPaletteItem(
                    target: .remoteWorkspace(host.id), kind: .host, title: L("Open Remote Workspace: %@", host.name), subtitle: destination,
                    keywords: host.tags + ["ssh", "remote", "workspace"])
            ]
        }
        let projectItems = commandPaletteProjects().map { project in
            CommandPaletteItem(
                target: .project(project.id), kind: .project, title: L("Launch Project: %@", project.name),
                subtitle: Self.plural(project.tabs.count, L("1 tab"), L("%d tabs", project.tabs.count)) + (project.notes.map { " · " + $0.prefix(80) } ?? ""),
                keywords: ["project", "workspace", "launch"] + project.checkouts.map { GitRepository.shortName($0.repository.url) })
        }
        var taskItems: [CommandPaletteItem] = []
        if let catalog = taskCatalog, catalog.paneID == presentation.activePane?.id, taskAvailability(paneID: catalog.paneID).reason == nil {
            taskItems += catalog.tasks.map { CommandPaletteItem(target: .task(name: $0.name, detected: false), kind: .task, title: $0.name, subtitle: ".trellis/launch.json · " + $0.command) }
            taskItems += catalog.detected.map {
                CommandPaletteItem(target: .task(name: $0.task.name, detected: true), kind: .task, title: $0.task.name, subtitle: $0.detail + " · " + $0.task.command)
            }
        }
        let currentTheme = appearance.themeID(systemIsDark: systemIsDark)
        let themeItems = allThemes.map { theme in
            CommandPaletteItem(
                target: .theme(theme.id), kind: .theme, title: L("Theme: %@", theme.name),
                subtitle: (theme.appearance == .light ? L("Light") : L("Dark")) + (theme.id == currentTheme ? " · " + L("current") : ""), keywords: ["appearance colors"])
        }
        // FR-AG07: the same agents as the Agents view, opened beside the focused pane.
        let agentItems =
            presentation.activePane == nil
            ? []
            : agentCatalog.definitions.map { agent in
                CommandPaletteItem(
                    target: .agent(agent.id), kind: .agent, title: L("Launch Agent: %@", agent.name), subtitle: L("In a new tab · ⌥↩ beside the focused pane"),
                    keywords: ["agent", "ai", agent.executable])
            }
        let directoryItems = directoryPaletteItems
        let tabsInSpaces =
            switch (tabItems.count == 1, spaces.count == 1) {
            case (true, true): L("1 tab in 1 space")
            case (true, false): L("1 tab in %d spaces", spaces.count)
            case (false, true): L("%d tabs in 1 space", tabItems.count)
            case (false, false): L("%1$d tabs in %2$d spaces", tabItems.count, spaces.count)
            }
        let tasksInProject =
            if let name = taskCatalog?.name { Self.plural(taskItems.count, L("1 task in %@", name), L("%1$d tasks in %2$@", taskItems.count, name)) } else {
                Self.plural(taskItems.count, L("1 task in this project"), L("%d tasks in this project", taskItems.count))
            }
        let savedHosts = commandPaletteHosts().count
        let counts: [CommandPaletteScope: (Int, String)] = [
            .spaces: (spaceItems.count, Self.plural(spaceItems.count, L("1 space"), L("%d spaces", spaceItems.count))),
            .tabs: (tabItems.count, tabsInSpaces),
            .panes: (paneItems.count, Self.plural(paneItems.count, L("1 pane"), L("%d panes", paneItems.count))),
            .hosts: (hostItems.count, Self.plural(savedHosts, L("1 saved host"), L("%d saved hosts", savedHosts))),
            .projects: (projectItems.count, Self.plural(projectItems.count, L("1 project"), L("%d projects", projectItems.count))),
            .tasks: (taskItems.count, tasksInProject),
            .themes: (themeItems.count, Self.plural(themeItems.count, L("1 theme"), L("%d themes", themeItems.count))),
            .agents: (agentItems.count, Self.plural(agentItems.count, L("1 agent"), L("%d agents", agentItems.count))),
            .directories: (directoryItems.count, Self.plural(directoryItems.count, L("1 recent directory"), L("%d recent directories", directoryItems.count)))
        ]
        let scopes = CommandPaletteScope.allCases.compactMap { scope -> CommandPaletteItem? in
            guard let (count, text) = counts[scope], count > 0 else { return nil }
            let shortcut = scope == .directories ? keyboard.shortcuts[.jumpToDirectory] : nil
            let keywords = scope == .directories ? ["go to jump switch", "cd folder recent"] : ["go to jump switch"]
            return CommandPaletteItem(target: .scope(scope), kind: .action, title: scope.title, subtitle: text, keywords: keywords, shortcut: shortcut)
        }
        return scopes + actions + tabItems + spaceItems + paneItems + hostItems + projectItems + taskItems + themeItems + agentItems + directoryItems
    }

    /// The menu's own title where it changes with state.
    private func commandPaletteTitle(_ action: ShortcutAction) -> String {
        switch action {
        case .toggleSidebar: sidebarCollapsed ? L("Show Sidebar") : L("Hide Sidebar")
        case .toggleFiles, .toggleChanges, .toggleScratchpad, .toggleTasks, .toggleAgents: SidebarView(shortcut: action).map { visibleSidebarView == $0 ? L("Hide %@", $0.title) : L("Show %@", $0.title) } ?? action.title
        default: action.title
        }
    }

    private func commandPaletteStatus(_ paneID: UUID) -> String {
        guard let terminal = terminals[paneID] else { return L("Stopped") }
        return SessionStatusText.describe(terminal.sessionState, exitCode: terminal.exitCode)
    }

    /// Each count has its own two whole phrases, so a translation never has to build a plural from a noun.
    private static func plural(_ count: Int, _ one: String, _ many: String) -> String { count == 1 ? one : many }

    /// The menu an action lives in, as its row's subtitle.
    private static func menuTitle(_ menu: ShortcutMenu) -> String {
        switch menu {
        case .file: L("File")
        case .edit: L("Edit")
        case .view: L("View")
        case .pane: L("Pane")
        case .window: L("Window")
        }
    }
}
