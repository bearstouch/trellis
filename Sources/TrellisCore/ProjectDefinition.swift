import Foundation

/// A pane of a library project (FR-PL02): its title, folder relative to the project folder, the command typed at its
/// first prompt, and a repository its folder is a checkout of.
public struct ProjectPane: Codable, Equatable, Sendable {
    public var title: String?
    public var directory: String?
    public var command: String?
    public var repository: ProjectRepository?
    public init(title: String? = nil, directory: String? = nil, command: String? = nil, repository: ProjectRepository? = nil) {
        self.title = title; self.directory = directory; self.command = command; self.repository = repository
    }
}

/// A tab's layout: a pane, or a split of exactly two nodes where `ratio` is the first one's share.
public indirect enum ProjectNode: Equatable, Sendable {
    case pane(ProjectPane)
    case split(axis: SplitAxis, ratio: Double, first: ProjectNode, second: ProjectNode)

    /// Panes in display order, with their paths (0 = first child, 1 = second).
    public var panes: [(path: [Int], pane: ProjectPane)] {
        switch self {
        case .pane(let pane): [([], pane)]
        case .split(_, _, let first, let second): first.panes.map { ([0] + $0.path, $0.pane) } + second.panes.map { ([1] + $0.path, $0.pane) }
        }
    }

    public var depth: Int {
        switch self {
        case .pane: 0
        case .split(_, _, let first, let second): 1 + max(first.depth, second.depth)
        }
    }

    public subscript(path: [Int]) -> ProjectNode? {
        guard let step = path.first else { return self }
        guard case .split(_, _, let first, let second) = self, step == 0 || step == 1 else { return nil }
        return (step == 0 ? first : second)[Array(path.dropFirst())]
    }

    /// The node with the one at `path` replaced; unchanged when `path` doesn't exist.
    public func replacing(_ path: [Int], with node: ProjectNode) -> ProjectNode {
        guard let step = path.first else { return node }
        guard case .split(let axis, let ratio, let first, let second) = self else { return self }
        let rest = Array(path.dropFirst())
        return step == 0
            ? .split(axis: axis, ratio: ratio, first: first.replacing(rest, with: node), second: second)
            : .split(axis: axis, ratio: ratio, first: first, second: second.replacing(rest, with: node))
    }
}

extension ProjectNode: Codable {
    private enum Keys: String, CodingKey { case type, title, directory, command, repository, axis, ratio, children }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "pane":
            self = .pane(
                ProjectPane(
                    title: try values.decodeIfPresent(String.self, forKey: .title), directory: try values.decodeIfPresent(String.self, forKey: .directory),
                    command: try values.decodeIfPresent(String.self, forKey: .command), repository: try values.decodeIfPresent(ProjectRepository.self, forKey: .repository)))
        case "split":
            let children = try values.decode([ProjectNode].self, forKey: .children)
            guard children.count == 2 else { throw DecodingError.dataCorruptedError(forKey: .children, in: values, debugDescription: "A split has two children.") }
            self = .split(
                axis: try values.decode(SplitAxis.self, forKey: .axis), ratio: try values.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5, first: children[0],
                second: children[1])
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: values, debugDescription: "A node is a pane or a split.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        switch self {
        case .pane(let pane):
            try values.encode("pane", forKey: .type)
            try values.encodeIfPresent(pane.title, forKey: .title)
            try values.encodeIfPresent(pane.directory, forKey: .directory)
            try values.encodeIfPresent(pane.command, forKey: .command)
            try values.encodeIfPresent(pane.repository, forKey: .repository)
        case .split(let axis, let ratio, let first, let second):
            try values.encode("split", forKey: .type)
            try values.encode(axis, forKey: .axis)
            try values.encode(ratio, forKey: .ratio)
            try values.encode([first, second], forKey: .children)
        }
    }
}

public struct ProjectTab: Codable, Equatable, Sendable {
    public var title: String
    public var color: TabColor?
    /// Where the tab's panes without a folder start, relative to the project folder.
    public var directory: String?
    /// Makes `directory` a checkout.
    public var repository: ProjectRepository?
    public var root: ProjectNode
    public init(title: String, color: TabColor? = nil, directory: String? = nil, repository: ProjectRepository? = nil, root: ProjectNode = .pane(ProjectPane())) {
        self.title = title; self.color = color; self.directory = directory; self.repository = repository; self.root = root
    }
}

/// Where a project runs (FR-PL06): this Mac, or a saved host.
public enum ProjectTarget: Hashable, Sendable {
    case local
    case host(UUID)
    /// How it is stored in `lastFolders` and bindings.
    public var key: String {
        switch self {
        case .local: "local"
        case .host(let id): id.uuidString
        }
    }
    public init?(key: String) {
        if key == "local" { self = .local } else if let id = UUID(uuidString: key) { self = .host(id) } else { return nil }
    }
}

/// A project in the library (FR-PL02): a workspace defined once and launched on any target.
public struct ProjectDefinition: Codable, Equatable, Identifiable, Sendable {
    public static let maximumTabs = 50
    public static let maximumPanes = 100
    public static let maximumDepth = 16
    public static let maximumNotes = 4000

    public var id: UUID
    public var name: String
    public var notes: String?
    /// The project folder itself is a checkout of this repository.
    public var repository: ProjectRepository?
    public var tabs: [ProjectTab]
    /// The folder last launched per target (`ProjectTarget.key`); written by launches, never by the editor.
    public var lastFolders: [String: String]
    /// Set from the library's counter on every save; an editor's save must start from the stored one.
    public var revision: UInt64

    public init(
        id: UUID = UUID(), name: String, notes: String? = nil, repository: ProjectRepository? = nil, tabs: [ProjectTab] = [ProjectTab(title: "Shell")],
        lastFolders: [String: String] = [:], revision: UInt64 = 0
    ) {
        self.id = id; self.name = name; self.notes = notes; self.repository = repository; self.tabs = tabs; self.lastFolders = lastFolders; self.revision = revision
    }

    public var paneCount: Int { tabs.reduce(0) { $0 + $1.root.panes.count } }
    public var commandCount: Int { tabs.reduce(0) { $0 + $1.root.panes.filter { $0.pane.command != nil }.count } }

    /// Every repository with its folder relative to the project folder ("" for the project folder), project first,
    /// then by tab; a folder named twice with the same repository is listed once.
    public var checkouts: [(folder: String, repository: ProjectRepository)] {
        var result: [(String, ProjectRepository)] = []
        func add(_ folder: String?, _ repository: ProjectRepository?) {
            guard let repository, let folder = folder.flatMap(GitRepository.folder), !result.contains(where: { $0.0 == folder && $0.1 == repository }) else { return }
            result.append((folder, repository))
        }
        add(".", repository)
        for tab in tabs {
            add(tab.directory, tab.repository)
            for entry in tab.root.panes { add(entry.pane.directory, entry.pane.repository) }
        }
        return result
    }

    /// The folder a pane starts in, relative to the project folder: its own, else its tab's, else the project folder.
    public static func folder(of pane: ProjectPane, in tab: ProjectTab) -> String {
        (pane.directory ?? tab.directory).flatMap(GitRepository.folder) ?? ""
    }

    // MARK: Validation

    /// Where a problem is, so the form can show it next to the field.
    public enum Place: Hashable, Sendable {
        case project
        case tab(Int)
        case node(tab: Int, path: [Int])
    }

    public enum Field: String, Sendable { case name, notes, title, directory, command, repositoryURL, repositoryBranch, layout }

    public struct Issue: Equatable, Sendable {
        public let place: Place, field: Field, message: String
        public init(_ place: Place, _ field: Field, _ message: String) { self.place = place; self.field = field; self.message = message }
    }

    public var issues: [Issue] {
        var issues: [Issue] = []
        if let problem = ProjectText.textProblem(name, limit: 200) { issues.append(Issue(.project, .name, "The name \(problem)")) }
        if let notes, notes.count > Self.maximumNotes || notes.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" }) {
            issues.append(Issue(.project, .notes, "Notes are limited to \(Self.maximumNotes) characters without control characters."))
        }
        issues += Self.repositoryIssues(repository, at: .project)
        if tabs.isEmpty || tabs.count > Self.maximumTabs { issues.append(Issue(.project, .layout, "A project has 1–\(Self.maximumTabs) tabs.")) }
        if paneCount > Self.maximumPanes { issues.append(Issue(.project, .layout, "A project has at most \(Self.maximumPanes) panes.")) }
        var folders: [String: ProjectRepository] = [:]
        if let repository { folders[""] = repository }
        func claim(_ folder: String, _ repository: ProjectRepository, at place: Place) {
            if let other = folders[folder], other != repository {
                issues.append(Issue(place, .repositoryURL, "\(folder.isEmpty ? "The project folder" : folder) already has another repository or branch."))
            }
            folders[folder] = folders[folder] ?? repository
        }
        for (index, tab) in tabs.enumerated() {
            let place = Place.tab(index)
            if let problem = ProjectText.textProblem(tab.title, limit: 200) { issues.append(Issue(place, .title, "The title \(problem)")) }
            if tab.root.depth > Self.maximumDepth { issues.append(Issue(place, .layout, "Splits nest at most \(Self.maximumDepth) levels.")) }
            let tabFolder = tab.directory.flatMap(GitRepository.folder)
            if tab.directory != nil, tabFolder == nil { issues.append(Issue(place, .directory, Self.folderRule)) }
            issues += Self.repositoryIssues(tab.repository, at: place)
            if let repository = tab.repository {
                if let tabFolder, !tabFolder.isEmpty {
                    claim(tabFolder, repository, at: place)
                } else if tab.directory == nil || tabFolder != nil {
                    issues.append(Issue(place, .directory, "A tab's repository needs a folder inside the project folder."))
                }
            }
            issues += nodeIssues(tab.root, tab: index, path: [], claim: claim)
        }
        return issues
    }

    private func nodeIssues(_ node: ProjectNode, tab: Int, path: [Int], claim: (String, ProjectRepository, Place) -> Void) -> [Issue] {
        let place = Place.node(tab: tab, path: path)
        switch node {
        case .split(_, let ratio, let first, let second):
            let ratioIssue = (0.1...0.9).contains(ratio) ? [] : [Issue(place, .layout, "A split's ratio is between 0.1 and 0.9.")]
            return ratioIssue + nodeIssues(first, tab: tab, path: path + [0], claim: claim) + nodeIssues(second, tab: tab, path: path + [1], claim: claim)
        case .pane(let pane):
            var issues: [Issue] = []
            if let title = pane.title, let problem = ProjectText.textProblem(title, limit: 200) { issues.append(Issue(place, .title, "The title \(problem)")) }
            let folder = pane.directory.flatMap(GitRepository.folder)
            if pane.directory != nil, folder == nil { issues.append(Issue(place, .directory, Self.folderRule)) }
            if let command = pane.command, let problem = ProjectText.commandProblem(command) { issues.append(Issue(place, .command, "The command \(problem)")) }
            issues += Self.repositoryIssues(pane.repository, at: place)
            if let repository = pane.repository {
                if let folder, !folder.isEmpty {
                    claim(folder, repository, place)
                } else if pane.directory == nil || folder != nil {
                    issues.append(Issue(place, .directory, "A pane's repository needs a folder inside the project folder."))
                }
            }
            return issues
        }
    }

    static let folderRule = "Use a folder inside the project, without .., ~, $, backticks, quotes, backslashes or !."

    private static func repositoryIssues(_ repository: ProjectRepository?, at place: Place) -> [Issue] {
        guard let repository else { return [] }
        var issues: [Issue] = []
        if let problem = GitRepository.urlProblem(repository.url) { issues.append(Issue(place, .repositoryURL, problem)) }
        if let branch = repository.branch, let problem = GitRepository.branchProblem(branch) { issues.append(Issue(place, .repositoryBranch, problem)) }
        return issues
    }

    // MARK: Editing (FR-PL02)

    /// A new tab with one pane, after the last.
    public mutating func addTab() -> Int {
        tabs.append(ProjectTab(title: "Tab \(tabs.count + 1)"))
        return tabs.count - 1
    }

    /// Splits the pane at `path` into it and a new pane; returns the new pane's path.
    @discardableResult
    public mutating func split(tab: Int, path: [Int], axis: SplitAxis) -> [Int]? {
        guard tabs.indices.contains(tab), case .pane(let pane)? = tabs[tab].root[path] else { return nil }
        tabs[tab].root = tabs[tab].root.replacing(path, with: .split(axis: axis, ratio: 0.5, first: .pane(pane), second: .pane(ProjectPane())))
        return path + [1]
    }

    /// Removes the node at `path`, its sibling taking the split's place; an empty path removes the tab. The last tab and
    /// a tab's last pane stay. Returns where the selection goes.
    @discardableResult
    public mutating func remove(tab: Int, path: [Int]) -> Place? {
        guard tabs.indices.contains(tab) else { return nil }
        guard let last = path.last else {
            guard tabs.count > 1 else { return nil }
            tabs.remove(at: tab)
            return .tab(min(tab, tabs.count - 1))
        }
        let parent = Array(path.dropLast())
        guard case .split(_, _, let first, let second)? = tabs[tab].root[parent] else { return nil }
        tabs[tab].root = tabs[tab].root.replacing(parent, with: last == 0 ? second : first)
        return .node(tab: tab, path: parent)
    }

    public mutating func moveTab(_ index: Int, by offset: Int) -> Int {
        let target = index + offset
        guard tabs.indices.contains(index), tabs.indices.contains(target) else { return index }
        tabs.swapAt(index, target)
        return target
    }

    public mutating func updatePane(tab: Int, path: [Int], _ change: (inout ProjectPane) -> Void) {
        guard tabs.indices.contains(tab), case .pane(var pane)? = tabs[tab].root[path] else { return }
        change(&pane)
        tabs[tab].root = tabs[tab].root.replacing(path, with: .pane(pane))
    }

    public mutating func updateSplit(tab: Int, path: [Int], axis: SplitAxis, ratio: Double) {
        guard tabs.indices.contains(tab), case .split(_, _, let first, let second)? = tabs[tab].root[path] else { return }
        tabs[tab].root = tabs[tab].root.replacing(path, with: .split(axis: axis, ratio: ratio, first: first, second: second))
    }

    /// The project with optional text fields that are blank set to nil, as the form saves it.
    public var normalized: ProjectDefinition {
        func clean(_ text: String?) -> String? {
            guard let text else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        // A repository the form turned on keeps an empty URL, so validation asks for one instead of dropping it.
        func clean(_ repository: ProjectRepository?) -> ProjectRepository? {
            repository.map { ProjectRepository(url: $0.url.trimmingCharacters(in: .whitespaces), branch: clean($0.branch)) }
        }
        func clean(_ node: ProjectNode) -> ProjectNode {
            switch node {
            case .pane(let pane):
                .pane(ProjectPane(title: clean(pane.title), directory: clean(pane.directory), command: clean(pane.command), repository: clean(pane.repository)))
            case .split(let axis, let ratio, let first, let second): .split(axis: axis, ratio: ratio, first: clean(first), second: clean(second))
            }
        }
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespaces)
        copy.notes = notes.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        copy.repository = clean(repository)
        copy.tabs = tabs.map { tab in
            ProjectTab(title: tab.title.trimmingCharacters(in: .whitespaces), color: tab.color, directory: clean(tab.directory), repository: clean(tab.repository), root: clean(tab.root))
        }
        return copy
    }
}
