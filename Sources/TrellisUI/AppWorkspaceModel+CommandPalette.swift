import AppKit
import Foundation
import TrellisCore

/// A second Return-like key on a host row (FR-CP07).
public enum CommandPaletteModifier: Sendable { case none, command, option }

/// The command palette (FR-CP01–FR-CP08): one searchable list of actions and places. Every row runs through the path
/// its menu item or control uses, so the palette adds no mutation of its own.
extension AppWorkspaceModel {
    public func toggleCommandPalette() { commandPaletteVisible ? closeCommandPalette() : openCommandPalette() }

    public func openCommandPalette() {
        guard !commandPaletteVisible, !isRestoring, recoveryMessage == nil, !shuttingDown else { return }
        // Read now: some actions are enabled only while a terminal, not the palette's field, has focus.
        commandPaletteActions = ShortcutAction.allCases.filter { $0 != .commandPalette && $0.tabIndex == nil && canPerformShortcutAction?($0) == true }
        commandPaletteQuery = ""
        commandPaletteScope = nil
        commandPaletteVisible = true
        commandPaletteFocusRequest &+= 1
        terminals.values.forEach { $0.inputSuspended = true }
        selectFirstCommandPaletteItem()
        if let paneID = presentation.activePane?.id { Task { await refreshTaskCatalog(paneID: paneID) } }
    }

    /// Esc, the backdrop, the shortcut again, or a row that ran: focus goes back to the (now) active pane.
    public func closeCommandPalette() {
        guard commandPaletteVisible else { return }
        endCommandPalettePreview()
        commandPaletteVisible = false
        commandPaletteSelection = nil
        terminals.values.forEach { $0.inputSuspended = editingTabID != nil }
        focusActiveTerminal()
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

    public var commandPaletteSections: [CommandPaletteSection] {
        CommandPaletteSearch.sections(items: commandPaletteItems, query: commandPaletteQuery, scope: commandPaletteScope, recents: commandPaletteRecents.ids)
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
        case .scope: break
        case .window(let id):
            await selectWindow(id)
            focusActiveTerminal()
        case .tab(let windowID, let tabID):
            await selectWindowTab(windowID: windowID, tabID: tabID)
            focusActiveTerminal()
        case .pane(let id):
            await revealPane(id)
            focusActiveTerminal()
        case .host(let id):
            guard let host = commandPaletteHosts().first(where: { $0.id == id }) else { return }
            let placement: HostPlacement =
                switch modifier {
                case .none: .newTab
                case .command: .newWindow
                case .option: .split(.x)
                }
            await connect(host: host, placement: placement)
        case .task(let name, let detected):
            guard let catalog = taskCatalog else { return }
            let task = detected ? catalog.detected.first { $0.task.name == name }?.task : catalog.tasks.first { $0.name == name }
            if let task { runTask(task, fromFile: !detected) }
        case .theme(let id): useTheme(id)
        }
    }

    private func selectFirstCommandPaletteItem() {
        selectCommandPaletteItem(commandPaletteSections.first?.matches.first?.item.id)
    }

    private func focusActiveTerminal() {
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
        let windows = snapshot.windows
        // The current window's tabs and panes are listed first.
        let ordered = windows.filter { $0.id == snapshot.activeWindowID } + windows.filter { $0.id != snapshot.activeWindowID }
        var actions = commandPaletteActions.map { action in
            CommandPaletteItem(
                target: .action(action), kind: .action, title: commandPaletteTitle(action), subtitle: action.menu.rawValue.capitalized,
                keywords: action.paletteKeywords, shortcut: keyboard.shortcuts[action])
        }
        if openSettings != nil {
            actions.append(CommandPaletteItem(target: .settings, kind: .action, title: "Settings…", subtitle: "Trellis", keywords: ["preferences"], shortcut: KeyChord(",")))
        }
        let windowItems = windows.map { window in
            let current = window.id == snapshot.activeWindowID ? " · current" : ""
            return CommandPaletteItem(target: .window(window.id), kind: .window, title: window.name, subtitle: Self.count(window.tabIDs.count, "tab") + current)
        }
        var tabItems: [CommandPaletteItem] = [], paneItems: [CommandPaletteItem] = []
        for window in ordered {
            let tabs = window.tabIDs.compactMap { snapshot.tabs[$0] }
            for (index, tab) in tabs.enumerated() {
                let title = displayTitle(tab)
                tabItems.append(
                    CommandPaletteItem(
                        target: .tab(windowID: window.id, tabID: tab.id), kind: .tab, title: title,
                        subtitle: "\(window.name) › \(index + 1) of \(tabs.count) · \(commandPaletteStatus(tab.activePaneID))",
                        groupID: window.id.uuidString, groupTitle: window.name))
                for paneID in tab.root.paneIDs {
                    paneItems.append(
                        CommandPaletteItem(
                            target: .pane(paneID), kind: .pane, title: paneTitle(paneID), subtitle: "\(window.name) › \(title) · \(commandPaletteStatus(paneID))",
                            groupID: window.id.uuidString, groupTitle: window.name))
                }
            }
        }
        let hostItems = commandPaletteHosts().map { host in
            let destination = (host.user.map { "\($0)@" } ?? "") + host.destination + (host.port.map { " · port \($0)" } ?? "")
            return CommandPaletteItem(target: .host(host.id), kind: .host, title: host.name, subtitle: destination, keywords: host.tags + ["ssh"])
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
                target: .theme(theme.id), kind: .theme, title: "Theme: " + theme.name,
                subtitle: theme.appearance.rawValue.capitalized + (theme.id == currentTheme ? " · current" : ""), keywords: ["appearance colors"])
        }
        let counts: [CommandPaletteScope: (Int, String)] = [
            .windows: (windowItems.count, Self.count(windowItems.count, "window")),
            .tabs: (tabItems.count, Self.count(tabItems.count, "tab") + " in " + Self.count(windows.count, "window")),
            .panes: (paneItems.count, Self.count(paneItems.count, "pane")),
            .hosts: (hostItems.count, Self.count(hostItems.count, "saved host")),
            .tasks: (taskItems.count, Self.count(taskItems.count, "task") + " in " + (taskCatalog?.name ?? "this project")),
            .themes: (themeItems.count, Self.count(themeItems.count, "theme"))
        ]
        let scopes = CommandPaletteScope.allCases.compactMap { scope -> CommandPaletteItem? in
            guard let (count, text) = counts[scope], count > 0 else { return nil }
            return CommandPaletteItem(target: .scope(scope), kind: .action, title: scope.title, subtitle: text, keywords: ["go to jump switch"])
        }
        return scopes + actions + tabItems + windowItems + paneItems + hostItems + taskItems + themeItems
    }

    /// The menu's own title where it changes with state.
    private func commandPaletteTitle(_ action: ShortcutAction) -> String {
        switch action {
        case .toggleSidebar: sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar"
        case .toggleScratchpad: scratchpadVisible ? "Hide Scratchpad" : "Show Scratchpad"
        default: action.title
        }
    }

    private func commandPaletteStatus(_ paneID: UUID) -> String {
        guard let terminal = terminals[paneID] else { return "Stopped" }
        return SessionStatusText.describe(terminal.sessionState, exitCode: terminal.exitCode)
    }

    private static func count(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
}
