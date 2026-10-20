import SwiftUI
import TrellisCore

/// Shows every command a workspace file would type, verbatim, before any of them can run (FR-WF03).
struct WorkspaceFileReviewView: View {
    @ObservedObject var model: AppWorkspaceModel
    let review: WorkspaceFileReview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Workspace File").font(.headline)
            Text("“\(review.file.name)” opens \(review.file.tabs.count) tab(s) and types the commands below into new shells.")
            Text(review.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(model.themeColor(.mutedForeground))
            if review.changedSinceTrusted {
                Label("This file changed since you last trusted it.", systemImage: "exclamationmark.triangle").font(.callout)
            }
            ScrollView {
                WorkspaceFileOutline(file: review.file, muted: model.themeColor(.mutedForeground)) { entry, _ in
                    Text(entry.pane.command ?? "No command").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .foregroundStyle(entry.pane.command == nil ? model.themeColor(.mutedForeground) : model.themeColor(.foreground))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(entry.pane.command.map { "Command: \($0)" } ?? "No command")
                }.padding(10)
            }.frame(height: 260).background(model.themeColor(.background))
            ForEach(review.warnings, id: \.self) { Text($0).font(.caption) }
            Text("Commands run in your login shell with your permissions. Trust only files you have read; any change to the file asks again.")
                .font(.caption).foregroundStyle(model.themeColor(.mutedForeground)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { decide(.cancel) }.keyboardShortcut(.cancelAction)
                Button("Open Without Commands") { decide(.openWithoutCommands) }
                Button("Trust and Open") { decide(.trustAndOpen) }
            }
        }.padding(24).frame(width: 600)
    }

    private func decide(_ decision: AppWorkspaceModel.WorkspaceReviewDecision) {
        let id = review.id
        Task { await model.resolveWorkspaceReview(id, decision) }
    }
}

/// The window as a workspace file, with an editable command per pane (FR-WF06).
struct WorkspaceFileSaveView: View {
    @ObservedObject var model: AppWorkspaceModel
    @State var draft: WorkspaceFileDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Workspace File").font(.headline)
            Text("Saves this window's tabs, splits, titles, labels and folders. Commands are typed into each new shell when the file is opened.")
                .fixedSize(horizontal: false, vertical: true)
            Text(draft.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(model.themeColor(.mutedForeground))
            ScrollView {
                WorkspaceFileOutline(file: draft.file, muted: model.themeColor(.mutedForeground)) { entry, index in
                    TextField("Command (optional)", text: $draft.commands[index]).font(.system(size: 12, design: .monospaced))
                        .accessibilityLabel("Command for \(entry.pane.title ?? "pane \(index + 1)")")
                }.padding(10)
            }.frame(height: 260).background(model.themeColor(.background))
            ForEach(draft.warnings, id: \.self) { Text($0).font(.caption).fixedSize(horizontal: false, vertical: true) }
            if draft.replacesExisting { Text("This replaces the existing file.").font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelWorkspaceSave() }.keyboardShortcut(.cancelAction)
                Button(draft.replacesExisting ? "Replace" : "Save") { _ = model.writeWorkspaceFile(draft) }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 600)
    }
}

/// Tabs, then each pane's title and folder, with a caller-supplied row for its command.
private struct WorkspaceFileOutline<Detail: View>: View {
    let file: WorkspaceFile
    let muted: Color
    @ViewBuilder let detail: (WorkspaceFile.Entry, Int) -> Detail

    var body: some View {
        let entries = Array(file.entries.enumerated())
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(file.tabs.enumerated()), id: \.offset) { tabIndex, tab in
                VStack(alignment: .leading, spacing: 6) {
                    Text(tab.color.map { "\(tab.title) · \($0.displayName) label" } ?? tab.title).font(.subheadline.weight(.semibold))
                    ForEach(entries.filter { $0.element.tab == tabIndex }, id: \.offset) { index, entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(entry.pane.title ?? "Pane") · \(entry.pane.directory ?? ".")").font(.caption).foregroundStyle(muted)
                            detail(entry, index)
                        }.padding(.leading, 12).accessibilityElement(children: .contain)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
