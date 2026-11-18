import AppKit
import SwiftUI
import TrellisCore
import TrellisTerminal

/// Settings → Keyboard. Edits a draft; conflicts are listed by action name and
/// block saving, so the active shortcuts never change to a conflicting map.
struct KeyboardSettingsView: View {
    @ObservedObject var model: AppWorkspaceModel
    @State private var draft = KeyboardSettings()
    @State private var recording: ShortcutAction?
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        let issues = draft.shortcuts.issues()
        VStack(spacing: 0) {
            Form {
                Section(L("Terminal keys")) {
                    Toggle(isOn: $draft.optionAsMeta) {
                        SettingsLabel(
                            L("Use Option as Meta key"),
                            help: L("When off, Option types accented and layout characters (such as Portuguese symbols and dead keys). When on, Option sends Esc-prefixed Meta keys."))
                    }
                }
                if !issues.isEmpty {
                    // One stack, so the combined label is spoken once: on a Section it would land on every row.
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                                Label(issue.description, systemImage: "exclamationmark.triangle").foregroundStyle(model.themeColor(.warning))
                            }
                        }
                        .accessibilityElement(children: .combine).accessibilityLabel(L("Shortcut problems: %@", issues.map(\.description).joined(separator: " ")))
                    }
                }
                ForEach(ShortcutMenu.allCases, id: \.self) { menu in
                    Section(menu.title) {
                        ForEach(ShortcutAction.allCases.filter { $0.menu == menu }, id: \.self) { row($0, issues: issues) }
                    }
                }
                if let notice = model.keyboardNotice { Section { SettingsNote(text: notice) } }
            }
            .settingsFormStyle()
            .accessibilityLabel(L("Keyboard shortcuts"))
            SettingsFooter(message: message) {
                Button(L("Restore Defaults")) {
                    let meta = draft.optionAsMeta
                    draft = KeyboardSettings()
                    draft.optionAsMeta = meta
                }
                Button(L("Revert")) { draft = model.keyboard }.disabled(draft == model.keyboard)
                Button(L("Save Shortcuts")) {
                    let problems = model.saveKeyboardSettings(draft)
                    message = problems.isEmpty ? L("Keyboard settings saved.") : L("Not saved. %@", problems.map(\.description).joined(separator: " "))
                }
                .disabled(!issues.isEmpty || draft == model.keyboard)
            }
        }
        .onAppear { draft = model.keyboard }
        .onDisappear(perform: stopRecording)
    }

    private func row(_ action: ShortcutAction, issues: [ShortcutIssue]) -> some View {
        let chord = draft.shortcuts[action]
        let problem = issues.contains { $0.involves(action) }
        return HStack {
            Text(action.title)
            Spacer()
            if problem { Image(systemName: "exclamationmark.triangle").help(L("This shortcut has a problem")).accessibilityHidden(true) }
            Button(recording == action ? L("Type shortcut…") : chord?.description ?? L("None")) {
                recording == action ? stopRecording() : startRecording(action)
            }
            .font(.system(.body, design: .monospaced))
            .accessibilityLabel(L("%@ shortcut", action.title))
            .accessibilityValue(recording == action ? L("Recording. Press a shortcut with Command, or Escape to cancel.") : chord?.description ?? L("None"))
            .accessibilityHint(L("Records a new shortcut"))
            Button(L("Clear")) { draft.shortcuts = draft.shortcuts.assigning(nil, to: action) }
                .disabled(chord == nil).accessibilityLabel(L("Clear %@ shortcut", action.title))
        }
        .accessibilityElement(children: .contain)
    }

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        recording = action
        // A local monitor sees the chord before menus, so recording never runs the
        // command currently bound to it. Escape cancels without changing the draft.
        // Settings stays alive when closed (no onDisappear), so a key typed in any
        // other window ends recording and passes through instead of being eaten.
        let settingsWindow = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let settingsWindow, event.window === settingsWindow, settingsWindow.isVisible else {
                stopRecording()
                return event
            }
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            guard let chord = KeyChord(event: event) else { return nil }
            draft.shortcuts = draft.shortcuts.assigning(chord, to: action)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}
