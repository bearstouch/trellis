import SwiftUI
import TrellisCore

/// The sidebar's Tasks view (FR-TK02, FR-TK07): the focused pane's project, its launch.json and detected tasks with
/// their exact lines and Run, Stop or Add buttons, and the pane's task state in words and a symbol, never color alone.
struct TasksSidebarView: View {
    @ObservedObject var model: AppWorkspaceModel
    let paneID: UUID
    /// The pane the list was last read for; a `cd` reads it again without flashing the progress view.
    @State private var loadedPane: UUID?
    private var loaded: Bool { loadedPane == paneID }
    /// A `cd`, or a remote shell's first authenticated mark, changes the folder and reads the project again (FR-TK02).
    private var refreshKey: [String?] { [paneID.uuidString, model.paneDirectory(paneID) ?? model.remoteWorkingDirectory(paneID: paneID)] }

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(model: model, view: .tasks) {
                Button {
                    Task { await model.refreshTaskCatalog(paneID: paneID) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L("Reload launch.json")).accessibilityLabel(L("Reload Tasks"))
            }
            Divider().overlay(model.separatorOverlay)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !loaded {
                        ProgressView(L("Looking for tasks…")).frame(maxWidth: .infinity)
                    } else if let catalog = model.taskCatalog, catalog.paneID == paneID {
                        content(catalog)
                    } else {
                        Text(L("No project folder")).font(.headline)
                        Text(L("The focused pane isn't inside a folder with .trellis or .git, or it isn't a shell."))
                            .font(.callout).foregroundStyle(model.themeColor(.mutedForeground)).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            if loaded, let catalog = model.taskCatalog, catalog.paneID == paneID, catalog.hostID == nil {
                Divider().overlay(model.separatorOverlay)
                HStack {
                    Button(catalog.file == .missing ? L("Create launch.json") : L("Edit launch.json")) { Task { await model.editLaunchFile() } }.help(catalog.path)
                    Spacer()
                }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .background(model.chromeFill(.surface))
        .accessibilityElement(children: .contain).accessibilityLabel(L("Tasks"))
        // The list follows the focused pane, and reads launch.json again each time (FR-TK02).
        .task(id: refreshKey) {
            await model.refreshTaskCatalog(paneID: paneID)
            if !Task.isCancelled { loadedPane = paneID }
        }
    }

    @ViewBuilder private func content(_ catalog: TaskCatalog) -> some View {
        let muted = model.themeColor(.mutedForeground)
        VStack(alignment: .leading, spacing: 2) {
            Text(catalog.name).font(.headline)
            Text(catalog.root).font(.system(size: 11, design: .monospaced)).foregroundStyle(muted).textSelection(.enabled).lineLimit(1).truncationMode(.head)
        }
        runStatus
        if let reason = model.taskAvailability(paneID: catalog.paneID).reason, model.taskRuns[catalog.paneID]?.isActive != true {
            Label(reason, systemImage: "info.circle").font(.caption).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }
        Text("launch.json").font(.subheadline.weight(.semibold)).padding(.top, 4)
        switch catalog.file {
        case .missing:
            Text(L("No launch.json yet. Add a detected task below, or create the file.")).font(.caption).foregroundStyle(muted)
        case .invalid(let reason):
            Label(reason, systemImage: "exclamationmark.triangle").font(.caption).fixedSize(horizontal: false, vertical: true)
        case .loaded(let file):
            if file.tasks.isEmpty { Text(L("No tasks yet.")).font(.caption).foregroundStyle(muted) }
            ForEach(file.tasks, id: \.name) { task in
                TaskRow(model: model, catalog: catalog, task: task, detected: nil, env: file.environment(for: task).map(\.name))
            }
        }
        if !catalog.detected.isEmpty {
            Divider().padding(.vertical, 2)
            Text(L("Detected")).font(.subheadline.weight(.semibold))
            ForEach(catalog.detected) { detected in TaskRow(model: model, catalog: catalog, task: detected.task, detected: detected, env: []) }
        }
    }

    /// The focused pane's task, in words and a symbol (FR-TK07). Only a running task's elapsed time changes, so the
    /// timeline ticks only then.
    @ViewBuilder private var runStatus: some View {
        if let run = model.taskRuns[paneID] {
            TimelineView(.periodic(from: .now, by: run.isRunning ? 1 : 3600)) { context in
                Label(run.statusText(now: context.date), systemImage: symbol(run)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(model.themeColor(.accent).opacity(run.isActive ? 0.18 : 0.08)))
                    .accessibilityElement(children: .ignore).accessibilityLabel(L("Task")).accessibilityValue(run.statusText(now: context.date))
            }
        }
    }

    private func symbol(_ run: TaskRun) -> String {
        switch run.failed {
        case nil: return "stop.circle"
        case true?: return "xmark.octagon"
        case false?: return "checkmark.circle"
        }
    }
}

/// One task: name, group and source, the exact line Run types, then Add (detected only) and Run or Stop.
private struct TaskRow: View {
    @ObservedObject var model: AppWorkspaceModel
    let catalog: TaskCatalog
    let task: LaunchTask
    let detected: DetectedTask?
    /// Variable names only; values are in the line and in launch.json.
    let env: [String]

    var body: some View {
        let muted = model.themeColor(.mutedForeground)
        let id = AppWorkspaceModel.taskID(task, detected: detected != nil)
        let line = model.taskLine(task, fromFile: detected == nil) ?? task.command
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if let group = task.group {
                        Text(group.rawValue).font(.system(size: 9, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(muted.opacity(0.6), lineWidth: 1))
                    }
                }
                Text(line).font(.system(size: 11, design: .monospaced)).lineLimit(3).textSelection(.enabled).help(line)
                    .fixedSize(horizontal: false, vertical: true)
                if let detected { Text(detected.detail).font(.caption2).foregroundStyle(muted) }
                if !env.isEmpty { Text(L("env: %@", env.joined(separator: ", "))).font(.caption2).foregroundStyle(muted).lineLimit(2) }
            }.accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            // A host's launch.json is read-only here (FR-RW11).
            if let detected, catalog.hostID == nil {
                let added = catalog.contains(task)
                Button {
                    Task { await model.addDetectedTask(detected) }
                } label: {
                    Image(systemName: added ? "checkmark.circle" : "plus.circle")
                }
                .buttonStyle(.borderless).disabled(added || isInvalid)
                .help(added ? L("Already in launch.json") : L("Add to launch.json"))
                .accessibilityLabel(added ? L("%@ is in launch.json", task.name) : L("Add %@ to launch.json", task.name))
            }
            runButton(id: id)
        }.padding(.vertical, 3)
    }

    private var isInvalid: Bool {
        if case .invalid = catalog.file { return true }
        return false
    }

    @ViewBuilder private func runButton(id: String) -> some View {
        let paneID = catalog.paneID
        if let run = model.taskRuns[paneID], run.isActive, run.taskID == id {
            // Re-evaluated each half second, so Force Stop appears without a model timer (FR-TK08).
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                if model.canForceStop(paneID: paneID) {
                    Button(L("Force Stop")) { model.forceStopTask(paneID: paneID) }.help(L("Send Ctrl-\\ (SIGQUIT) to the task"))
                        .accessibilityLabel(L("Force stop %@", task.name))
                } else {
                    Button(L("Stop")) { model.stopTask(paneID: paneID) }.help(L("Send Ctrl-C (SIGINT) to the task")).accessibilityLabel(L("Stop %@", task.name))
                }
            }.controlSize(.small)
        } else {
            let availability = model.taskAvailability(paneID: paneID)
            Button(L("Run")) { model.runTask(task, fromFile: detected == nil) }.controlSize(.small)
                .disabled(availability != .ready || model.taskLine(task, fromFile: detected == nil) == nil)
                .help(availability.reason ?? L("Type this line into this pane"))
                .accessibilityLabel(L("Run %@", task.name))
        }
    }
}

/// Every task in a launch.json version, verbatim, before any of them can run (FR-TK06).
struct TaskReviewView: View {
    @ObservedObject var model: AppWorkspaceModel
    let review: TaskReview

    var body: some View {
        let muted = model.themeColor(.mutedForeground)
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Review launch.json")).font(.headline)
            Text(L("Running “%@” trusts this version of the project's launch.json. These are all of its tasks:", review.taskName))
                .fixedSize(horizontal: false, vertical: true)
            Text(review.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(muted)
            if let host = review.hostName {
                Label(L("On %@. Its tasks run on that host.", host), systemImage: "server.rack").font(.callout).accessibilityIdentifier("task.review.host")
            }
            if review.changedSinceTrusted { Label(L("This file changed since you last trusted it."), systemImage: "exclamationmark.triangle").font(.callout) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(review.file.tasks, id: \.name) { task in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(task.name) · \(task.cwd ?? ".")").font(.caption).foregroundStyle(muted)
                            Text(task.command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel(L("Command: %@", task.command))
                            ForEach(review.file.environment(for: task), id: \.name) { variable in
                                Text("\(variable.name)=\(variable.value)").font(.system(size: 11, design: .monospaced)).foregroundStyle(muted).textSelection(.enabled)
                            }
                        }.accessibilityElement(children: .contain)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 260).background(model.themeColor(.background))
            Text(L("Tasks run in your shell with your permissions. Trust only files you have read; any change to the file asks again."))
                .font(.caption).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("Cancel")) { model.resolveTaskReview(review.id, trust: false) }.keyboardShortcut(.cancelAction)
                Button(L("Trust and Run")) { model.resolveTaskReview(review.id, trust: true) }
            }
        }.padding(24).frame(width: 600)
    }
}
