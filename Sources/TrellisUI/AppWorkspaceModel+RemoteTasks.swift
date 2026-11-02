import CryptoKit
import Foundation
import TrellisBroker
import TrellisControl
import TrellisCore

/// Tasks on a remote workspace's host (FR-RW11): found, read and trusted with the same rules as local ones, through the
/// host's helper. Trellis never writes a host's task files.
extension AppWorkspaceModel {
    /// Whether a new shell on `hostID` reports its first prompt, so a queued command can wait for it.
    func remoteShellGetsIntegration(_ hostID: UUID) -> Bool {
        guard shellIntegrationEnabled, let shell = remoteHosts?.workspaceConnection(hostID)?.hostInfo?.shell else { return false }
        return ShellIntegrationKind(executable: shell) != nil
    }

    /// Trust for a folder on a host: the host, the machine behind it and the folder's real path, so the
    /// same file on two hosts, or a host name that now reaches another machine, asks again.
    func remoteTrustKey(_ hostID: UUID, root: String, connection: BrokerConnection) -> String {
        let machine = connection.hostInfo?.machineID.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16) } ?? "unknown"
        return "remote:\(hostID.uuidString):\(machine):\(root)"
    }

    /// FR-TK02/FR-TK03 on a host: the project's `launch.json` and the tasks detected from its manifests.
    func loadRemoteTaskCatalog(directory: String, hostID: UUID, paneID: UUID) async -> TaskCatalog? {
        guard let connection = remoteHosts?.workspaceConnection(hostID), let home = connection.hostInfo?.home else { return nil }
        let facts = RemoteFacts(connection: connection)
        let found = await facts.evaluate { ProjectLocator.taskRoot(containing: directory, home: home, exists: $0.exists) }
        guard let found, let entry = await facts.entry(found) else { return nil }
        let root = entry.realPath ?? found
        let state: TaskCatalog.FileState
        var data: Data?
        switch await facts.read(LaunchFile.url(projectRoot: root).path, limit: LaunchFile.maximumBytes) {
        case .failure(.missing): state = .missing
        case .failure: state = .invalid("launch.json must be a regular file you own, at most 64 KB, and not a symbolic link.")
        case .success(let read):
            data = read
            switch LaunchFileJSON.parse(read) {
            case .success(let file): state = .loaded(file)
            case .failure(let error): state = .invalid(LaunchFileJSON.describe(error))
            }
        }
        let detected = await facts.evaluate { lookup in
            TaskDetector.detect(read: { name, limit in lookup.read(root + "/" + name, limit) }, exists: { lookup.exists(root + "/" + $0) })
        }
        return TaskCatalog(
            root: root, paneID: paneID, file: state, data: data, detected: detected, hostID: hostID,
            trustKey: remoteTrustKey(hostID, root: root, connection: connection))
    }
}
