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
}
