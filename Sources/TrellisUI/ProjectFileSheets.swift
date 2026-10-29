import SwiftUI
import TrellisCore

/// Shows every command a project file would type, verbatim, before any of them can run (FR-WF03).
struct ProjectFileReviewView: View {
    @ObservedObject var model: AppWorkspaceModel
    let review: ProjectFileReview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Project File").font(.headline)
            Text("“\(review.file.name)” opens \(review.file.tabs.count) tab(s) and types the commands below into new shells.")
            Text(review.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(model.themeColor(.mutedForeground))
            // FR-RW10: a remote project names its host, and its commands run there.
            if let host = review.hostName {
                Label("On \(host). Its commands run on that host.", systemImage: "server.rack").font(.callout).accessibilityIdentifier("project.review.host")
            }
            if review.changedSinceTrusted {
                Label("This file changed since you last trusted it.", systemImage: "exclamationmark.triangle").font(.callout)
            }
            ScrollView {
                ProjectFileOutline(file: review.file, muted: model.themeColor(.mutedForeground)) { entry, _ in
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

    private func decide(_ decision: AppWorkspaceModel.ProjectReviewDecision) {
        let id = review.id
        Task { await model.resolveProjectReview(id, decision) }
    }
}

/// The window's project file as editable JSON, with Validate and Save; replacing a file asks first (FR-WF06).
struct ProjectFileSaveView: View {
    @ObservedObject var model: AppWorkspaceModel
    @State var draft: ProjectFileDraft
    @State private var check: ProjectFileCheck?
    /// Set when Save needs a confirmation: replacing a file that exists now, or saving with warnings.
    @State private var confirmation: (replacing: Bool, warnings: [String])?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Project").font(.headline)
            Text("This window's tabs, splits, titles, labels and folders as a project file. Edit it before saving; commands are typed into each new shell when the file is opened.")
                .fixedSize(horizontal: false, vertical: true)
            Text(draft.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(model.themeColor(.mutedForeground))
            ProjectJSONEditor(model: model, text: $draft.text, check: check, validate: validate, save: save)
            ForEach(draft.warnings, id: \.self) { Text($0).font(.caption).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelProjectSave() }.keyboardShortcut(.cancelAction)
                Button("Validate", action: validate).help("Check the file without saving it (⌥⌘V)")
                Button("Save", action: save).help("Save the file (⌥⌘S)")
            }
        }
        .padding(24).frame(width: 640)
        .onChange(of: draft.text) {
            check = nil; model.errorMessage = nil
        }
        .alert(
            confirmation?.replacing == true ? "Replace project.json?" : "Save project.json?",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
        ) {
            Button("Cancel", role: .cancel) {}
            Button(confirmation?.replacing == true ? "Replace" : "Save", role: confirmation?.replacing == true ? .destructive : nil) { _ = model.writeProjectFile(draft) }
        } message: {
            Text(((confirmation?.replacing == true ? ["\(draft.path) already exists. Saving replaces it with this file."] : []) + (confirmation?.warnings ?? [])).joined(separator: "\n\n"))
        }
    }

    private func validate() { model.errorMessage = nil; check = model.checkProjectFile(draft) }

    /// Saves only text that checks out, and asks before replacing a file that exists now or saving with a warning,
    /// which would otherwise close the sheet before it is seen.
    private func save() {
        validate()
        guard let check, check.isValid else { return }
        let replacing = model.projectFileExists(draft)
        if replacing || !check.warnings.isEmpty { confirmation = (replacing, check.warnings) } else { _ = model.writeProjectFile(draft) }
    }
}

/// A project file opened from a pane's header for editing as JSON (FR-WF08).
struct ProjectFileEditView: View {
    @ObservedObject var model: AppWorkspaceModel
    @State var edit: ProjectFileEdit
    @State private var check: ProjectFileCheck?
    @State private var confirmingReplace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Project File").font(.headline)
            Text("Changes apply the next time the project is opened. Commands you add run only after the file is trusted.")
                .fixedSize(horizontal: false, vertical: true)
            Text(edit.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(model.themeColor(.mutedForeground))
            ProjectJSONEditor(model: model, text: $edit.text, check: check, validate: validate, save: save)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelProjectEdit() }.keyboardShortcut(.cancelAction)
                Button("Validate", action: validate).help("Check the file without saving it (⌥⌘V)")
                Button("Save", action: save).help("Save the file (⌥⌘S)")
            }
        }
        .padding(24).frame(width: 640)
        .onChange(of: edit.text) {
            check = nil; model.errorMessage = nil
        }
        .alert("Replace the changed file?", isPresented: $confirmingReplace) {
            Button("Cancel", role: .cancel) {}
            Button("Replace", role: .destructive) { _ = model.writeProjectFileEdit(edit) }
        } message: {
            Text("\(edit.path) changed on disk after you opened it. Saving replaces that change with this text.")
        }
    }

    private func validate() { model.errorMessage = nil; check = model.checkProjectFileEdit(edit) }

    /// Saves only text that checks out, and asks before replacing a change made elsewhere since the editor opened.
    private func save() {
        validate()
        guard check?.isValid == true else { return }
        if model.projectFileEditChangedOnDisk(edit) { confirmingReplace = true } else { _ = model.writeProjectFileEdit(edit) }
    }
}

/// The JSON editor both project file sheets use, in the terminal's font and colors, with the last check's result.
private struct ProjectJSONEditor: View {
    @ObservedObject var model: AppWorkspaceModel
    @Binding var text: String
    let check: ProjectFileCheck?
    let validate: () -> Void
    let save: () -> Void

    var body: some View {
        ScratchpadEditor(
            text: $text, language: .json, font: font, palette: model.effectiveTheme.terminal, issueLines: [], focusRequest: 0,
            commands: ScratchpadEditorCommands(validate: validate, save: save), accessibilityName: "Project file editor", contentNoun: "project file",
            maximumBytes: ProjectFile.maximumBytes
        ).frame(height: 320)
        // A failed write (the window changed, a linked or unwritable folder) is shown here, not behind the sheet.
        if let error = model.errorMessage {
            Label(error, systemImage: "xmark.octagon").font(.callout).fixedSize(horizontal: false, vertical: true).accessibilityLabel("Error: \(error)")
        }
        if let check {
            VStack(alignment: .leading, spacing: 4) {
                if check.isValid { Label("The project file is valid.", systemImage: "checkmark.circle").font(.callout) }
                ForEach(check.errors, id: \.self) { Label($0, systemImage: "xmark.octagon").font(.callout).fixedSize(horizontal: false, vertical: true) }
                ForEach(check.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).fixedSize(horizontal: false, vertical: true) }
            }.accessibilityElement(children: .combine)
        }
    }

    private var font: NSFont {
        NSFont(name: model.appearance.fontName, size: CGFloat(model.appearance.fontSize)) ?? .monospacedSystemFont(ofSize: CGFloat(model.appearance.fontSize), weight: .regular)
    }
}

/// Tabs, then each pane's title and folder, with a caller-supplied row for its command.
private struct ProjectFileOutline<Detail: View>: View {
    let file: ProjectFile
    let muted: Color
    @ViewBuilder let detail: (ProjectFile.Entry, Int) -> Detail

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
