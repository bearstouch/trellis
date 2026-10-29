import Foundation

/// What a palette row is, in the order equal scores are listed (FR-CP04).
public enum CommandPaletteKind: Int, CaseIterable, Comparable, Sendable {
    case action, tab, window, pane, host, task, theme

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var sectionTitle: String {
        switch self {
        case .action: "Actions"
        case .tab: "Tabs"
        case .window: "Windows"
        case .pane: "Panes"
        case .host: "Hosts"
        case .task: "Tasks"
        case .theme: "Themes"
        }
    }

    /// Spoken after the title, e.g. "Split Left/Right, Pane action".
    public var noun: String {
        switch self {
        case .action: "action"
        case .tab: "tab"
        case .window: "window"
        case .pane: "pane"
        case .host: "host"
        case .task: "task"
        case .theme: "theme"
        }
    }
}

/// One kind listed alone (FR-CP06).
public enum CommandPaletteScope: String, CaseIterable, Sendable {
    case windows, tabs, panes, hosts, tasks, themes

    public var kind: CommandPaletteKind {
        switch self {
        case .windows: .window
        case .tabs: .tab
        case .panes: .pane
        case .hosts: .host
        case .tasks: .task
        case .themes: .theme
        }
    }

    public var title: String {
        switch self {
        case .windows: "Go to Window…"
        case .tabs: "Go to Tab…"
        case .panes: "Go to Pane…"
        case .hosts: "Connect to Host…"
        case .tasks: "Run Task…"
        case .themes: "Use Theme…"
        }
    }

    /// The chip in the search field while the scope is entered.
    public var chipTitle: String { kind.sectionTitle }
}

/// What Return does. Stable across rebuilds, so selection and recents survive a snapshot change.
public enum CommandPaletteTarget: Hashable, Sendable {
    case action(ShortcutAction)
    case settings
    case scope(CommandPaletteScope)
    case window(UUID)
    case tab(windowID: UUID, tabID: UUID)
    case pane(UUID)
    case host(UUID)
    /// Opens the saved host as a remote workspace (FR-RW01).
    case remoteWorkspace(UUID)
    case task(name: String, detected: Bool)
    case theme(String)

    public var id: String {
        switch self {
        case .action(let action): "action:" + action.rawValue
        case .settings: "settings"
        case .scope(let scope): "scope:" + scope.rawValue
        case .window(let id): "window:" + id.uuidString
        case .tab(_, let id): "tab:" + id.uuidString
        case .pane(let id): "pane:" + id.uuidString
        case .host(let id): "host:" + id.uuidString
        case .remoteWorkspace(let id): "remote-workspace:" + id.uuidString
        case .task(let name, let detected): (detected ? "task:detected:" : "task:file:") + name
        case .theme(let id): "theme:" + id
        }
    }
}

public struct CommandPaletteItem: Identifiable, Equatable, Sendable {
    public var target: CommandPaletteTarget
    public var kind: CommandPaletteKind
    public var title: String
    public var subtitle: String
    /// Aliases that also find the item ("split" for Maximize Pane); never shown unless they matched.
    public var keywords: [String]
    public var shortcut: KeyChord?
    /// The heading inside a scope, such as a tab's window. `groupID` keeps two windows with one name apart.
    public var groupID: String?
    public var groupTitle: String?
    public var id: String { target.id }

    public init(
        target: CommandPaletteTarget, kind: CommandPaletteKind, title: String, subtitle: String = "", keywords: [String] = [], shortcut: KeyChord? = nil,
        groupID: String? = nil, groupTitle: String? = nil
    ) {
        self.target = target; self.kind = kind; self.title = title; self.subtitle = subtitle; self.keywords = keywords; self.shortcut = shortcut
        self.groupID = groupID; self.groupTitle = groupTitle
    }
}

public struct CommandPaletteMatch: Equatable, Sendable {
    public let item: CommandPaletteItem
    public let score: Int
    /// Character offsets into `item.title` to emphasize.
    public let titlePositions: [Int]
    /// The alias or subtitle that matched when the title didn't.
    public let matchedAlias: String?
}

public struct CommandPaletteSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let matches: [CommandPaletteMatch]
}

/// Item IDs only, most recent first, kept in memory for one launch (FR-CP05).
public struct CommandPaletteRecents: Equatable, Sendable {
    public static let limit = 20
    public private(set) var ids: [String] = []
    public init() {}
    public mutating func record(_ id: String) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > Self.limit { ids.removeLast(ids.count - Self.limit) }
    }
}

public enum FuzzyMatch {
    /// Longer queries match nothing, and only the start of a long text is searched, so a pasted query or a long
    /// task command can't stall typing: the search is quadratic.
    public static let maximumQueryLetters = 64
    public static let maximumTextCharacters = 512

    /// The best placement of the query's letters, in order and case-insensitively, inside `text`; nil when one is
    /// missing. Whitespace in the query is ignored. Positions are character offsets into `text`.
    public static func match(_ query: String, in text: String) -> (score: Int, positions: [Int])? {
        let needle = query.filter { !$0.isWhitespace }.map { $0.lowercased() }
        let m = needle.count
        guard m > 0 else { return (0, []) }
        guard m <= maximumQueryLetters else { return nil }
        let original = Array(text.prefix(maximumTextCharacters))
        let haystack = original.map { $0.lowercased() }
        let n = haystack.count
        guard m <= n else { return nil }
        // Most candidates lack a letter: one pass rules them out before the full search.
        var next = 0
        for letter in haystack where next < m && letter == needle[next] { next += 1 }
        guard next == m else { return nil }
        func bonus(_ j: Int) -> Int {
            if j == 0 { return 10 }
            let previous = original[j - 1]
            if !previous.isLetter && !previous.isNumber { return 8 }
            if original[j].isUppercase && previous.isLowercase { return 7 }
            return 0
        }
        let none = Int.min / 2
        // score[i][j]: best total with query letter i placed on text letter j; from[i][j]: where letter i-1 went.
        var score = Array(repeating: Array(repeating: none, count: n), count: m)
        var from = Array(repeating: Array(repeating: -1, count: n), count: m)
        for j in 0..<n where haystack[j] == needle[0] { score[0][j] = 1 + bonus(j) - min(j, 5) }
        for i in 1..<m {
            var best = none, bestIndex = -1
            for j in i..<n {
                // Letters placed two or more back count as a gap; the one just before is consecutive.
                if j >= 2, score[i - 1][j - 2] > best { best = score[i - 1][j - 2]; bestIndex = j - 2 }
                guard haystack[j] == needle[i] else { continue }
                let consecutive = score[i - 1][j - 1] > none ? score[i - 1][j - 1] + 8 : none
                let gapped = best > none ? best - 3 : none
                guard max(consecutive, gapped) > none else { continue }
                score[i][j] = 1 + bonus(j) + max(consecutive, gapped)
                from[i][j] = consecutive >= gapped ? j - 1 : bestIndex
            }
        }
        guard let end = (0..<n).max(by: { score[m - 1][$0] < score[m - 1][$1] }), score[m - 1][end] > none else { return nil }
        var positions = [end]
        for i in stride(from: m - 1, to: 0, by: -1) { positions.append(from[i][positions.last!]) }
        return (score[m - 1][end], positions.reversed())
    }
}

public enum CommandPaletteSearch {
    public static let recentLimit = 3
    /// An alias or subtitle match ranks below any title match of similar quality (FR-CP04).
    static let aliasPenalty = 15

    /// The rows to show, grouped and ordered (FR-CP04–FR-CP06).
    public static func sections(items: [CommandPaletteItem], query: String, scope: CommandPaletteScope?, recents: [String]) -> [CommandPaletteSection] {
        let pool = scope.map { scope in items.filter { $0.kind == scope.kind && !$0.isScope } } ?? items
        let unranked = { (item: CommandPaletteItem) in CommandPaletteMatch(item: item, score: 0, titlePositions: [], matchedAlias: nil) }
        guard query.contains(where: { !$0.isWhitespace }) else {
            if scope != nil { return grouped(pool.map(unranked), byKind: false) }
            let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let recent = recents.compactMap { byID[$0] }.prefix(recentLimit)
            let shown = Set(recent.map(\.id))
            let suggested = pool.filter { ($0.isScope || $0.target == .action(.newTab)) && !shown.contains($0.id) }
            return [
                CommandPaletteSection(id: "recent", title: "Recent", matches: recent.map(unranked)),
                CommandPaletteSection(id: "suggested", title: "Suggested", matches: suggested.map(unranked))
            ].filter { !$0.matches.isEmpty }
        }
        let recency = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let matches = pool.compactMap { item -> CommandPaletteMatch? in
            let boost = recency[item.id].map { max(0, 10 - $0) } ?? 0
            if let title = FuzzyMatch.match(query, in: item.title) {
                return CommandPaletteMatch(item: item, score: title.score + boost, titlePositions: title.positions, matchedAlias: nil)
            }
            let aliases = (item.keywords + [item.subtitle]).filter { !$0.isEmpty }
            let best = aliases.compactMap { alias in FuzzyMatch.match(query, in: alias).map { (alias, $0.score) } }.max { $0.1 < $1.1 }
            return best.map { CommandPaletteMatch(item: item, score: $0.1 - aliasPenalty + boost, titlePositions: [], matchedAlias: $0.0) }
        }
        let sorted = matches.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.item.kind != $1.item.kind { return $0.item.kind < $1.item.kind }
            return $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending
        }
        return grouped(sorted, byKind: scope == nil)
    }

    /// Sections in order of their first (best) row; rows keep their order.
    static func grouped(_ matches: [CommandPaletteMatch], byKind: Bool) -> [CommandPaletteSection] {
        var order: [String] = [], titles: [String: String] = [:], rows: [String: [CommandPaletteMatch]] = [:]
        for match in matches {
            let key = byKind ? "kind:\(match.item.kind.rawValue)" : "group:" + (match.item.groupID ?? "")
            if rows[key] == nil { order.append(key); titles[key] = byKind ? match.item.kind.sectionTitle : match.item.groupTitle ?? match.item.kind.sectionTitle }
            rows[key, default: []].append(match)
        }
        return order.map { CommandPaletteSection(id: $0, title: titles[$0]!, matches: rows[$0]!) }
    }
}

extension CommandPaletteItem {
    public var isScope: Bool { if case .scope = target { true } else { false } }
}

extension ShortcutAction {
    /// Other words people search for (FR-CP04).
    public var paletteKeywords: [String] {
        switch self {
        case .maximizePane: ["split zoom", "fullscreen"]
        case .resizeLeft, .resizeRight, .resizeUp, .resizeDown: ["split resize"]
        case .focusLeft, .focusRight, .focusUp, .focusDown: ["split pane"]
        case .findInPane, .findNext, .findPrevious: ["search"]
        case .clearPane: ["reset screen", "cls"]
        case .closePane: ["kill"]
        case .showHosts: ["ssh servers"]
        case .openProjectFile: ["folder"]
        case .saveWorkspace: ["layout"]
        case .toggleSidebar: ["windows list"]
        case .toggleScratchpad: ["script editor"]
        case .zoomIn, .zoomOut, .actualSize: ["font size"]
        default: []
        }
    }
}
