import AppKit
import SwiftUI
import TrellisCore

/// The command scratchpad beside the panes (FR-SP01): saved file, language, editor, check result, and icon buttons whose
/// tooltips and labels say what they do and, when disabled, why.
struct ScratchpadPanel: View {
    @ObservedObject var model: AppWorkspaceModel
    /// Typing publishes here, not on `model`; `model.scratchpad` reads it.
    @ObservedObject var buffer: ScratchpadBuffer
    @State private var saveDraft: SaveDraft?
    /// What would replace a buffer with unsaved changes, waiting for confirmation.
    @State private var pendingDiscard: Discard?

    enum Discard: Equatable {
        case clear
        case open(String)
    }

    struct SaveDraft: Identifiable {
        let id = UUID()
        var name: String
        var group: TaskGroup?
        /// Follows the task name until edited.
        var scriptName: String
        var scriptNameEdited = false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(model.separatorOverlay)
            ScratchpadEditor(
                text: Binding(get: { model.scratchpad.text }, set: { model.scratchpad.text = $0 }), language: model.scratchpad.language, font: editorFont,
                palette: model.effectiveTheme.terminal, issueLines: Set(model.scratchpadCheck?.issues.compactMap(\.line) ?? []),
                focusRequest: model.scratchpadFocusRequest,
                commands: ScratchpadEditorCommands(
                    run: { if canRun { Task { await model.runScratchpad() } } },
                    validate: { if canValidate { Task { await model.validateScratchpad() } } },
                    save: { if canSave { beginSave() } }))
            checkResult
            Divider().overlay(model.separatorOverlay)
            footer
        }
        .background(model.themeColor(.surface))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command scratchpad")
        .sheet(item: $saveDraft) { draft in saveSheet(draft) }
        .alert(discardTitle, isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }), presenting: pendingDiscard) {
            discard in
            Button(discard == .clear ? "Clear" : "Open", role: .destructive) { perform(discard) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(
                model.scratchpadSaved == nil
                    ? "This script hasn't been saved as a task. Its text will be lost."
                    : "Changes since you saved \(model.scratchpadSaved?.fileName ?? "the script") will be lost. The saved script and its task stay.")
        }
        // The list follows the pane Run types into.
        .task(id: model.scratchpadPaneID) { await model.refreshScratchpadFiles() }
    }

    private var discardTitle: String {
        switch pendingDiscard {
        case .open(let file)?: "Open \(file)?"
        default: "Clear the scratchpad?"
        }
    }

    /// Replaces the buffer, asking first when that would lose unsaved changes (FR-SP09, FR-SP10).
    private func replaceBuffer(_ discard: Discard) {
        if model.scratchpadHasUnsavedChanges { pendingDiscard = discard } else { perform(discard) }
    }

    private func perform(_ discard: Discard) {
        pendingDiscard = nil
        switch discard {
        case .clear: model.clearScratchpad()
        case .open(let file): Task { await model.openScratchpadFile(file) }
        }
    }

    private var editorFont: NSFont {
        NSFont(name: model.appearance.fontName, size: CGFloat(model.appearance.fontSize)) ?? .monospacedSystemFont(ofSize: CGFloat(model.appearance.fontSize), weight: .regular)
    }

    private var canValidate: Bool { model.scratchpad.language.isRunnable && !model.scratchpad.isEmpty && !model.scratchpadChecking }
    private var validateBlocker: String {
        model.scratchpad.language.isRunnable ? "Write a command or script first." : "\(model.scratchpad.language.displayName) has no syntax check."
    }
    private var canSave: Bool { !model.scratchpad.isEmpty }
    private var canClear: Bool { !model.scratchpad.isEmpty || model.scratchpadSaved != nil }
    private var canRun: Bool { model.scratchpadRunBlocker == nil && !model.scratchpadChecking }

    // MARK: Header

    /// The file selector shows the saved script's name, with **Edited** while the buffer differs from it.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(model.themeColor(.mutedForeground)).accessibilityHidden(true)
            fileMenu
            if model.scratchpadSaved != nil, model.scratchpadHasUnsavedChanges {
                Text("Edited").font(.system(size: 11)).foregroundStyle(model.themeColor(.mutedForeground)).accessibilityLabel("Unsaved changes")
            }
            Spacer(minLength: 4)
            languageMenu
            Button {
                Task { await model.toggleScratchpad() }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain).foregroundStyle(model.themeColor(.mutedForeground))
            .help(shortcutHelp("Close Scratchpad", .toggleScratchpad)).accessibilityLabel("Close Scratchpad")
        }
        .font(.system(size: 12)).padding(.leading, 12).padding(.trailing, 10).frame(height: 40)
    }

    /// The open script's name, or Scratchpad before it is saved; its menu lists the project's saved scratchpads
    /// (FR-SP10).
    private var fileMenu: some View {
        let title = model.scratchpadSaved?.fileName ?? "Scratchpad"
        return Menu {
            Button("New Scratchpad") { replaceBuffer(.clear) }
            Divider()
            if let list = model.scratchpadFiles {
                if list.files.isEmpty {
                    Text("No saved scratchpads in \(list.projectName)")
                } else {
                    Section("Saved in \(list.projectName)") {
                        ForEach(list.files, id: \.self) { file in
                            Toggle(isOn: Binding(get: { model.scratchpadSaved?.fileName == file }, set: { _ in replaceBuffer(.open(file)) })) { Text(file) }
                        }
                    }
                }
            } else {
                Text("Focus a local pane in a project to list its scratchpads")
            }
        } label: {
            Text(title).fontWeight(.semibold)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(model.scratchpadSaved.map { "\(ScratchpadDocument.projectDirectory)/\($0.fileName) — open another scratchpad" } ?? "Open a saved scratchpad")
        .accessibilityLabel("Scratchpad file").accessibilityValue(title)
    }

    /// One entry per registered language, with the program that checks and runs it (FR-SP03).
    private var languageMenu: some View {
        Menu {
            ForEach(ScratchpadLanguage.all) { language in
                Toggle(
                    isOn: Binding(get: { model.scratchpad.language == language }, set: { if $0 { model.setScratchpadLanguage(language) } })
                ) {
                    Text(language.interpreter.map { "\(language.displayName) — \($0)" } ?? language.displayName)
                }
            }
        } label: {
            Text(model.scratchpad.language.displayName).fontWeight(.semibold)
        }
        .menuStyle(.button).fixedSize()
        .help(
            model.scratchpad.language.checkDescription.map { "Language: \(model.scratchpad.language.displayName), checked with \($0)" }
                ?? "Language: \(model.scratchpad.language.displayName), not checked or run"
        )
        .accessibilityLabel("Language").accessibilityValue(model.scratchpad.language.displayName)
    }

    // MARK: Check result (FR-SP04)

    @ViewBuilder private var checkResult: some View {
        if model.scratchpadChecking {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Checking…")
            }
            .modifier(StatusStrip(color: model.themeColor(.mutedForeground)))
        } else if let check = model.scratchpadCheck {
            switch check.outcome {
            case .passed:
                Label {
                    Text("Syntax OK").fontWeight(.semibold) + Text(" · checked with \(check.checker ?? "") · \(lineCount) \(lineCount == 1 ? "line" : "lines")")
                } icon: {
                    Image(systemName: "checkmark")
                }
                .modifier(StatusStrip(color: model.themeColor(.success)))
            case .failed, .notChecked:
                let failed = check.outcome == .failed
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        failed ? "\(check.issues.count) \(check.issues.count == 1 ? "error" : "errors")" : "Not checked",
                        systemImage: failed ? "exclamationmark.triangle" : "questionmark.circle"
                    )
                    .fontWeight(.semibold)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(check.issues.enumerated()), id: \.offset) { _, issue in
                                Text(issue.line.map { "Line \($0): " + issue.message } ?? issue.message).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 96).fixedSize(horizontal: false, vertical: true)
                }
                .modifier(StatusStrip(color: model.themeColor(failed ? .error : .warning)))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var lineCount: Int { model.scratchpad.text.split(separator: "\n", omittingEmptySubsequences: false).count }

    private struct StatusStrip: ViewModifier {
        let color: Color
        func body(content: Content) -> some View {
            content.font(.system(size: 11.5)).foregroundStyle(color).padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading).background(color.opacity(0.1))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal").accessibilityHidden(true)
            Text(targetText).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            iconButton("trash", "Clear Scratchpad", shortcut: "", enabled: canClear, reason: "The scratchpad is already empty.") {
                replaceBuffer(.clear)
            }
            iconButton("checkmark.circle", "Validate Syntax", shortcut: "⌥⌘V", enabled: canValidate, reason: validateBlocker) {
                Task { await model.validateScratchpad() }
            }
            iconButton("square.and.arrow.down", model.scratchpad.language.isRunnable ? "Save as Task…" : "Save File…", shortcut: "⌥⌘S", enabled: canSave, reason: "Write a command or script first.") {
                beginSave()
            }
            iconButton("play.fill", "Run in \(targetName)", shortcut: "⌘↩", enabled: canRun, reason: model.scratchpadRunBlocker, prominent: true) {
                Task { await model.runScratchpad() }
            }
        }
        .font(.system(size: 11)).foregroundStyle(model.themeColor(.mutedForeground))
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var targetName: String { model.scratchpadPaneID.map(model.paneTitle) ?? "the focused pane" }

    /// Where Run types and whether it can: words, not color (FR-SP08).
    private var targetText: String {
        guard let paneID = model.scratchpadPaneID else { return "No pane selected" }
        let state: String
        switch model.taskAvailability(paneID: paneID) {
        case .ready: state = "at prompt"
        case .busy: state = "busy"
        case .taskActive: state = "task running"
        case .notRunning: state = "not running"
        case .remote: state = "remote shell"
        case .noIntegration: state = "no shell integration"
        }
        return "Runs in \(targetName) · \(state)"
    }

    private func iconButton(
        _ symbol: String, _ title: String, shortcut: String, enabled: Bool, reason: String?, prominent: Bool = false, action: @escaping () -> Void
    ) -> some View {
        let help = enabled ? (shortcut.isEmpty ? title : "\(title) (\(shortcut))") : "\(title) — \(reason ?? "unavailable")"
        return Button(action: action) {
            Image(systemName: symbol).font(.system(size: prominent ? 11 : 13)).frame(width: prominent ? 30 : 24, height: 22)
                .foregroundStyle(prominent && enabled ? model.accentForeground : enabled ? model.themeColor(.foreground) : model.themeColor(.mutedForeground))
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(prominent && enabled ? model.themeColor(.accent) : model.themeColor(.background).opacity(enabled ? 1 : 0.5))
                )
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(prominent && enabled ? Color.clear : model.themeColor(.border)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .help(help).accessibilityLabel(title).accessibilityHint(enabled ? shortcut : reason ?? "")
    }

    // MARK: Save as Task, or as a file for text that isn't run (FR-SP06)

    private func beginSave() {
        let saved = model.scratchpadSaved, task = model.scratchpadSavedTask
        saveDraft = SaveDraft(name: task?.name ?? saved?.name ?? "", group: task?.group, scriptName: saved?.name ?? "", scriptNameEdited: saved != nil)
    }

    private func saveSheet(_ draft: SaveDraft) -> some View {
        let current = saveDraft ?? draft
        let taskName = Binding(
            get: { current.name },
            set: { name in
                saveDraft?.name = name
                if saveDraft?.scriptNameEdited == false { saveDraft?.scriptName = ScratchpadDocument.suggestedName(for: name) }
            })
        let scriptName = Binding(
            get: { current.scriptName },
            set: {
                saveDraft?.scriptName = $0; saveDraft?.scriptNameEdited = true
            })
        var document = model.scratchpad
        document.name = current.scriptName
        // Text that isn't run, like Markdown, is saved as a file only.
        let asTask = document.language.isRunnable
        let problem = (asTask ? LaunchFile.taskNameProblem(current.name) : nil) ?? ScratchpadDocument.nameProblem(current.scriptName)
        let note =
            asTask
            ? "The script is saved to \(ScratchpadDocument.projectDirectory)/\(document.fileName) and runs from the project folder. If launch.json was trusted, it stays trusted."
            : "The file is saved to \(ScratchpadDocument.projectDirectory)/\(document.fileName). \(document.language.displayName) isn't run, so no task is added."
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(asTask ? "Save as Task" : "Save File").font(.headline)
                Text(asTask ? "Adds a task to this project's launch.json." : "Saves the file in this project.").font(.caption).foregroundStyle(.secondary)
            }
            Form {
                if asTask { TextField("Task name", text: taskName) }
                HStack(spacing: 4) {
                    TextField("File name", text: scriptName)
                    Text("." + document.language.fileExtension).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
                if asTask {
                    Picker("Group", selection: Binding(get: { current.group }, set: { saveDraft?.group = $0 })) {
                        Text("None").tag(TaskGroup?.none)
                        ForEach(TaskGroup.allCases, id: \.self) { Text($0.rawValue).tag(TaskGroup?.some($0)) }
                    }.pickerStyle(.segmented)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                if let command = document.taskCommand {
                    Text("Command").font(.caption).fontWeight(.semibold)
                    Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .padding(7).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                }
                Text((asTask ? current.name.isEmpty : current.scriptName.isEmpty) || problem == nil ? note : problem ?? "")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { saveDraft = nil }.keyboardShortcut(.cancelAction)
                Button("Save") { finishSave(run: false) }.keyboardShortcut(.defaultAction).disabled(problem != nil)
                if asTask { Button("Save & Run") { finishSave(run: true) }.disabled(problem != nil) }
            }
        }
        .padding(20).frame(width: 440)
    }

    private func finishSave(run: Bool) {
        guard let draft = saveDraft else { return }
        saveDraft = nil
        let asTask = model.scratchpad.language.isRunnable
        Task {
            if !asTask {
                await model.saveScratchpadFile(scriptName: draft.scriptName)
            } else if run {
                await model.saveScratchpadAndRun(name: draft.name, scriptName: draft.scriptName, group: draft.group)
            } else {
                await model.saveScratchpadAsTask(name: draft.name, scriptName: draft.scriptName, group: draft.group)
            }
        }
    }

    private func shortcutHelp(_ title: String, _ action: ShortcutAction) -> String {
        model.keyboard.shortcuts[action].map { "\(title) (\($0))" } ?? title
    }
}
