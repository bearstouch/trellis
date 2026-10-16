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
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Use Option as Meta key", isOn: $draft.optionAsMeta)
            Text("When off, Option types accented and layout characters (such as Portuguese symbols and dead keys). When on, Option sends Esc-prefixed Meta keys.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(ShortcutMenu.allCases, id: \.self) { menu in
                    Section(menu.rawValue.capitalized) {
                        ForEach(ShortcutAction.allCases.filter { $0.menu == menu }, id: \.self) { row($0, issues: issues) }
                    }
                }
            }
            .frame(minHeight: 220)
            .accessibilityLabel("Keyboard shortcuts")
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                        Label(issue.description, systemImage: "exclamationmark.triangle").font(.caption)
                    }
                }.accessibilityElement(children: .combine).accessibilityLabel("Shortcut problems: \(issues.map(\.description).joined(separator: " "))")
            }
            if let notice = model.keyboardNotice { Text(notice).font(.caption) }
            if let message { Text(message).font(.caption).accessibilityIdentifier("keyboard.result") }
            HStack {
                Button("Restore Defaults") {
                    let meta = draft.optionAsMeta
                    draft = KeyboardSettings()
                    draft.optionAsMeta = meta
                }
                Spacer()
                Button("Revert") { draft = model.keyboard }.disabled(draft == model.keyboard)
                Button("Save Shortcuts") {
                    let problems = model.saveKeyboardSettings(draft)
                    message = problems.isEmpty ? "Keyboard settings saved." : "Not saved. \(problems.map(\.description).joined(separator: " "))"
                }.disabled(!issues.isEmpty || draft == model.keyboard)
            }
        }
        .padding(16)
        .onAppear { draft = model.keyboard }
        .onDisappear(perform: stopRecording)
    }

    private func row(_ action: ShortcutAction, issues: [ShortcutIssue]) -> some View {
        let chord = draft.shortcuts[action]
        let problem = issues.contains { $0.involves(action) }
        return HStack {
            Text(action.title)
            Spacer()
            if problem { Image(systemName: "exclamationmark.triangle").help("This shortcut has a problem").accessibilityHidden(true) }
            Button(recording == action ? "Type shortcut…" : chord?.description ?? "None") {
                recording == action ? stopRecording() : startRecording(action)
            }
            .font(.system(.body, design: .monospaced))
            .accessibilityLabel("\(action.title) shortcut")
            .accessibilityValue(recording == action ? "Recording. Press a shortcut with Command, or Escape to cancel." : chord?.description ?? "None")
            .accessibilityHint("Records a new shortcut")
            Button("Clear") { draft.shortcuts = draft.shortcuts.assigning(nil, to: action) }
                .disabled(chord == nil).accessibilityLabel("Clear \(action.title) shortcut")
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
