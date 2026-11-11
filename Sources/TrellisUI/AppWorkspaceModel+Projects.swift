import Foundation
import TrellisCore

/// The project library's view of the workspace (FR-PL04, FR-PL06–FR-PL08).
extension AppWorkspaceModel {
    /// A project made from an open space: local folders, or a remote workspace's folders on its host.
    public func captureProject(spaceID: UUID) -> ProjectCapture? {
        guard let space = snapshot.spaces.first(where: { $0.id == spaceID }) else { return nil }
        guard let hostID = space.remoteHostID else {
            return ProjectCapture.capture(space: spaceID, snapshot: snapshot, home: FileManager.default.homeDirectoryForCurrentUser.path) { self.paneDirectory($0) }
        }
        let home = remoteHosts?.workspaceConnection(hostID)?.hostInfo?.home
        return ProjectCapture.capture(space: spaceID, snapshot: snapshot, home: home) { paneID in
            if let directory = self.remoteWorkingDirectory(paneID: paneID) { return directory }
            switch self.snapshot.panes[paneID].flatMap({ self.snapshot.sessions[$0.sessionID] })?.launch {
            case .remoteShell(_, let directory)?: return directory
            case .agent(let agent)?: return agent.directory
            default: return nil
            }
        }
    }

    /// The folder each open project space was launched in (FR-W08), as the launch remembers it: absolute on this Mac,
    /// relative to home on a host. Read from the launch's binding namespace (`project:<id>:<target>:<root>`); a host's
    /// root is made relative with its home when its link knows it, else with the folders the project remembers there.
    func projectSpaceFolders() -> [UUID: String] {
        // Loads the bindings file once; an unreadable one gives no folders.
        guard (try? layoutBindings("")) != nil, let namespaces = layoutNamespaces else { return [:] }
        let spaces = Dictionary(snapshot.spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projects = Dictionary(commandPaletteProjects().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var folders: [UUID: String] = [:]
        for (namespace, bindings) in namespaces where namespace.hasPrefix("project:") {
            let parts = namespace.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, let spaceID = bindings[ProjectLaunch.spaceKey()]?.id, let space = spaces[spaceID],
                space.projectID.map({ $0.uuidString == parts[1] }) == true, let target = ProjectTarget(key: parts[2])
            else { continue }
            let root = parts[3]
            switch target {
            case .local: folders[spaceID] = root
            case .host(let hostID):
                if let home = remoteHosts?.workspaceConnection(hostID)?.hostInfo?.home, root.hasPrefix(home + "/") {
                    folders[spaceID] = String(root.dropFirst(home.count + 1))
                } else if let remembered = space.projectID.flatMap({ projects[$0]?.lastFolders[target.key] }), root.hasSuffix("/" + remembered) {
                    folders[spaceID] = remembered
                }
            }
        }
        return folders
    }
}
