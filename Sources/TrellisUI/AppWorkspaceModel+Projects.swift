import Foundation
import TrellisCore

/// The project library's view of the workspace (FR-PL04, FR-PL06–FR-PL08).
extension AppWorkspaceModel {
    /// A project made from an open window: local folders, or a remote workspace's folders on its host.
    public func captureProject(windowID: UUID) -> ProjectCapture? {
        guard let window = snapshot.windows.first(where: { $0.id == windowID }) else { return nil }
        guard let hostID = window.remoteHostID else {
            return ProjectCapture.capture(window: windowID, snapshot: snapshot, home: FileManager.default.homeDirectoryForCurrentUser.path) { self.paneDirectory($0) }
        }
        let home = remoteHosts?.workspaceConnection(hostID)?.hostInfo?.home
        return ProjectCapture.capture(window: windowID, snapshot: snapshot, home: home) { paneID in
            if let directory = self.remoteWorkingDirectory(paneID: paneID) { return directory }
            guard case .remoteShell(_, let directory)? = self.snapshot.panes[paneID].flatMap({ self.snapshot.sessions[$0.sessionID] })?.launch else { return nil }
            return directory
        }
    }
}
