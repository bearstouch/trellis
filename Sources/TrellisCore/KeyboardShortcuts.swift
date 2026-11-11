import Foundation

public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1)
    public static let shift = Self(rawValue: 2)
    public static let option = Self(rawValue: 4)
    public static let control = Self(rawValue: 8)
}

/// Layout-neutral chord. `key` is a single lowercase character as produced by the
/// active layout without modifiers, or one of `KeyChord.namedKeys`.
public struct KeyChord: Codable, Hashable, Sendable, CustomStringConvertible {
    public static let namedKeys: Set<String> = Set(
        ["left", "right", "up", "down", "return", "tab", "space", "delete", "forwardDelete", "home", "end", "pageUp", "pageDown"]
            + (1...12).map { "f\($0)" })
    public let key: String
    public let modifiers: KeyModifiers

    public init(_ key: String, _ modifiers: KeyModifiers = .command) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = modifiers
    }

    public var isSupported: Bool { key.count == 1 ? key.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F } : Self.namedKeys.contains(key) }

    /// Menu-style glyphs in Apple's modifier order, e.g. ⌃⌥⇧⌘D.
    public var description: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let glyphs = [
            "left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↩", "tab": "⇥", "space": "Space",
            "delete": "⌫", "forwardDelete": "⌦", "home": "↖", "end": "↘", "pageUp": "⇞", "pageDown": "⇟"
        ]
        return text + (glyphs[key] ?? key.uppercased())
    }
}

public enum ShortcutMenu: String, CaseIterable, Sendable {
    case file, edit, view, pane, window

    public var title: String {
        switch self {
        case .file: L("File")
        case .edit: L("Edit")
        case .view: L("View")
        case .pane: L("Pane")
        case .window: L("Window")
        }
    }
}

public enum ShortcutAction: String, Codable, CaseIterable, Sendable {
    // The Space actions keep their stored names from before windows were renamed spaces, so customized shortcuts carry over.
    case newSpace = "newWindow", newTab, renameTab, renameSpace = "renameWindow", closePane, closeTab, deleteSpace = "deleteWindow", saveWorkspace, showHosts
    /// The project library (FR-PL01). The stored name predates it, so a customized ⌘O carries over.
    case showProjects = "openWorkspaceFile"
    case findInPane, findNext, findPrevious, previousPrompt, nextPrompt, clearPane
    case zoomIn, zoomOut, actualSize, toggleSidebar, toggleFiles, toggleChanges, toggleScratchpad, toggleTasks, toggleAgents, commandPalette, jumpToDirectory
    case splitLeftRight, splitTopBottom, maximizePane
    case focusLeft, focusRight, focusUp, focusDown
    case resizeLeft, resizeRight, resizeUp, resizeDown
    case nextSpace = "nextWindow", previousSpace = "previousWindow", nextTab, previousTab
    case selectTab1, selectTab2, selectTab3, selectTab4, selectTab5, selectTab6, selectTab7, selectTab8, selectTab9

    public var title: String {
        switch self {
        case .newSpace: L("New Space")
        case .newTab: L("New Tab")
        case .renameTab: L("Rename Tab…")
        case .renameSpace: L("Rename Space…")
        case .closePane: L("Close Pane")
        case .closeTab: L("Close Tab")
        case .deleteSpace: L("Delete Space…")
        case .saveWorkspace: L("Save Workspace")
        case .showHosts: L("Hosts…")
        case .showProjects: L("Projects…")
        case .findInPane: L("Find in Pane…")
        case .findNext: L("Find Next")
        case .findPrevious: L("Find Previous")
        case .previousPrompt: L("Previous Prompt")
        case .nextPrompt: L("Next Prompt")
        case .clearPane: L("Clear")
        case .zoomIn: L("Zoom In")
        case .zoomOut: L("Zoom Out")
        case .actualSize: L("Actual Size")
        case .toggleSidebar: L("Toggle Sidebar")
        case .toggleFiles: L("Toggle Files")
        case .toggleChanges: L("Toggle Changes")
        case .toggleScratchpad: L("Toggle Scratchpad")
        case .toggleTasks: L("Toggle Tasks")
        case .toggleAgents: L("Toggle Agents")
        case .commandPalette: L("Command Palette…")
        case .jumpToDirectory: L("Jump to Directory…")
        case .splitLeftRight: L("Split Left/Right")
        case .splitTopBottom: L("Split Top/Bottom")
        case .maximizePane: L("Maximize / Restore Pane")
        case .focusLeft: L("Focus Left")
        case .focusRight: L("Focus Right")
        case .focusUp: L("Focus Up")
        case .focusDown: L("Focus Down")
        case .resizeLeft: L("Move Divider Left")
        case .resizeRight: L("Move Divider Right")
        case .resizeUp: L("Move Divider Up")
        case .resizeDown: L("Move Divider Down")
        case .nextSpace: L("Next Space")
        case .previousSpace: L("Previous Space")
        case .nextTab: L("Next Tab")
        case .previousTab: L("Previous Tab")
        default: L("Select Tab %d", tabIndex! + 1)
        }
    }

    /// Zero-based tab position for the Select Tab actions.
    public var tabIndex: Int? {
        let order: [Self] = [.selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5, .selectTab6, .selectTab7, .selectTab8, .selectTab9]
        return order.firstIndex(of: self)
    }

    public var menu: ShortcutMenu {
        switch self {
        case .newSpace, .newTab, .renameTab, .renameSpace, .closePane, .closeTab, .deleteSpace, .saveWorkspace, .showHosts, .showProjects: .file
        case .findInPane, .findNext, .findPrevious, .previousPrompt, .nextPrompt, .clearPane: .edit
        case .zoomIn, .zoomOut, .actualSize, .toggleSidebar, .toggleFiles, .toggleChanges, .toggleScratchpad, .toggleTasks, .toggleAgents, .commandPalette, .jumpToDirectory: .view
        case .splitLeftRight, .splitTopBottom, .maximizePane, .focusLeft, .focusRight, .focusUp, .focusDown,
            .resizeLeft, .resizeRight, .resizeUp, .resizeDown:
            .pane
        default: .window
        }
    }

    public var defaultChord: KeyChord? {
        switch self {
        case .newSpace: KeyChord("n")
        case .newTab: KeyChord("t")
        case .closePane: KeyChord("w")
        case .closeTab: KeyChord("w", [.command, .shift])
        case .saveWorkspace: KeyChord("s")
        case .showProjects: KeyChord("o")
        case .findInPane: KeyChord("f")
        case .findNext: KeyChord("g")
        case .findPrevious: KeyChord("g", [.command, .shift])
        case .previousPrompt: KeyChord("up")
        case .nextPrompt: KeyChord("down")
        case .clearPane: KeyChord("k")
        case .zoomIn: KeyChord("+")
        case .zoomOut: KeyChord("-")
        case .actualSize: KeyChord("0")
        case .toggleSidebar: KeyChord("s", [.command, .control])
        case .toggleFiles: KeyChord("f", [.command, .option])
        case .toggleChanges: KeyChord("g", [.command, .option])
        case .toggleScratchpad: KeyChord("e", [.command, .option])
        case .toggleTasks: KeyChord("t", [.command, .option])
        case .toggleAgents: KeyChord("a", [.command, .option])
        case .commandPalette: KeyChord("p", [.command, .shift])
        case .jumpToDirectory: KeyChord("j")
        case .splitLeftRight: KeyChord("d")
        case .splitTopBottom: KeyChord("d", [.command, .shift])
        case .maximizePane: KeyChord("return", [.command, .shift])
        case .focusLeft: KeyChord("left", [.command, .option])
        case .focusRight: KeyChord("right", [.command, .option])
        case .focusUp: KeyChord("up", [.command, .option])
        case .focusDown: KeyChord("down", [.command, .option])
        case .resizeLeft: KeyChord("left", [.command, .option, .shift])
        case .resizeRight: KeyChord("right", [.command, .option, .shift])
        case .resizeUp: KeyChord("up", [.command, .option, .shift])
        case .resizeDown: KeyChord("down", [.command, .option, .shift])
        case .nextSpace: KeyChord("]", [.command, .control])
        case .previousSpace: KeyChord("[", [.command, .control])
        case .nextTab: KeyChord("]", [.command, .shift])
        case .previousTab: KeyChord("[", [.command, .shift])
        case .renameTab, .renameSpace, .deleteSpace, .showHosts: nil
        default: KeyChord(String(tabIndex! + 1))
        }
    }
}

public enum ShortcutIssue: Error, Equatable, Sendable, CustomStringConvertible {
    case conflict(KeyChord, [ShortcutAction])
    case reserved(KeyChord, ShortcutAction, reservedFor: String)
    case requiresCommand(KeyChord, ShortcutAction)
    case unsupportedKey(KeyChord, ShortcutAction)

    public var description: String {
        switch self {
        case .conflict(let chord, let actions) where actions.count == 2:
            L("%1$@ is assigned to both %2$@ and %3$@. Choose a different shortcut for one of them.", chord.description, actions[0].title, actions[1].title)
        case .conflict(let chord, let actions):
            L("%1$@ is assigned to both %2$@. Choose a different shortcut for one of them.", chord.description, actions.map(\.title).joined(separator: " \(L("and")) "))
        case .reserved(let chord, let action, let owner): L("%1$@ is reserved for %2$@ and cannot be used for %3$@.", chord.description, owner, action.title)
        case .requiresCommand(let chord, let action): L("%1$@ for %2$@ must include ⌘ so terminal control keys keep working.", chord.description, action.title)
        case .unsupportedKey(let chord, let action): L("%1$@ is not a supported key for %2$@.", chord.description, action.title)
        }
    }
}

/// Complete action → chord map. A nil entry means the action is deliberately
/// unbound; it stays reachable from its menu. Validation never mutates `self`.
public struct ShortcutMap: Equatable, Sendable {
    /// Native editing and application commands. Text fields and the terminal's
    /// copy/paste depend on these, so they can never be reassigned.
    public static var reserved: [KeyChord: String] {
        [
            KeyChord("c"): L("Copy"), KeyChord("v"): L("Paste"), KeyChord("x"): L("Cut"), KeyChord("a"): L("Select All"),
            KeyChord("z"): L("Undo"), KeyChord("z", [.command, .shift]): L("Redo"), KeyChord("q"): L("Quit Trellis"),
            KeyChord("h"): L("Hide Trellis"), KeyChord("h", [.command, .option]): L("Hide Others"), KeyChord(","): L("Settings…"),
            KeyChord("m"): L("Minimize"), KeyChord("`"): L("Cycle Windows"), KeyChord("tab"): L("Switch Applications"),
            KeyChord("space"): "Spotlight", KeyChord("o", [.command, .option]): L("Option-as-Meta toggle (disabled)")
        ]
    }
    public private(set) var chords: [ShortcutAction: KeyChord]

    public static let defaults = Self(chords: Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.compactMap { action in action.defaultChord.map { (action, $0) } }))

    public init(chords: [ShortcutAction: KeyChord]) { self.chords = chords }

    public subscript(action: ShortcutAction) -> KeyChord? { chords[action] }

    public func action(for chord: KeyChord) -> ShortcutAction? { chords.first { $0.value == chord }?.key }

    /// Every problem, in a stable order, so the UI can name all affected actions.
    public func issues() -> [ShortcutIssue] {
        var result: [ShortcutIssue] = []
        var owners: [KeyChord: [ShortcutAction]] = [:]
        for action in ShortcutAction.allCases {
            guard let chord = chords[action] else { continue }
            if !chord.isSupported {
                result.append(.unsupportedKey(chord, action))
            } else if !chord.modifiers.contains(.command) {
                result.append(.requiresCommand(chord, action))
            } else if let owner = Self.reserved[chord] {
                result.append(.reserved(chord, action, reservedFor: owner))
            }
            owners[chord, default: []].append(action)
        }
        for action in ShortcutAction.allCases {
            if let chord = chords[action], let shared = owners[chord], shared.count > 1, shared.first == action {
                result.append(.conflict(chord, shared))
            }
        }
        return result
    }

    /// Unvalidated draft edit, so a user can swap two shortcuts in steps.
    public func assigning(_ chord: KeyChord?, to action: ShortcutAction) -> Self {
        var next = self
        next.chords[action] = chord
        return next
    }

    /// Returns the updated map or throws the first issue; the receiver is unchanged.
    public func binding(_ action: ShortcutAction, to chord: KeyChord?) throws(ShortcutIssue) -> Self {
        let next = assigning(chord, to: action)
        if let issue = next.issues().first(where: { $0.involves(action) }) { throw issue }
        return next
    }
}

extension ShortcutIssue {
    public func involves(_ action: ShortcutAction) -> Bool {
        switch self {
        case .conflict(_, let actions): actions.contains(action)
        case .reserved(_, let owner, _), .requiresCommand(_, let owner), .unsupportedKey(_, let owner): owner == action
        }
    }
}

/// Persisted keyboard preferences. Only differences from the defaults are stored
/// so new default bindings reach existing users.
public struct KeyboardSettings: Equatable, Sendable, Codable {
    /// Off by default: Option composes characters on Portuguese and many other
    /// layouts (and dead keys on US); Meta is an explicit opt-in.
    public var optionAsMeta = false
    public var shortcuts = ShortcutMap.defaults
    public init() {}

    private enum CodingKeys: String, CodingKey { case optionAsMeta, overrides }
    /// A missing chord encodes as JSON null so an unbound default survives a round trip.
    private struct Override: Codable { var chord: KeyChord? }

    /// Actions whose default chord shipped after saved maps already existed.
    static let laterDefaults: [ShortcutAction] = [
        .previousPrompt, .nextPrompt, .toggleSidebar, .clearPane, .showProjects, .toggleScratchpad, .commandPalette, .jumpToDirectory, .toggleTasks, .toggleAgents, .toggleFiles, .toggleChanges
    ]

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        optionAsMeta = try values.decodeIfPresent(Bool.self, forKey: .optionAsMeta) ?? false
        var chords = ShortcutMap.defaults.chords
        var overridden: Set<ShortcutAction> = []
        // Unknown action names from a newer build are ignored rather than fatal.
        for (name, override) in try values.decodeIfPresent([String: Override].self, forKey: .overrides) ?? [:] {
            guard let action = ShortcutAction(rawValue: name) else { continue }
            chords[action] = override.chord; overridden.insert(action)
        }
        // A default added in a later build yields to a chord the user already chose,
        // instead of turning the whole saved map into a conflict. Other conflicts still reject the map.
        let chosen = Set(overridden.compactMap { chords[$0] })
        for action in Self.laterDefaults where !overridden.contains(action) {
            if let chord = chords[action], chosen.contains(chord) { chords[action] = nil }
        }
        shortcuts = ShortcutMap(chords: chords)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(optionAsMeta, forKey: .optionAsMeta)
        var overrides: [String: Override] = [:]
        for action in ShortcutAction.allCases where shortcuts[action] != action.defaultChord {
            overrides[action.rawValue] = Override(chord: shortcuts[action])
        }
        try values.encode(overrides, forKey: .overrides)
    }
}
