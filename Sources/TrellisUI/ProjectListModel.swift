import Foundation
import TrellisControl
import TrellisCore

/// Main-actor view state for the project library (FR-PL01–FR-PL05). The library actor owns validation and persistence;
/// this model mirrors its committed list.
@MainActor
public final class ProjectListModel: ObservableObject {
    @Published public private(set) var projects: [ProjectDefinition] = []
    @Published public var query = ""
    @Published public private(set) var loadFailed = false
    /// An unsaved project for the editor (captured from a window or imported); the window selects it.
    @Published public var pendingDraft: ProjectCapture?
    /// The editor holds changes that aren't saved; closing the window asks first.
    public var editorDirty = false
    /// Raised by the window's close prompt: the editor saves (then runs `afterRequestedSave`) or reloads its project.
    @Published public private(set) var saveRequests = 0
    @Published public private(set) var discardRequests = 0
    private var afterRequestedSave: (() -> Void)?
    public let library: ProjectLibrary

    /// Opens the launch sheet for a saved project (FR-PL06); set by the app.
    public var onLaunch: ((ProjectDefinition) -> Void)?
    /// Names a saved host for list summaries; set by the app.
    public var hostName: (UUID) -> String? = { _ in nil }

    public init(library: ProjectLibrary) { self.library = library }

    public var visibleProjects: [ProjectDefinition] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return projects }
        return projects.filter { project in
            let fields = [project.name, project.notes ?? ""] + project.checkouts.map(\.repository.url)
            return terms.allSatisfy { term in fields.contains { $0.lowercased().contains(term) } }
        }
    }

    /// Asks the editor to save its project; `then` runs only after the save succeeds.
    public func requestSave(then: @escaping () -> Void) { afterRequestedSave = then; saveRequests += 1 }
    public func takeAfterRequestedSave() -> (() -> Void)? { defer { afterRequestedSave = nil }; return afterRequestedSave }
    /// Drops the editor's unsaved changes, so reopening the window shows the stored project.
    public func discardEditor() { editorDirty = false; discardRequests += 1 }

    public func load() async {
        await library.load()
        await refresh()
    }

    /// Creates when `project` isn't stored yet (new, captured or imported), otherwise updates from its revision.
    public func save(_ project: ProjectDefinition) async -> Result<ProjectDefinition, ProjectLibraryError> {
        let result: Result<ProjectDefinition, ProjectLibraryError>
        do {
            if projects.contains(where: { $0.id == project.id }) {
                result = .success(try await library.update(project))
            } else {
                result = .success(try await library.create(project))
            }
        } catch { result = .failure(error) }
        await refresh()
        return result
    }

    public func delete(_ project: ProjectDefinition) async -> ProjectLibraryError? {
        var failure: ProjectLibraryError?
        do { try await library.delete(project.id, expectedRevision: project.revision) } catch { failure = error }
        await refresh()
        return failure
    }

    public func recordLaunch(_ id: UUID, target: ProjectTarget, folder: String) async {
        try? await library.recordLaunch(id, target: target, folder: folder)
        await refresh()
    }

    public func resetUnreadable() async -> Bool {
        let reset = (try? await library.resetUnreadable()) != nil
        await refresh()
        return reset
    }

    /// A project read from JSON text, or its problems (FR-PL04).
    public func importJSON(_ data: Data) -> Result<ProjectDefinition, ProjectJSONError> { ProjectJSON.parse(data) }

    /// "3 tabs · 2 repositories".
    public func summary(_ project: ProjectDefinition) -> String {
        let tabs = project.tabs.count, repositories = project.checkouts.count
        return "\(tabs) tab\(tabs == 1 ? "" : "s")" + (repositories == 0 ? "" : " · \(repositories) repositor\(repositories == 1 ? "y" : "ies")")
    }

    /// "Last: build-box, This Mac", or nil before the first launch.
    public func lastLaunched(_ project: ProjectDefinition) -> String? {
        let names = project.lastFolders.keys.sorted().compactMap { key -> String? in
            switch ProjectTarget(key: key) {
            case .local?: "This Mac"
            case .host(let id)?: hostName(id)
            case nil: nil
            }
        }
        return names.isEmpty ? nil : "Last: " + names.joined(separator: ", ")
    }

    private func refresh() async {
        projects = await library.projects
        loadFailed = await library.loadFailed
    }

    public static func message(for error: ProjectLibraryError) -> String {
        switch error {
        case .invalid: "Check the highlighted fields."
        case .notFound: "This project was deleted."
        case .conflict: "This project changed since you opened it. Reselect it to see the latest version."
        case .readOnly: "Saved projects could not be read, so changes are not saved. Reset the project library to continue."
        case .io: "Saved projects could not be written. Check disk space and permissions, then try again."
        }
    }
}
