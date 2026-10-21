import SwiftUI
import TrellisCore

/// A pane header's Tasks button (FR-TK02, FR-TK07): the pane's task state in words and a symbol, never color alone,
/// opening the Tasks menu for that pane.
struct TaskDropdownButton: View {
    @ObservedObject var model: AppWorkspaceModel
    let paneID: UUID
    @State private var isPresented = false

    var body: some View {
        let run = model.taskRuns[paneID]
        Button {
            isPresented.toggle()
        } label: {
            // Only a running task's elapsed time changes; otherwise the header needn't redraw every second.
            TimelineView(.periodic(from: .now, by: run?.isRunning == true ? 1 : 3600)) { context in
                HStack(spacing: 4) {
                    Image(systemName: symbol(run))
                    Text(run?.statusText(now: context.date) ?? "Tasks").lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).accessibilityHidden(true)
                }
                .monospacedDigit()
                .accessibilityElement(children: .ignore).accessibilityLabel("Tasks")
                .accessibilityValue(run?.statusText(now: context.date) ?? "")
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(model.themeColor(.accent).opacity(run?.isActive == true ? 0.18 : 0)))
            // Hugs its label, up to 220 points, so it sits right before Local.
            .frame(maxWidth: 220).fixedSize()
        }
        .help("Run a task in this pane")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { TaskPopover(model: model, paneID: paneID) }
    }

    private func symbol(_ run: TaskRun?) -> String {
        guard let run else { return "play.circle" }
        switch run.failed {
        case nil: return "stop.circle"
        case true?: return "xmark.octagon"
        case false?: return "checkmark.circle"
        }
    }
}

/// The project's launch.json tasks and detected tasks, each with its exact line and a Run, Stop or Add button.
private struct TaskPopover: View {
    @ObservedObject var model: AppWorkspaceModel
    let paneID: UUID
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !loaded {
                ProgressView("Looking for tasks…").frame(maxWidth: .infinity)
            } else if let catalog = model.taskCatalog, catalog.paneID == paneID {
                content(catalog)
            } else {
                Text("No project folder").font(.headline)
                Text("This pane isn't inside a folder with .trellis or .git, or it isn't a local shell.")
                    .font(.callout).foregroundStyle(model.themeColor(.mutedForeground)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14).frame(width: 440)
        .task {
            await model.refreshTaskCatalog(paneID: paneID)
            loaded = true
        }
    }

    @ViewBuilder private func content(_ catalog: TaskCatalog) -> some View {
        let muted = model.themeColor(.mutedForeground)
        VStack(alignment: .leading, spacing: 2) {
            Text(catalog.name).font(.headline)
            Text(catalog.root).font(.system(size: 11, design: .monospaced)).foregroundStyle(muted).textSelection(.enabled).lineLimit(1).truncationMode(.head)
        }
        if let reason = model.taskAvailability(paneID: catalog.paneID).reason, model.taskRuns[catalog.paneID]?.isActive != true {
            Label(reason, systemImage: "info.circle").font(.caption).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("launch.json").font(.subheadline.weight(.semibold))
                switch catalog.file {
                case .missing:
                    Text("No launch.json yet. Add a detected task below, or create the file.").font(.caption).foregroundStyle(muted)
                case .invalid(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle").font(.caption).fixedSize(horizontal: false, vertical: true)
                case .loaded(let file):
                    if file.tasks.isEmpty { Text("No tasks yet.").font(.caption).foregroundStyle(muted) }
                    ForEach(file.tasks, id: \.name) { task in
                        TaskRow(model: model, catalog: catalog, task: task, detected: nil, env: file.environment(for: task).map(\.name))
                    }
                }
                if !catalog.detected.isEmpty {
                    Divider().padding(.vertical, 2)
                    Text("Detected").font(.subheadline.weight(.semibold))
                    ForEach(catalog.detected) { detected in TaskRow(model: model, catalog: catalog, task: detected.task, detected: detected, env: []) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 420).fixedSize(horizontal: false, vertical: true)
        Divider()
        HStack {
            Button(catalog.file == .missing ? "Create launch.json" : "Edit launch.json") { Task { await model.editLaunchFile() } }
                .help(catalog.path)
            Spacer()
            Button("Reload") { Task { await model.refreshTaskCatalog(paneID: paneID) } }
        }.controlSize(.small)
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
                if !env.isEmpty { Text("env: " + env.joined(separator: ", ")).font(.caption2).foregroundStyle(muted).lineLimit(2) }
            }.accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            if let detected {
                let added = catalog.contains(task)
                Button {
                    Task { await model.addDetectedTask(detected) }
                } label: {
                    Image(systemName: added ? "checkmark.circle" : "plus.circle")
                }
                .buttonStyle(.borderless).disabled(added || isInvalid)
                .help(added ? "Already in launch.json" : "Add to launch.json")
                .accessibilityLabel(added ? "\(task.name) is in launch.json" : "Add \(task.name) to launch.json")
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
                    Button("Force Stop") { model.forceStopTask(paneID: paneID) }.help("Send Ctrl-\\ (SIGQUIT) to the task")
                        .accessibilityLabel("Force stop \(task.name)")
                } else {
                    Button("Stop") { model.stopTask(paneID: paneID) }.help("Send Ctrl-C (SIGINT) to the task").accessibilityLabel("Stop \(task.name)")
                }
            }.controlSize(.small)
        } else {
            let availability = model.taskAvailability(paneID: paneID)
            Button("Run") { model.runTask(task, fromFile: detected == nil) }.controlSize(.small)
                .disabled(availability != .ready || model.taskLine(task, fromFile: detected == nil) == nil)
                .help(availability.reason ?? "Type this line into this pane")
                .accessibilityLabel("Run \(task.name)")
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
            Text("Review launch.json").font(.headline)
            Text("Running “\(review.taskName)” trusts this version of the project's launch.json. These are all of its tasks:")
                .fixedSize(horizontal: false, vertical: true)
            Text(review.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(muted)
            if review.changedSinceTrusted { Label("This file changed since you last trusted it.", systemImage: "exclamationmark.triangle").font(.callout) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(review.file.tasks, id: \.name) { task in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(task.name) · \(task.cwd ?? ".")").font(.caption).foregroundStyle(muted)
                            Text(task.command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("Command: \(task.command)")
                            ForEach(review.file.environment(for: task), id: \.name) { variable in
                                Text("\(variable.name)=\(variable.value)").font(.system(size: 11, design: .monospaced)).foregroundStyle(muted).textSelection(.enabled)
                            }
                        }.accessibilityElement(children: .contain)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 260).background(model.themeColor(.background))
            Text("Tasks run in your shell with your permissions. Trust only files you have read; any change to the file asks again.")
                .font(.caption).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.resolveTaskReview(review.id, trust: false) }.keyboardShortcut(.cancelAction)
                Button("Trust and Run") { model.resolveTaskReview(review.id, trust: true) }
            }
        }.padding(24).frame(width: 600)
    }
}
