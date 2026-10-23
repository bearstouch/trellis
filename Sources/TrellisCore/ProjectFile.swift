import CryptoKit
import Foundation

/// A project's reviewable `.trellis/project.json` (FR-WF01): one window's tabs,
/// splits, titles, labels, folders and commands. Unlike API layouts it may carry
/// commands, which only run after the exact file bytes are trusted (FR-WF03).
public struct ProjectFile: Equatable, Sendable {
    public static let directoryName = ".trellis"
    public static let fileName = "project.json"
    /// The name before project files were renamed; still read when `project.json` is absent (FR-WF07).
    public static let legacyFileName = "workspace.json"
    public static let maximumBytes = 262_144
    public static let maximumCommandLength = 4096
    /// The single window's layout key; documents may not use it.
    public static let windowKey = "trellis-window"

    public struct Tab: Equatable, Sendable {
        public var key: String?, title: String, color: TabColor?, root: Node
        public init(key: String? = nil, title: String, color: TabColor? = nil, root: Node) { self.key = key; self.title = title; self.color = color; self.root = root }
    }

    public struct Pane: Equatable, Sendable {
        public var key: String?, title: String?
        /// Relative to the project folder; nil is the folder itself.
        public var directory: String?
        public var command: String?
        public init(key: String? = nil, title: String? = nil, directory: String? = nil, command: String? = nil) {
            self.key = key; self.title = title; self.directory = directory; self.command = command
        }
    }

    public indirect enum Node: Equatable, Sendable {
        case pane(Pane)
        case split(key: String?, axis: SplitAxis, ratio: Double, children: [Node])
    }

    /// A pane with its tab and resolved layout key, in document order.
    public struct Entry: Equatable, Sendable {
        public let tab: Int, key: String, pane: Pane
    }

    public var name: String
    public var tabs: [Tab]
    public init(name: String, tabs: [Tab]) { self.name = name; self.tabs = tabs }

    /// Where a project file is written: always `project.json`.
    public static func url(projectRoot: String) -> URL { url(projectRoot: projectRoot, fileName: fileName) }
    public static func legacyURL(projectRoot: String) -> URL { url(projectRoot: projectRoot, fileName: legacyFileName) }

    /// The file a project is read from: `project.json`, or the legacy `workspace.json` when only that exists.
    public static func existingURL(projectRoot: String, fileExists: (String) -> Bool) -> URL? {
        [url(projectRoot: projectRoot), legacyURL(projectRoot: projectRoot)].first { fileExists($0.path) }
    }

    private static func url(projectRoot: String, fileName: String) -> URL {
        URL(fileURLWithPath: projectRoot, isDirectory: true).appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent(fileName)
    }

    /// Keys omitted from the document are derived from position, so the same file always maps to the same resources.
    public static func tabKey(_ tab: Tab, index: Int) -> String { tab.key ?? "t\(index + 1)" }
    static func nodeKey(_ key: String?, tab index: Int, path: String) -> String { key ?? "t\(index + 1)-\(path.isEmpty ? "0" : path)" }

    public var entries: [Entry] {
        var result: [Entry] = []
        func visit(_ node: Node, tab: Int, path: String) {
            switch node {
            case .pane(let pane): result.append(Entry(tab: tab, key: Self.nodeKey(pane.key, tab: tab, path: path), pane: pane))
            case .split(_, _, _, let children): for (offset, child) in children.enumerated() { visit(child, tab: tab, path: path + "\(offset + 1)") }
            }
        }
        for (index, tab) in tabs.enumerated() { visit(tab.root, tab: index, path: "") }
        return result
    }

    public var hasCommands: Bool { entries.contains { $0.pane.command != nil } }

    /// The file with each pane's command replaced, in `entries` order; blank text removes a command.
    public func settingCommands(_ commands: [String?]) -> ProjectFile {
        var remaining = commands[...]
        func visit(_ node: Node) -> Node {
            switch node {
            case .pane(var pane):
                let text = (remaining.popFirst() ?? nil)?.trimmingCharacters(in: .whitespaces)
                pane.command = text?.isEmpty == false ? text : nil
                return .pane(pane)
            case .split(let key, let axis, let ratio, let children): return .split(key: key, axis: axis, ratio: ratio, children: children.map(visit))
            }
        }
        var copy = self
        for index in copy.tabs.indices { copy.tabs[index].root = visit(copy.tabs[index].root) }
        return copy
    }

    /// Layout bindings that make `window` this file's window, so reopening the file reconciles it (FR-WF06).
    /// Nil when the window no longer has the file's shape.
    public func bindings(window: ManagedWindow, snapshot: WorkspaceSnapshot) -> [String: LayoutBinding]? {
        guard window.tabIDs.count == tabs.count else { return nil }
        var result = [Self.windowKey: LayoutBinding(kind: .window, id: window.id)]
        func visit(_ node: Node, _ layout: PaneLayout, tab: Int, path: String) -> Bool {
            switch (node, layout) {
            case (.pane(let pane), .pane(let id)):
                result[Self.nodeKey(pane.key, tab: tab, path: path)] = LayoutBinding(kind: .pane, id: id)
                return true
            case (.split(let key, _, _, let children), .split(let id, _, _, let branches)) where children.count == branches.count:
                result[Self.nodeKey(key, tab: tab, path: path)] = LayoutBinding(kind: .split, id: id)
                return zip(children, branches).enumerated().allSatisfy { visit($0.element.0, $0.element.1, tab: tab, path: path + "\($0.offset + 1)") }
            default: return false
            }
        }
        for (index, (tab, id)) in zip(tabs, window.tabIDs).enumerated() {
            guard let live = snapshot.tabs[id], visit(tab.root, live.root, tab: index, path: "") else { return nil }
            result[Self.tabKey(tab, index: index)] = LayoutBinding(kind: .tab, id: id)
        }
        return result
    }

    /// Rules the JSON shape can't express; the layout planner adds keys, limits and ratios.
    public var issues: [LayoutIssue] {
        var issues: [LayoutIssue] = []
        if let problem = Self.textProblem(name, limit: 200) { issues.append(LayoutIssue(key: nil, "The project name \(problem)")) }
        for (index, tab) in tabs.enumerated() {
            let key = Self.tabKey(tab, index: index)
            if key == Self.windowKey { issues.append(LayoutIssue(key: key, "The key \(Self.windowKey) is reserved.")) }
            if let problem = Self.textProblem(tab.title, limit: 200) { issues.append(LayoutIssue(key: key, "The tab title \(problem)")) }
        }
        for entry in entries {
            if entry.key == Self.windowKey { issues.append(LayoutIssue(key: entry.key, "The key \(Self.windowKey) is reserved.")) }
            if let title = entry.pane.title, let problem = Self.textProblem(title, limit: 200) { issues.append(LayoutIssue(key: entry.key, "The pane title \(problem)")) }
            if let directory = entry.pane.directory, Self.relativeDirectory(directory) == nil {
                issues.append(LayoutIssue(key: entry.key, "Directories must be relative to the project folder, without .., ~, $ or backticks."))
            }
            if let command = entry.pane.command, let problem = Self.commandProblem(command) { issues.append(LayoutIssue(key: entry.key, "The command \(problem)")) }
        }
        return issues
    }

    /// Bidi overrides, zero-width characters and line separators could make reviewed text differ from what runs.
    static func hasHiddenCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { [.format, .control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }
    }

    static func textProblem(_ text: String, limit: Int) -> String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > limit { return "needs 1–\(limit) characters." }
        return hasHiddenCharacters(text) ? "contains control or invisible formatting characters." : nil
    }

    /// One shell line, as `session.execute` accepts, with nothing hidden from review.
    public static func commandProblem(_ command: String) -> String? {
        if command.trimmingCharacters(in: .whitespaces).isEmpty || command.count > maximumCommandLength { return "needs 1–\(maximumCommandLength) characters." }
        // Commands also refuse other default-ignorable scalars (fillers, variation selectors), which render as nothing.
        let hidden = hasHiddenCharacters(command) || command.unicodeScalars.contains { $0.properties.isDefaultIgnorableCodePoint }
        return hidden ? "must be a single line without control or invisible formatting characters." : nil
    }

    /// The normalized relative form, or nil when it could escape the project or needs expansion.
    public static func relativeDirectory(_ directory: String) -> String? {
        guard !directory.isEmpty, directory.utf8.count <= 1024, !directory.hasPrefix("/"), !directory.hasPrefix("~"), !hasHiddenCharacters(directory),
            !directory.unicodeScalars.contains(where: { "$`".unicodeScalars.contains($0) })
        else { return nil }
        let segments = directory.split(separator: "/").filter { $0 != "." }
        guard !segments.contains("..") else { return nil }
        return segments.joined(separator: "/")
    }

    public struct Resolved: Equatable, Sendable {
        public let layout: LayoutDocument
        /// Pane key → command.
        public let commands: [String: String]
    }

    /// The window layout with absolute directories under `projectRoot`. Call only when `issues` is empty.
    public func resolve(projectRoot: String) -> Resolved {
        var commands: [String: String] = [:]
        func build(_ node: Node, tab: Int, path: String) -> LayoutNode {
            switch node {
            case .pane(let pane):
                let key = Self.nodeKey(pane.key, tab: tab, path: path)
                if let command = pane.command { commands[key] = command }
                let relative = pane.directory.flatMap(Self.relativeDirectory) ?? ""
                return .pane(key: key, title: pane.title, launch: .shell(directory: relative.isEmpty ? projectRoot : projectRoot + "/" + relative))
            case .split(let key, let axis, let ratio, let children):
                return .split(
                    key: Self.nodeKey(key, tab: tab, path: path), axis: axis, ratio: ratio,
                    children: children.enumerated().map { build($0.element, tab: tab, path: path + "\($0.offset + 1)") })
            }
        }
        let tabs = tabs.enumerated().map { index, tab in
            LayoutTab(key: Self.tabKey(tab, index: index), title: tab.title, color: tab.color, root: build(tab.root, tab: index, path: ""))
        }
        return Resolved(layout: LayoutDocument(windows: [LayoutWindow(key: Self.windowKey, name: name, tabs: tabs)]), commands: commands)
    }

    /// The window as a project file. `directory` gives a pane's absolute folder; folders outside the project
    /// are dropped with a warning, since a shared file can only name folders inside it. `key` keeps keys a
    /// previous file declared, so saving over it keeps matching the same panes.
    public static func export(
        window: ManagedWindow, snapshot: WorkspaceSnapshot, projectRoot: String, directory: (UUID) -> String?, command: (UUID) -> String?,
        key: (UUID) -> String? = { _ in nil }
    ) -> (file: ProjectFile, paneIDs: [UUID], warnings: [String]) {
        var warnings: [String] = [], paneIDs: [UUID] = []
        func build(_ layout: PaneLayout) -> Node {
            switch layout {
            case .pane(let id):
                paneIDs.append(id)
                let title = snapshot.panes[id]?.title
                // The format holds only local login shells; anything else reopens as one.
                switch snapshot.panes[id].flatMap({ snapshot.sessions[$0.sessionID] })?.launch {
                case .host?:
                    warnings.append("“\(title ?? "Untitled pane")” is an SSH pane; project files hold only local shells, so it will open as a local shell.")
                case .process(let executable, let arguments, _)? where arguments != ["-l"]:
                    let program = URL(fileURLWithPath: executable).lastPathComponent
                    warnings.append("“\(title ?? "Untitled pane")” runs \(program); project files hold only local shells, so it will open as a local shell.")
                default: break
                }
                var relative: String?
                if let path = directory(id).map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) {
                    if path == projectRoot {
                        relative = nil
                    } else if path.hasPrefix(projectRoot + "/"), let inside = relativeDirectory(String(path.dropFirst(projectRoot.count + 1))) {
                        relative = inside
                    } else {
                        warnings.append("“\(title ?? "Untitled pane")” is in \(path), outside the project folder, so it will open in the project folder.")
                    }
                }
                return .pane(Pane(key: key(id), title: title, directory: relative, command: command(id)))
            case .split(let id, let axis, let ratio, let children):
                return .split(key: key(id), axis: axis, ratio: (ratio * 1000).rounded() / 1000, children: children.map(build))
            }
        }
        let tabs = window.tabIDs.compactMap { snapshot.tabs[$0] }.map { tab in
            Tab(key: key(tab.id), title: tab.title, color: tab.color, root: build(tab.root))
        }
        return (ProjectFile(name: window.name, tabs: tabs), paneIDs, warnings)
    }
}

public enum ProjectFileLocator {
    /// The nearest project folder at or above `directory` holding `.trellis/project.json` (or the legacy
    /// `workspace.json`). Neither the home folder nor `/` counts as a project, and the search never leaves the
    /// home folder it started in.
    public static func projectRoot(containing directory: String, home: String, fileExists: (String) -> Bool) -> String? {
        nearestRoot(containing: directory, home: home) { ProjectFile.existingURL(projectRoot: $0, fileExists: fileExists) != nil }
    }

    /// A task project (FR-TK02): the nearest folder with a `.trellis` folder, or a `.git` folder or file (worktrees
    /// and submodules use a file), within the same bounds.
    public static func taskRoot(containing directory: String, home: String, exists: (String) -> Bool) -> String? {
        nearestRoot(containing: directory, home: home) { exists($0 + "/" + ProjectFile.directoryName) || exists($0 + "/.git") }
    }

    /// The nearest folder at or above `directory` that `matches`, excluding home and `/`, never leaving home.
    public static func nearestRoot(containing directory: String, home: String, matches: (String) -> Bool) -> String? {
        guard directory.hasPrefix("/") else { return nil }
        let home = URL(fileURLWithPath: home).standardizedFileURL.path
        var current = URL(fileURLWithPath: directory).standardizedFileURL.path
        let underHome = current.hasPrefix(home + "/")
        while current != "/", current != home {
            if matches(current) { return current }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || (underHome && !parent.hasPrefix(home)) { return nil }
            current = parent
        }
        return nil
    }
}

/// Trusted (project folder, file digest) pairs and folders the user never wants offered (FR-WF03).
/// A folder holds one trusted digest: trusting a new version replaces the old one.
public struct ProjectTrustList: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let root: String, sha256: String
        public init(root: String, sha256: String) { self.root = root; self.sha256 = sha256 }
    }
    public static let maximumEntries = 1000
    public var version = 1
    public private(set) var trusted: [Entry] = []
    public private(set) var ignored: [String] = []
    public init() {}

    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public func isTrusted(root: String, digest: String) -> Bool { trusted.contains(Entry(root: root, sha256: digest)) }
    /// A different version of this folder's file was trusted before.
    public func trustedOtherVersion(root: String, digest: String) -> Bool { trusted.contains { $0.root == root && $0.sha256 != digest } }
    public func isIgnored(_ root: String) -> Bool { ignored.contains(root) }

    public mutating func trust(root: String, digest: String) {
        trusted.removeAll { $0.root == root }
        trusted.append(Entry(root: root, sha256: digest))
        if trusted.count > Self.maximumEntries { trusted.removeFirst(trusted.count - Self.maximumEntries) }
    }

    public mutating func setIgnored(_ root: String, _ value: Bool) {
        ignored.removeAll { $0 == root }
        if value { ignored.append(root) }
        if ignored.count > Self.maximumEntries { ignored.removeFirst(ignored.count - Self.maximumEntries) }
    }
}
