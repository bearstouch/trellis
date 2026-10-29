import CryptoKit
import Foundation
import TrellisBroker
import TrellisControl
import TrellisCore

/// Project files and tasks on a remote workspace's host (FR-RW10, FR-RW11): found, read and trusted with the same
/// rules as local ones, through the host's helper. Trellis never writes a host's files in this version.
extension AppWorkspaceModel {
    /// Whether a new shell on `hostID` reports its first prompt, so a project command can wait for it.
    func remoteShellGetsIntegration(_ hostID: UUID) -> Bool {
        guard shellIntegrationEnabled, let shell = remoteHosts?.workspaceConnection(hostID)?.hostInfo?.shell else { return false }
        return ShellIntegrationKind(executable: shell) != nil
    }

    /// Trust and "don't offer" for a folder on a host: the host, the machine behind it and the folder's real path, so the
    /// same file on two hosts, or a host name that now reaches another machine, asks again.
    func remoteTrustKey(_ hostID: UUID, root: String, connection: BrokerConnection) -> String {
        let machine = connection.hostInfo?.machineID.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16) } ?? "unknown"
        return "remote:\(hostID.uuidString):\(machine):\(root)"
    }

    /// FR-WF02 on a host: looks above a remote pane's new directory; a newer directory wins.
    func detectRemoteProjectFile(paneID: UUID, hostID: UUID, directory: String) {
        guard projectFileLookups[paneID] != directory else { return }
        pruneProjectFileState()
        projectFileLookups[paneID] = directory
        Task { [weak self] in
            guard let self else { return }
            guard let connection = self.remoteHosts?.workspaceConnection(hostID), let home = connection.hostInfo?.home else {
                // Nothing is known about this directory: no stale offer from the last one, and the next report looks again.
                if self.projectFileLookups[paneID] == directory { self.projectFileLookups[paneID] = nil; self.projectFileOffers[paneID] = nil }
                return
            }
            let facts = RemoteFacts(connection: connection)
            let offer = await self.remoteProjectOffer(facts: facts, directory: directory, home: home, hostID: hostID)
            guard self.projectFileLookups[paneID] == directory else { return }
            if self.projectFileOffers[paneID] != offer { self.projectFileOffers[paneID] = offer }
        }
    }

    private func remoteProjectOffer(facts: RemoteFacts, directory: String, home: String, hostID: UUID) async -> ProjectFileOffer? {
        let found = await facts.evaluate { ProjectFileLocator.projectRoot(containing: directory, home: home, fileExists: $0.exists) }
        guard let found, let entry = await facts.entry(found) else { return nil }
        let root = entry.realPath ?? found
        let path = await facts.evaluate { lookup in ProjectFile.existingURL(projectRoot: root, fileExists: lookup.exists)?.path }
        // As locally: only a regular file the user owns, never through a symlink, is offered.
        guard let path, case .success(let data) = await facts.read(path, limit: ProjectFile.maximumBytes) else { return nil }
        let name = try? ProjectFileJSON.parse(data).get().name
        return ProjectFileOffer(
            root: root, name: name ?? URL(fileURLWithPath: root).lastPathComponent, path: path, hostID: hostID,
            trustKey: remoteTrustKey(hostID, root: root, connection: facts.connection))
    }

    /// Opens an offer: a local one as before, a remote one by reading the host's file through the link (FR-RW10).
    public func loadProjectFile(offer found: ProjectFileOffer) async {
        guard let hostID = found.hostID else { return await loadProjectFile(root: found.root) }
        guard projectFileCanOpen() else { return }
        guard let connection = remoteHosts?.workspaceConnection(hostID) else {
            errorMessage = "\(remoteHostName(hostID)) isn't connected, so its project file can't be opened. Reconnect, then try again."
            return
        }
        // Trust is checked and recorded for the machine these bytes are read from, which a reconnect may have changed.
        let offer = ProjectFileOffer(
            root: found.root, name: found.name, path: found.path, hostID: hostID, trustKey: remoteTrustKey(hostID, root: found.root, connection: connection))
        let data: Data
        switch await RemoteFacts(connection: connection).read(offer.path, limit: ProjectFile.maximumBytes) {
        case .success(let read): data = read
        case .failure(.missing):
            errorMessage = "There is no \(ProjectFile.directoryName)/\(ProjectFile.fileName) in \(offer.root) on \(remoteHostName(hostID))."
            return
        case .failure:
            errorMessage = "\(ProjectFile.directoryName)/\(URL(fileURLWithPath: offer.path).lastPathComponent) on \(remoteHostName(hostID)) must be a regular file you own, at most 256 KB, and not a symbolic link."
            return
        }
        let file: ProjectFile
        switch ProjectFileJSON.parse(data) {
        case .success(let parsed): file = parsed
        case .failure(let error):
            errorMessage = "The project file can't be opened: " + error.text
            return
        }
        let plan: LayoutPlan
        do { plan = try await planProjectFile(file, root: offer.root, hostID: hostID, namespace: offer.namespace) } catch {
            errorMessage = error.localizedDescription
            return
        }
        let digest = ProjectTrustList.digest(data)
        let trust = try? projectTrustList()
        let review = ProjectFileReview(
            root: offer.root, file: file, digest: digest, changedSinceTrusted: trust?.trustedOtherVersion(root: offer.trustKey, digest: digest) ?? false,
            warnings: plan.warnings.map(\.message), path: offer.path, hostID: hostID, hostName: remoteHostName(hostID), trustKey: offer.trustKey)
        guard file.hasCommands, trust?.isTrusted(root: offer.trustKey, digest: digest) != true else {
            await openReviewedProjectFile(review, runCommands: file.hasCommands)
            return
        }
        pendingProjectReview = review
    }

    /// FR-TK02/FR-TK03 on a host: the project's `launch.json` and the tasks detected from its manifests.
    func loadRemoteTaskCatalog(directory: String, hostID: UUID, paneID: UUID) async -> TaskCatalog? {
        guard let connection = remoteHosts?.workspaceConnection(hostID), let home = connection.hostInfo?.home else { return nil }
        let facts = RemoteFacts(connection: connection)
        let found = await facts.evaluate { ProjectFileLocator.taskRoot(containing: directory, home: home, exists: $0.exists) }
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
