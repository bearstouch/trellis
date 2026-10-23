import AppKit
import SwiftUI
import TrellisCore

/// The command scratchpad beside the panes (FR-SP01): name, language, editor, check result, and icon buttons whose
/// tooltips and labels say what they do and, when disabled, why.
struct ScratchpadPanel: View {
    @ObservedObject var model: AppWorkspaceModel
    @State private var saveDraft: SaveDraft?

    struct SaveDraft: Identifiable {
        let id = UUID()
        var name: String
        var group: TaskGroup?
        var runAfterSaving: Bool
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
                    saveAndRun: { if canSave { beginSave(run: true) } },
                    validate: { if canValidate { Task { await model.validateScratchpad() } } },
                    save: { if canSave { beginSave(run: false) } }))
            checkResult
            Divider().overlay(model.separatorOverlay)
            footer
        }
        .background(model.themeColor(.surface))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command scratchpad")
        .sheet(item: $saveDraft) { draft in saveSheet(draft) }
    }

    private var editorFont: NSFont {
        NSFont(name: model.appearance.fontName, size: CGFloat(model.appearance.fontSize)) ?? .monospacedSystemFont(ofSize: CGFloat(model.appearance.fontSize), weight: .regular)
    }

    private var canValidate: Bool { !model.scratchpad.isEmpty && !model.scratchpadChecking }
    private var canSave: Bool { !model.scratchpad.isEmpty }
    private var canRun: Bool { model.scratchpadRunBlocker == nil && !model.scratchpadChecking }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(model.themeColor(.mutedForeground)).accessibilityHidden(true)
            HStack(spacing: 0) {
                TextField("Name", text: Binding(get: { model.scratchpad.name }, set: { model.scratchpad.name = $0 }))
                    .textFieldStyle(.plain).fontWeight(.semibold).accessibilityLabel("Script name")
                Text("." + model.scratchpad.language.fileExtension).font(.system(size: 11, design: .monospaced)).foregroundStyle(model.themeColor(.mutedForeground))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 7).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(model.themeColor(.background)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(model.themeColor(.border)))
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

    /// One entry per registered language, with the program that checks and runs it (FR-SP03).
    private var languageMenu: some View {
        Menu {
            ForEach(ScratchpadLanguage.all) { language in
                Toggle(
                    isOn: Binding(get: { model.scratchpad.language == language }, set: { if $0 { model.setScratchpadLanguage(language) } })
                ) {
                    Text("\(language.displayName) — \(language.interpreter)")
                }
            }
        } label: {
            Text(model.scratchpad.language.displayName).fontWeight(.semibold)
        }
        .menuStyle(.button).fixedSize()
        .help("Language: \(model.scratchpad.language.displayName), checked with \(model.scratchpad.language.checkDescription)")
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
            iconButton("checkmark.circle", "Validate Syntax", shortcut: "⌥⌘V", enabled: canValidate, reason: "Write a command or script first.") {
                Task { await model.validateScratchpad() }
            }
            iconButton("square.and.arrow.down", "Save as Task…", shortcut: "⌥⌘S", enabled: canSave, reason: "Write a command or script first.") {
                beginSave(run: false)
            }
            iconButton("play.square", "Save as Task and Run", shortcut: "⌥⌘↩", enabled: canSave, reason: "Write a command or script first.") {
                beginSave(run: true)
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
        let help = enabled ? "\(title) (\(shortcut))" : "\(title) — \(reason ?? "unavailable")"
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

    // MARK: Save as Task (FR-SP06)

    private func beginSave(run: Bool) {
        saveDraft = SaveDraft(name: model.scratchpad.name, group: nil, runAfterSaving: run)
    }

    private func saveSheet(_ draft: SaveDraft) -> some View {
        let binding = Binding(get: { saveDraft ?? draft }, set: { saveDraft = $0 })
        let document = model.scratchpad
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Save as Task").font(.headline)
                Text("Adds a task to this project's launch.json.").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Task name", text: binding.name)
            Picker("Group", selection: binding.group) {
                Text("None").tag(TaskGroup?.none)
                ForEach(TaskGroup.allCases, id: \.self) { Text($0.rawValue).tag(TaskGroup?.some($0)) }
            }.pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 5) {
                Text("Command").font(.caption).fontWeight(.semibold)
                Text(document.taskCommand).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .padding(7).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                Text(
                    "The script is saved to \(ScratchpadDocument.projectDirectory)/\(document.fileName) and runs from the project folder. If launch.json was trusted, it stays trusted."
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { saveDraft = nil }.keyboardShortcut(.cancelAction)
                Button("Save") { finishSave(run: false) }.keyboardShortcut(draft.runAfterSaving ? nil : .defaultAction)
                Button("Save & Run") { finishSave(run: true) }.keyboardShortcut(draft.runAfterSaving ? .defaultAction : nil)
            }
        }
        .padding(20).frame(width: 440)
    }

    private func finishSave(run: Bool) {
        guard let draft = saveDraft else { return }
        saveDraft = nil
        Task {
            if run { await model.saveScratchpadAndRun(name: draft.name, group: draft.group) } else { await model.saveScratchpadAsTask(name: draft.name, group: draft.group) }
        }
    }

    private func shortcutHelp(_ title: String, _ action: ShortcutAction) -> String {
        model.keyboard.shortcuts[action].map { "\(title) (\($0))" } ?? title
    }
}
