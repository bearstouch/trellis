import Foundation
import TrellisControl
import TrellisCore

/// Helpers shared by tasks, the scratchpad and project launches: trust files, pane folders, repository files and the
/// commands typed into new shells once they are ready.
extension AppWorkspaceModel {
    nonisolated static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    /// A stored trust list, or an empty one when there is none. Unreadable, invalid or newer lists throw `failure`:
    /// rewriting a newer one would drop what this version doesn't know.
    static func readTrustList(_ url: URL?, failure: String) throws -> ProjectTrustList {
        do {
            let stored = try url.flatMap { try OwnerOnlyFile.read($0, limit: 4_194_304) }
            let list = try stored.map { try JSONDecoder().decode(ProjectTrustList.self, from: $0) } ?? ProjectTrustList()
            guard list.version == ProjectTrustList().version else { throw ProjectSupportFailure(failure) }
            return list
        } catch { throw ProjectSupportFailure(failure) }
    }

    static func writeTrustList(_ list: ProjectTrustList, to url: URL?, failure: String) throws {
        guard let url else { return }
        do { try OwnerOnlyFile.publish(try JSONEncoder().encode(list), to: url) } catch { throw ProjectSupportFailure(failure) }
    }

    /// Drops state for closed panes and sessions, on each shell event. Kept out of `publish`: pruning there makes Swift 6.3.3 (Xcode 26.6)
    /// emit code that corrupts the task allocator in later async calls ("freed pointer was not the last allocation").
    func pruneProjectState() {
        let panes = snapshot.panes, sessions = snapshot.sessions
        if pendingProjectCommands.keys.contains(where: { sessions[$0] == nil }) { pendingProjectCommands = pendingProjectCommands.filter { sessions[$0.key] != nil } }
        if taskRuns.keys.contains(where: { panes[$0] == nil }) { taskRuns = taskRuns.filter { panes[$0.key] != nil } }
    }

    /// Whether a new local shell pane gets integration, and so reports its first prompt (FR-SI01).
    var shellGetsIntegration: Bool {
        shellIntegrationEnabled && shellIntegrationDirectory != nil && ShellIntegrationKind(executable: defaultShell) != nil
    }

    /// Types a queued command into its shell, once; it is dropped if the shell is no longer running.
    func submitProjectCommand(paneID: UUID) {
        guard let terminal = terminals[paneID], let command = pendingProjectCommands.removeValue(forKey: terminal.sessionID),
            terminal.sessionState == .running
        else { return }
        try? terminal.adapter.send(Data((command + "\r").utf8))
    }

    /// A pane's current local directory, else the folder it was started in.
    func paneDirectory(_ paneID: UUID) -> String? {
        if let directory = currentDirectory(paneID: paneID) { return directory }
        switch snapshot.panes[paneID].flatMap({ snapshot.sessions[$0.sessionID] })?.launch {
        case .shell(let directory)?: return directory
        case .process(_, let arguments, let directory)? where arguments == ["-l"]: return directory
        default: return nil
        }
    }

    /// A shell's directory for comparing with a task's folder under a canonical root: a shell's `$PWD` keeps the logical
    /// path it was reached by, so it is resolved, unless it already names the task's folder.
    func taskCurrentDirectory(paneID: UUID, directory: String) -> String? {
        // A remote pane's directory is a path on its host, compared as given: there is no local file to resolve (FR-RW11).
        if isRemoteWorkspace(paneID: paneID) {
            return remoteWorkingDirectory(paneID: paneID).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        }
        guard let path = currentDirectory(paneID: paneID) else { return nil }
        let logical = URL(fileURLWithPath: path).standardizedFileURL.path
        return logical == URL(fileURLWithPath: directory).standardizedFileURL.path ? logical : Self.canonical(path)
    }

    /// Writes a `.trellis/` repository file, not Trellis state: readable by the project's tools like any other source
    /// file. A linked `.trellis` folder or file is refused, since it could point the write outside the project.
    func writeRepositoryFile(_ data: Data, to url: URL) -> Bool {
        let manager = FileManager.default
        guard ![url.deletingLastPathComponent(), url].contains(where: { (try? manager.destinationOfSymbolicLink(atPath: $0.path)) != nil }) else {
            errorMessage = "\(url.path) or its folder is a symbolic link, so nothing was written."
            return false
        }
        do {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            return true
        } catch {
            errorMessage = "\(url.path) could not be written. Check the folder's permissions and try again."
            return false
        }
    }
}

struct ProjectSupportFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
