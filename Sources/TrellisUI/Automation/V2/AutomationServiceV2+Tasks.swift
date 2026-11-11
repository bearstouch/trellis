import Foundation
import TrellisControl
import TrellisCore

/// `task.*` (methods.md#tasks): a pane's project tasks read as the Tasks view reads them (FR-TK02, FR-TK03), typed as Run
/// types them (FR-TK04, FR-TK05) and followed in the same `taskRuns` the view and the `task.run` events use (FR-TK07).
/// Trust in a launch.json is only ever given in the app (FR-TK06): an untrusted task is TASK_UNTRUSTED, never a review.
extension AutomationServiceV2 {
    @MainActor func performTasks(_ call: CallV2) async throws -> JSONValue {
        let p = call.params
        let paneID = try p.uuid("paneId")
        guard let pane = model.snapshot.panes[paneID] else { throw Self.notFound }
        switch call.spec.name {
        case "task.get":
            var object: [String: JSONValue] = [:]
            if let run = model.taskRuns[paneID] { object["run"] = projection(call, spaces: spaceOf(pane: paneID)).taskRun(run, paneID: paneID) }
            return .object(object)
        case "task.list":
            let catalog = try await catalog(pane, call)
            let projection = projection(call, spaces: [])
            let page = try PageV2(p, method: call.spec.name).slice(catalog.map(entries) ?? [])
            var object: [String: JSONValue] = ["tasks": .array(page.items.map(projection.task))]
            if let catalog {
                object["file"] = .string(Self.fileState(catalog.file))
                if call.grant.holds(.sessionExecute) { object["folder"] = .string(catalog.root) }
            }
            if let next = page.nextCursor { object["nextCursor"] = .string(next) }
            return .object(object)
        case "task.run": return try await runTask(call, pane)
        case "task.stop":
            try requireRemoteHostAccess(pane.sessionID, call)
            guard let run = model.taskRuns[paneID], run.isActive, let terminal = model.terminals[paneID], terminal.isRunning else {
                throw Self.invalidState("No task is running in this pane.", state: model.taskRuns[paneID].map(ProjectionV2.phase) ?? "noTask")
            }
            try requireLinkUp(pane.sessionID)
            if try p.optionalBool("force") == true {
                // As the app's Force Stop: only once the first Stop is `taskStopEscalation` old.
                guard model.canForceStop(paneID: paneID) else {
                    if run.stopRequestedAt == nil { model.stopTask(paneID: paneID) }
                    throw ControlError.api(.closePending, "The task was asked to stop. Retry with force: true after two seconds if it is still running.")
                }
                model.forceStopTask(paneID: paneID)
            } else {
                model.stopTask(paneID: paneID)
            }
            return try taskRunResult(call, paneID)
        default: throw ControlError.methodNotFound
        }
    }

    /// The pane's project, read without touching the Tasks view's catalog. A remote workspace pane's is read on its host,
    /// which needs the host in scope (FR-RW15) and its link.
    @MainActor private func catalog(_ pane: WorkspacePane, _ call: CallV2) async throws -> TaskCatalog? {
        try requireRemoteHostAccess(pane.sessionID, call)
        try requireLinkUp(pane.sessionID)
        return await model.loadTaskCatalog(paneID: pane.id)
    }

    /// launch.json's tasks (trusted when the user trusted this exact file in the app), then the detected ones.
    @MainActor private func entries(_ catalog: TaskCatalog) -> [TaskEntryV2] {
        var entries: [TaskEntryV2] = []
        if case .loaded(let file) = catalog.file {
            let trusted = catalog.digest.map { digest in (try? model.launchTrustList())?.isTrusted(root: catalog.trustKey, digest: digest) == true } ?? false
            entries += file.tasks.map { task in
                TaskEntryV2(
                    id: AppWorkspaceModel.taskID(task, detected: false), task: task, source: .file, trusted: trusted, environment: file.environment(for: task).map(\.name))
            }
        }
        entries += catalog.detected.map { TaskEntryV2(id: $0.id, task: $0.task, source: $0.source, trusted: true) }
        return entries
    }

    static func fileState(_ file: TaskCatalog.FileState) -> String {
        switch file {
        case .missing: "missing"
        case .loaded: "loaded"
        case .invalid: "invalid"
        }
    }

    /// Types the task as Run does. A launch.json task runs only from a file version the user trusted in the app; the
    /// line typed is built from the copy just read and checked, never a later read.
    @MainActor private func runTask(_ call: CallV2, _ pane: WorkspacePane) async throws -> JSONValue {
        let taskID = try call.params.string("taskId")
        guard let catalog = try await catalog(pane, call) else { throw Self.invalidState("The pane's folder isn't in a project with tasks.", state: "noProject") }
        let fromFile = taskID.hasPrefix("file:")
        let task: LaunchTask
        var file: LaunchFile?
        if fromFile {
            guard case .loaded(let loaded) = catalog.file, let found = loaded.task(named: String(taskID.dropFirst(5))) else { throw Self.taskNotFound }
            let trust: ProjectTrustList
            do { trust = try model.launchTrustList() } catch {
                throw Self.invalidState("Trusted launch.json files could not be read, so launch.json tasks can't run.", state: "trustUnreadable")
            }
            guard let digest = catalog.digest, trust.isTrusted(root: catalog.trustKey, digest: digest) else {
                throw ControlError.api(
                    .taskUntrusted, "This launch.json version hasn't been trusted. Review and trust it in the app's Tasks view (Run asks), then retry.",
                    details: .object([
                        "taskId": .string(taskID), "changedSinceTrusted": .bool(catalog.digest.map { trust.trustedOtherVersion(root: catalog.trustKey, digest: $0) } ?? false)
                    ]))
            }
            task = found; file = loaded
        } else {
            guard let detected = catalog.detected.first(where: { $0.id == taskID }) else { throw Self.taskNotFound }
            task = detected.task
        }
        do { try model.startTask(task, file: file, root: catalog.root, paneID: pane.id, taskID: taskID) } catch {
            switch error {
            case .unavailable(let availability):
                let state: String =
                    switch availability {
                    case .ready, .noIntegration: "noIntegration"
                    case .notRunning: "notRunning"
                    case .remote: "notShell"
                    case .busy: "busy"
                    case .taskActive: "taskActive"
                    }
                let message = Localization.$sourceTextOnly.withValue(true) { availability.reason ?? TaskRunAvailability.noIntegration.reason ?? "" }
                throw Self.invalidState(message, state: state, retryable: availability == .busy || availability == .taskActive)
            case .unquotable: throw Self.invalidState("The task can't be typed safely: its folder or shell has characters that can't be quoted, or the line is too long.", state: "unquotable")
            case .notSent: throw Self.invalidState("The task could not be typed. The session may have stopped.", state: "notRunning")
            }
        }
        return try taskRunResult(call, pane.id)
    }

    private static let taskNotFound = ControlError.api(.notFound, "No such task in this pane's project. List them with task.list.")

    @MainActor private func taskRunResult(_ call: CallV2, _ paneID: UUID) throws -> JSONValue {
        guard let run = model.taskRuns[paneID] else { throw Self.invalidState("The task run ended.", state: "noTask") }
        return .object(["run": projection(call, spaces: spaceOf(pane: paneID)).taskRun(run, paneID: paneID)])
    }
}
