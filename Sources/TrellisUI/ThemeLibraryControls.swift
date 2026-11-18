import AppKit
import SwiftUI
import TrellisCore

/// Settings → Themes: the library section, then the preview section around the caller's sample.
struct ThemeLibraryControls<Sample: View>: View {
    @ObservedObject var workspace: AppWorkspaceModel
    @ObservedObject var preview: ThemePreviewModel
    @ViewBuilder var sample: Sample
    @State private var selectedID = "trellis-light"
    @State private var message: String?
    @State private var confirmDelete = false
    private var selected: ResolvedTheme? { workspace.allThemes.first { $0.id == selectedID } }
    private var busy: Bool { workspace.themeBusy || workspace.isRestoring || workspace.themesDirectory == nil }
    var body: some View {
        Section(L("Library")) {
            Picker(L("Installed theme"), selection: $selectedID) {
                ForEach(workspace.allThemes, id: \.id) { Text($0.appearance == .light ? L("%@ (light)", $0.name) : L("%@ (dark)", $0.name)).tag($0.id) }
            }
            .onChange(of: selectedID) { _, id in showInstalled(id) }
            .onChange(of: workspace.themeCatalog) { _, _ in
                if selected == nil { selectedID = "trellis-light" }
            }
            HStack {
                Button(L("Use Theme")) { workspace.useTheme(selectedID) }
                Button(L("Export…")) { export(resolved: false) }
                Button(L("Export Resolved…")) { export(resolved: true) }
                Button(L("Delete…"), role: .destructive) { confirmDelete = true }.disabled(!workspace.themeCatalog.documents.keys.contains(selectedID))
                Spacer(minLength: 0)
            }
            .confirmationDialog(
                selected.map { L("Delete %@? Selected appearances will use their built-in theme.", $0.name) } ?? L("Delete theme? Selected appearances will use their built-in theme."),
                isPresented: $confirmDelete
            ) {
                Button(L("Delete Theme"), role: .destructive) {
                    let id = selectedID
                    Task {
                        await workspace.deleteTheme(id)
                        if selected == nil { selectedID = "trellis-light" }
                    }
                }
            }
            HStack {
                Button(L("Reload Themes")) { Task { await workspace.reloadThemes() } }
                Button(L("Open Themes Folder")) { Task { await workspace.openThemesFolder() } }
                Spacer(minLength: 0)
            }
            if let notice = workspace.themeNotice { SettingsNote(text: notice).textSelection(.enabled) }
            if let message { SettingsNote(text: message).textSelection(.enabled) }
        }
        .disabled(busy)
        // The sample's own controls (Preview JSON…, examples) need no library, so only the library actions wait on it.
        Section(L("Preview")) {
            sample
            HStack {
                Button(L("Preview in Workspace")) {
                    if let document = preview.document { workspace.previewThemeInWorkspace(document) }
                }
                .disabled(preview.document == nil)
                Button(L("Cancel Preview")) { workspace.cancelThemePreview() }.disabled(workspace.previewedTheme == nil)
                Button(L("Save & Use Theme")) { save(replace: false) }.disabled(preview.document == nil || preview.document?.hasReservedID == true)
                Spacer(minLength: 0)
            }
            .disabled(busy)
            if let document = preview.document, workspace.themeReplacementID == document.id {
                LabeledContent {
                    Button(L("Replace Theme")) { save(replace: true) }
                } label: {
                    SettingsLabel(L("Replace Theme"), help: L("Replace overwrites the installed file for this ID."))
                }
                .disabled(busy)
            }
        }
    }
    private func showInstalled(_ id: String) {
        let generation = preview.contentGeneration
        Task {
            do {
                let data = try await workspace.exportTheme(id, resolved: false)
                guard selectedID == id, preview.contentGeneration == generation else { return }
                _ = preview.preview(data)
            } catch {
                guard selectedID == id, preview.contentGeneration == generation else { return }
                message = error.localizedDescription
            }
        }
    }
    private func save(replace: Bool) {
        guard let document = preview.document else { return }
        Task {
            if await workspace.saveTheme(document, replace: replace) { selectedID = document.id }
        }
    }
    private func export(resolved: Bool) {
        let id = selectedID
        Task {
            do {
                let data = try await workspace.exportTheme(id, resolved: resolved)
                let panel = NSSavePanel()
                panel.title = resolved ? L("Export Resolved Theme") : L("Export Theme")
                panel.nameFieldStringValue = id + ".theme.json"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try await Task.detached { try data.write(to: url, options: .atomic) }.value
                message = L("Theme exported.")
            } catch { message = error.localizedDescription }
        }
    }
}
