import Foundation
import TrellisCore

/// Main-actor view state for the saved-host library. The library actor owns
/// validation and persistence; this model only mirrors its committed list.
@MainActor
public final class HostListModel: ObservableObject {
    @Published public private(set) var hosts: [SavedHost] = []
    @Published public var query = ""
    @Published public private(set) var loadFailed = false
    let library: HostLibrary

    public init(library: HostLibrary) { self.library = library }

    /// Opens a connection; set by the app to the workspace model.
    public var onConnect: ((SavedHost, AppWorkspaceModel.HostPlacement) -> Void)?

    /// The latest committed host, read when a session spawns.
    public func host(_ id: UUID) async -> SavedHost? { await library.hosts.first { $0.id == id } }

    public var visibleHosts: [SavedHost] { SavedHost.search(hosts, query: query) }

    public func load() async {
        await library.load()
        await refresh()
    }

    /// Creates when `editing` is nil, otherwise updates from the revision the editor loaded.
    public func save(_ draft: HostDraft, editing: SavedHost?) async -> Result<SavedHost, HostLibraryError> {
        let result: Result<SavedHost, HostLibraryError>
        do {
            if let editing {
                result = .success(try await library.update(id: editing.id, draft, expectedRevision: editing.revision))
            } else {
                result = .success(try await library.create(draft))
            }
        } catch {
            result = .failure(error)
        }
        await refresh()
        return result
    }

    public func delete(_ host: SavedHost) async -> HostLibraryError? {
        var failure: HostLibraryError?
        do { try await library.delete(id: host.id, expectedRevision: host.revision) } catch { failure = error }
        await refresh()
        return failure
    }

    public func resetUnreadable() async -> Bool {
        let reset = (try? await library.resetUnreadable()) != nil
        await refresh()
        return reset
    }

    private func refresh() async {
        hosts = await library.hosts
        loadFailed = await library.loadFailed
    }

    /// Injected for tests; production reads the user's ~/.ssh/config read-only.
    public var sshConfigURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    public var readSSHConfig: @Sendable (URL) throws -> Data? = SSHConfigDiscovery.readConfig

    public func discoverAliases() async -> Result<SSHConfigDiscovery.Result, SSHConfigDiscovery.Failure> {
        let url = sshConfigURL, read = readSSHConfig
        return await Task.detached { SSHConfigDiscovery.discover(url, read: read) }.value
    }

    public func importAliases(_ aliases: [String]) async -> HostLibraryError? {
        var failure: HostLibraryError?
        do { _ = try await library.importAliases(aliases) } catch { failure = error }
        await refresh()
        return failure
    }

    public static func message(for failure: SSHConfigDiscovery.Failure) -> String {
        switch failure {
        case .missing: "No ~/.ssh/config file was found. Add aliases manually with New Host."
        case .unreadable(let reason):
            "~/.ssh/config could not be read (\(reason)). Nothing was changed. Check the file’s permissions and try again, or add aliases manually."
        }
    }

    public static func message(for error: HostLibraryError) -> String {
        switch error {
        case .invalid: "Check the highlighted fields."
        case .notFound: "This host was deleted. Its saved details are no longer available."
        case .conflict: "This host changed since you opened it. Reselect it to see the latest details."
        case .readOnly: "Saved hosts could not be read, so changes are not saved. Reset the host library to continue."
        case .io: "Saved hosts could not be written. Check disk space and permissions, then try again."
        }
    }
}
