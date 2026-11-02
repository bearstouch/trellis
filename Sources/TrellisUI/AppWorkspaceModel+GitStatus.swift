import Foundation
import TrellisBroker
import TrellisCore

/// Git status in pane headers (FR-PL09): looked at when a shell shows its prompt (after a `cd` or a command), at most one
/// check per pane at a time, on this Mac or by the host's helper. Only the branch and counts are kept.
extension AppWorkspaceModel {
    func refreshGitStatus(paneID: UUID) {
        guard gitStatusEnabled else { return }
        guard !gitStatusInFlight.contains(paneID) else { gitStatusAgain.insert(paneID); return }
        let request: (directory: String, hostID: UUID?)
        if let directory = currentDirectory(paneID: paneID) {
            request = (directory, nil)
        } else if let directory = remoteWorkingDirectory(paneID: paneID), let pane = snapshot.panes[paneID],
            let hostID = snapshot.sessions[pane.sessionID]?.launch.remoteHostID
        {
            request = (directory, hostID)
        } else {
            if gitStatuses[paneID] != nil { gitStatuses[paneID] = nil }
            return
        }
        gitStatusInFlight.insert(paneID)
        let directory = request.directory, hostID = request.hostID
        Task { [weak self] in await self?.finishGitStatus(paneID: paneID, directory: directory, hostID: hostID) }
    }

    private func finishGitStatus(paneID: UUID, directory: String, hostID: UUID?) async {
        let status = await fetchGitStatus(directory: directory, hostID: hostID)
        gitStatusInFlight.remove(paneID)
        if snapshot.panes[paneID] == nil {
            gitStatuses[paneID] = nil
        } else if gitStatuses[paneID] != status {
            gitStatuses[paneID] = status
        }
        if gitStatusAgain.remove(paneID) != nil { refreshGitStatus(paneID: paneID) }
    }

    private func fetchGitStatus(directory: String, hostID: UUID?) async -> BrokerGitStatus? {
        guard let hostID else {
            let runner = gitStatusRunner
            return await Task.detached(priority: .utility) { runner(directory) }.value
        }
        // A helper older than protocol 3 doesn't know the request; its panes show no status.
        guard let connection = remoteHosts?.workspaceConnection(hostID), connection.protocolVersion >= 3,
            case .gitState(let found)? = try? await connection.request(.gitStatus(path: directory))
        else { return nil }
        return found
    }

    /// "main ●2 ↑1" for the header.
    nonisolated static func gitStatusText(_ status: BrokerGitStatus) -> String {
        var parts = [status.branch ?? status.commit.map { "(\($0))" } ?? "(no commit)"]
        if status.changes > 0 { parts.append("●\(status.changes)") }
        if status.ahead > 0 { parts.append("↑\(status.ahead)") }
        if status.behind > 0 { parts.append("↓\(status.behind)") }
        return parts.joined(separator: " ")
    }

    /// "Git branch main, 2 changes, 1 ahead" for VoiceOver.
    nonisolated static func gitStatusSpoken(_ status: BrokerGitStatus) -> String {
        var parts = [status.branch.map { "Git branch \($0)" } ?? status.commit.map { "Git commit \($0), detached" } ?? "Git, no commits yet"]
        if status.changes > 0 { parts.append("\(status.changes) change\(status.changes == 1 ? "" : "s")") }
        if status.ahead > 0 { parts.append("\(status.ahead) ahead") }
        if status.behind > 0 { parts.append("\(status.behind) behind") }
        return parts.joined(separator: ", ")
    }
}
