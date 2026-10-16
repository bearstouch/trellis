import AppKit
import SwiftUI
import TrellisCore

struct ThemeLibraryControls: View {
    @ObservedObject var workspace: AppWorkspaceModel
    @ObservedObject var preview: ThemePreviewModel
    @State private var selectedID = "trellis-light"
    @State private var message: String?
    @State private var confirmDelete = false
    private var selected: ResolvedTheme? { workspace.allThemes.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Installed theme", selection: $selectedID) {
                ForEach(workspace.allThemes, id: \.id) { Text("\($0.name) (\($0.appearance.rawValue))").tag($0.id) }
            }.onChange(of: selectedID) { _, id in showInstalled(id) }
            HStack {
                Button("Use Theme") { workspace.useTheme(selectedID) }
                Button("Export…") { export(resolved: false) }
                Button("Export Resolved…") { export(resolved: true) }
                Button("Delete…", role: .destructive) { confirmDelete = true }.disabled(!workspace.themeCatalog.documents.keys.contains(selectedID))
            }
            HStack {
                Button("Reload Themes") { Task { await workspace.reloadThemes() } }
                Button("Open Themes Folder") { Task { await workspace.openThemesFolder() } }
            }
            Divider()
            HStack {
                Button("Preview in Workspace") {
                    if let document = preview.document { workspace.previewThemeInWorkspace(document) }
                }.disabled(preview.document == nil)
                Button("Cancel Preview") { workspace.cancelThemePreview() }.disabled(workspace.previewedTheme == nil)
                Button("Save & Use Theme") { save(replace: false) }.disabled(preview.document == nil || preview.document?.hasReservedID == true)
            }
            if let document = preview.document, workspace.themeReplacementID == document.id {
                Button("Replace Theme") { save(replace: true) }
                Text("Replace overwrites the installed file for this ID.").font(.caption).foregroundStyle(.secondary)
            }
            if let notice = workspace.themeNotice { Text(notice).font(.caption).textSelection(.enabled) }
            if let message { Text(message).font(.caption).textSelection(.enabled) }
        }
        .disabled(workspace.themeBusy || workspace.isRestoring || workspace.themesDirectory == nil)
        .confirmationDialog("Delete \(selected?.name ?? "theme")? Selected appearances will use their built-in theme.", isPresented: $confirmDelete) {
            Button("Delete Theme", role: .destructive) {
                let id = selectedID
                Task {
                    await workspace.deleteTheme(id)
                    if selected == nil { selectedID = "trellis-light" }
                }
            }
        }
        .onChange(of: workspace.themeCatalog) { _, _ in
            if selected == nil { selectedID = "trellis-light" }
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
                panel.title = resolved ? "Export Resolved Theme" : "Export Theme"
                panel.nameFieldStringValue = id + ".theme.json"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try await Task.detached { try data.write(to: url, options: .atomic) }.value
                message = "Theme exported."
            } catch { message = error.localizedDescription }
        }
    }
}
