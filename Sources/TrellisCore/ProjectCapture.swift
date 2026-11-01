import Foundation

/// A library project made from an open sidebar window (FR-PL04).
public struct ProjectCapture: Equatable, Sendable {
    public var project: ProjectDefinition
    public var warnings: [String]
    public init(project: ProjectDefinition, warnings: [String]) { self.project = project; self.warnings = warnings }

    /// Tabs, titles, colors, splits and ratios are copied; the project folder becomes the panes' nearest common folder,
    /// remembered as the last folder for the window's target. `directory` gives a pane's absolute folder (on the host
    /// for a remote workspace) and `home` that target's home. Commands are never captured. Nil when the window is gone.
    public static func capture(window id: UUID, snapshot: WorkspaceSnapshot, home: String?, directory: (UUID) -> String?) -> ProjectCapture? {
        guard let window = snapshot.windows.first(where: { $0.id == id }) else { return nil }
        var warnings: [String] = []
        let folders = Dictionary(
            uniqueKeysWithValues: window.tabIDs.compactMap { snapshot.tabs[$0] }.flatMap(\.root.paneIDs).compactMap { pane in
                // A relative path would resolve against this process's folder, which means nothing on a host.
                directory(pane).flatMap { $0.hasPrefix("/") ? $0 : nil }.map { (pane, URL(fileURLWithPath: $0).standardizedFileURL.path) }
            })
        let root = commonFolder(Array(folders.values))
        func node(_ layout: PaneLayout, tab: WorkspaceTab) -> ProjectNode {
            switch layout {
            case .pane(let id):
                let title = snapshot.panes[id]?.title
                switch snapshot.panes[id].flatMap({ snapshot.sessions[$0.sessionID] })?.launch {
                case .host?: warnings.append("“\(title ?? "Untitled pane")” in “\(tab.title)” is an SSH pane; it becomes a shell in the project.")
                case .process(let executable, let arguments, _)? where arguments != ["-l"]:
                    warnings.append("“\(title ?? "Untitled pane")” in “\(tab.title)” runs \(URL(fileURLWithPath: executable).lastPathComponent); it becomes a shell in the project.")
                default: break
                }
                var relative: String?
                if let root, let folder = folders[id], folder != root { relative = String(folder.dropFirst(root == "/" ? 1 : root.count + 1)) }
                if let candidate = relative, GitRepository.folder(candidate) == nil {
                    warnings.append("The folder of “\(title ?? "Untitled pane")” in “\(tab.title)” can't be used in a project, so it starts in the project folder.")
                    relative = nil
                }
                // FR-PL10: an agent pane stays one; its command line is rebuilt at launch, so only the ID is kept.
                let agent = snapshot.panes[id].flatMap { snapshot.sessions[$0.sessionID] }?.launch.agent?.agentID
                return .pane(ProjectPane(title: title, directory: relative, agent: agent))
            case .split(_, let axis, let ratio, let children) where children.count == 2:
                return .split(axis: axis, ratio: min(0.9, max(0.1, (ratio * 1000).rounded() / 1000)), first: node(children[0], tab: tab), second: node(children[1], tab: tab))
            case .split(_, _, _, let children):
                return children.first.map { node($0, tab: tab) } ?? .pane(ProjectPane())
            }
        }
        let tabs = window.tabIDs.compactMap { snapshot.tabs[$0] }.map { tab in ProjectTab(title: tab.title, color: tab.color, root: node(tab.root, tab: tab)) }
        guard !tabs.isEmpty else { return nil }
        let target: ProjectTarget = window.remoteHostID.map { .host($0) } ?? .local
        var lastFolders: [String: String] = [:]
        // A common folder of "/" or the home folder isn't a project folder: launching asks for one instead.
        if let root, root != "/", root != home {
            switch target {
            case .local: lastFolders[target.key] = root
            case .host:
                // Folders on a host are kept relative to its home (FR-PL06); one outside it isn't remembered.
                if let home, root.hasPrefix(home + "/") { lastFolders[target.key] = String(root.dropFirst(home.count + 1)) }
            }
        }
        if root == "/" || (root != nil && root == home) {
            warnings.append("The panes have no project folder in common, so launching asks where the project goes; their folders are kept relative to \(root!).")
        }
        let name = String(window.name.prefix(200)).trimmingCharacters(in: .whitespaces)
        return ProjectCapture(project: ProjectDefinition(name: name.isEmpty ? "Project" : name, tabs: tabs, lastFolders: lastFolders), warnings: warnings)
    }

    /// The deepest folder containing every path; nil when there are none.
    static func commonFolder(_ paths: [String]) -> String? {
        guard var common = paths.first?.split(separator: "/").map(String.init) else { return nil }
        for path in paths.dropFirst() {
            let parts = path.split(separator: "/").map(String.init)
            common = Array(zip(common, parts).prefix { $0 == $1 }.map(\.0))
        }
        return "/" + common.joined(separator: "/")
    }
}
