import AppKit
import SwiftUI
import TrellisCore
import UniformTypeIdentifiers

/// The sidebar's Files view (FR-FB01–FR-FB07): the focused pane's project as a tree, a file-name search, Open in with the
/// editors on this Mac, and Copy Path. Every action names its file; state is in words and symbols, never color alone.
struct FilesSidebarView: View {
    @ObservedObject var model: AppWorkspaceModel
    let paneID: UUID
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    /// A `cd` re-roots the tree (FR-FB02).
    private var refreshKey: [String?] { [paneID.uuidString, model.paneDirectory(paneID)] }
    private var searching: Bool { model.files.query.contains { !$0.isWhitespace } }

    var body: some View {
        let muted = model.themeColor(.mutedForeground)
        VStack(spacing: 0) {
            SidebarHeader(model: model, view: .files) {
                Toggle(isOn: Binding(get: { model.files.showHidden }, set: { show in Task { await model.setFilesShowHidden(show) } })) {
                    Image(systemName: model.files.showHidden ? "eye" : "eye.slash")
                }
                .toggleStyle(.button).buttonStyle(.plain)
                .help(model.files.showHidden ? L("Hide hidden files") : L("Show hidden files")).accessibilityLabel(L("Show hidden files"))
                Button {
                    model.collapseAllFilesFolders()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").rotationEffect(.degrees(90))
                }
                .help(L("Collapse all folders")).accessibilityLabel(L("Collapse All Folders"))
                Button {
                    Task { await model.refreshFiles(paneID: paneID, reloadEditors: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L("Read the folder again")).accessibilityLabel(L("Reload Files"))
            }
            Divider().overlay(model.separatorOverlay)
            if let root = model.files.root {
                toolbar(root: root)
                if searching { results } else { tree }
                if let status = model.files.status {
                    Label(status, systemImage: "checkmark.circle.fill").font(.caption).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(model.themeColor(.background)))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(model.themeColor(.border)))
                        .padding(.horizontal, 12).padding(.bottom, 6).transition(.opacity)
                }
                Divider().overlay(model.separatorOverlay)
                Text(L("↩ Open in %@ · ⇧⌘C Copy Path · ⌥↩ Insert in terminal", model.files.editor.name))
                    .font(.caption).foregroundStyle(muted).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("No folder")).font(.headline)
                    Text(L("The focused pane has no folder on this Mac yet. Its shell reports one after its first prompt."))
                        .font(.callout).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(model.chromeFill(.surface))
        .accessibilityElement(children: .contain).accessibilityLabel(L("Files"))
        .animation(.easeOut(duration: 0.15), value: model.files.status)
        .task(id: refreshKey) { await model.refreshFiles(paneID: paneID) }
        .onChange(of: model.filesFocusRequest, initial: true) { DispatchQueue.main.async { searchFocused = true } }
        .onChange(of: model.files.status) { _, status in
            if let status { AccessibilityNotification.Announcement(status).post() }
        }
    }

    // MARK: Search field and Open in

    private func toolbar(root: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(AppWorkspaceModel.abbreviatingHome(root)).font(.system(size: 11, design: .monospaced)).foregroundStyle(model.themeColor(.foreground))
                    .lineLimit(1).truncationMode(.head).help(root)
                Text(L("· follows the focused pane")).font(.caption).foregroundStyle(model.themeColor(.mutedForeground)).lineLimit(1).fixedSize()
            }.accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                TextField(L("Search files…"), text: Binding(get: { model.files.query }, set: { model.setFilesQuery($0) }))
                    .textFieldStyle(.roundedBorder).focused($searchFocused).accessibilityLabel(L("Search files"))
                    .onKeyPress(phases: .down) { handleKey($0) }
                openInMenu
            }
        }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    }

    private var openInMenu: some View {
        let editor = model.files.editor
        let target = model.files.selectedEntry
        return Menu {
            ForEach(model.files.editors) { app in
                Button {
                    Task { await model.openFile(target, in: app) }
                } label: {
                    editorLabel(app, checked: app.id == editor.id)
                }
            }
            Divider()
            Button(L("Other App…")) { chooseOtherApp(for: target) }
        } label: {
            editorLabel(editor, checked: false, title: L("Open in"))
        } primaryAction: {
            Task { await model.openFile(target) }
        }
        .menuStyle(.button).fixedSize().controlSize(.regular)
        .help(target.map { L("Open %1$@ in %2$@; the arrow chooses another app", $0.name, editor.name) } ?? L("Open the project folder in %@; the arrow chooses another app", editor.name))
        .accessibilityLabel(L("Open in %@", editor.name))
    }

    @ViewBuilder private func editorLabel(_ app: EditorApp, checked: Bool, title: String? = nil) -> some View {
        let label = title ?? (checked ? "\(app.name) ✓" : app.name)
        if let url = model.filesEditorAppURL(app) {
            Label {
                Text(label)
            } icon: {
                Image(nsImage: Self.icon(url))
            }
        } else {
            Label(label, systemImage: app.id == EditorApp.newTab.id ? "plus.rectangle.on.rectangle" : "doc")
        }
    }

    /// Loaded once per app: the menu is rebuilt on every model change.
    @MainActor private static var icons: [URL: NSImage] = [:]

    private static func icon(_ app: URL) -> NSImage {
        if let image = icons[app] { return image }
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 16, height: 16)
        icons[app] = image
        return image
    }

    private func chooseOtherApp(for entry: FileEntry?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("Open")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        model.openFile(entry, withApp: app)
    }

    // MARK: Tree (FR-FB03)

    private var tree: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.files.rows) { row in
                        if row.unreadable {
                            Label(L("Can't read this folder"), systemImage: "exclamationmark.triangle").font(.caption)
                                .foregroundStyle(model.themeColor(.mutedForeground)).padding(.leading, CGFloat(row.depth) * 16 + 26).frame(height: 24)
                        } else {
                            FileRow(model: model, entry: row.entry, depth: row.depth, title: AttributedString(row.entry.name), subtitle: nil)
                        }
                    }
                }.padding(.horizontal, 6).padding(.vertical, 2)
            }
            .focusable().focused($listFocused).focusEffectDisabled()
            .onKeyPress(phases: .down) { handleKey($0) }
            .onChange(of: model.files.selection) { _, path in if let path { proxy.scrollTo(path) } }
            .accessibilityLabel(L("Project files"))
        }
    }

    // MARK: Search results (FR-FB04)

    @ViewBuilder private var results: some View {
        let muted = model.themeColor(.mutedForeground)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let result = model.files.search {
                        Text(summary(result)).font(.caption).foregroundStyle(muted).padding(.horizontal, 8).padding(.bottom, 4)
                        ForEach(result.matches) { match in
                            FileRow(model: model, entry: match.entry, depth: 0, title: highlighted(match), subtitle: match.relativeFolder.isEmpty ? "/" : match.relativeFolder)
                        }
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 12)
                    }
                }.padding(.horizontal, 6).padding(.vertical, 2)
            }
            .onChange(of: model.files.selection) { _, path in if let path { proxy.scrollTo(path) } }
            .accessibilityLabel(L("Matching files"))
        }
    }

    private func summary(_ result: FileSearchResult) -> String {
        let count = result.matches.count
        guard result.truncated else { return count == 0 ? L("No files match") : count == 1 ? L("1 match") : L("%d matches", count) }
        let limit = FileBrowser.searchFileLimit.formatted()
        return count == 0 ? L("No files match in the first %@ files", limit) : count == 1 ? L("1 match in the first %@ files", limit) : L("%1$d matches in the first %2$@ files", count, limit)
    }

    private func highlighted(_ match: FileSearchMatch) -> AttributedString {
        var text = AttributedString()
        let positions = Set(match.namePositions)
        for (index, character) in match.entry.name.enumerated() {
            var piece = AttributedString(String(character))
            if positions.contains(index) {
                piece.font = .system(size: 12.5, weight: .bold)
                piece.foregroundColor = model.themeColor(.accent)
            }
            text += piece
        }
        return text
    }

    // MARK: Keyboard (FR-FB07)

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let entry = model.files.selectedEntry
        switch press.key {
        case .downArrow: model.moveFilesSelection(by: 1)
        case .upArrow: model.moveFilesSelection(by: -1)
        case .rightArrow where !searchFocused:
            guard let entry, entry.isDirectory, !model.files.expanded.contains(entry.path) else { return .ignored }
            Task { await model.toggleFilesFolder(entry.path) }
        case .leftArrow where !searchFocused:
            guard let entry, entry.isDirectory, model.files.expanded.contains(entry.path) else { return .ignored }
            Task { await model.toggleFilesFolder(entry.path) }
        case .return:
            if press.modifiers.contains(.option) {
                guard let entry else { return .ignored }
                model.insertFilePath(entry)
            } else if let entry, entry.isDirectory, !searching {
                Task { await model.toggleFilesFolder(entry.path) }
            } else {
                Task { await model.openFile(entry) }
            }
        case .escape:
            guard searching else { return .ignored }
            model.setFilesQuery("")
        default:
            // ⌥ changes the typed letter (⌥⇧C is "Ç" on a US layout), so both forms of C count.
            guard ["c", "ç"].contains(press.characters.lowercased()), press.modifiers == [.command, .shift] || press.modifiers == [.command, .shift, .option], let entry else { return .ignored }
            model.copyFilePath(entry, style: press.modifiers.contains(.option) ? .relative : .absolute)
        }
        return .handled
    }
}

/// One file or folder line: disclosure, icon, name (with its folder in search), and Copy Path and Open on hover or selection.
private struct FileRow: View {
    @ObservedObject var model: AppWorkspaceModel
    let entry: FileEntry
    let depth: Int
    let title: AttributedString
    let subtitle: String?
    @State private var hovering = false

    var body: some View {
        let selected = model.files.selection == entry.path
        let expanded = model.files.expanded.contains(entry.path)
        let muted = model.themeColor(.mutedForeground)
        HStack(spacing: 6) {
            if subtitle == nil {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(muted)
                    .frame(width: 10).opacity(entry.isDirectory ? 1 : 0).accessibilityHidden(true)
            }
            Image(systemName: entry.isDirectory ? "folder" : entry.isSymbolicLink ? "arrow.up.right.square" : "doc").font(.system(size: 12))
                .foregroundStyle(selected ? model.themeColor(.foreground) : muted).frame(width: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle).foregroundStyle(model.themeColor(.foreground))
                if let subtitle { Text(subtitle).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(muted).lineLimit(1).truncationMode(.head) }
            }
            Spacer(minLength: 4)
            if hovering || selected {
                Button {
                    model.copyFilePath(entry)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help(L("Copy Path (⇧⌘C)")).accessibilityLabel(L("Copy path of %@", entry.name))
                Button {
                    Task { await model.openFile(entry) }
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .help(L("Open in %@", model.files.editor.name)).accessibilityLabel(L("Open %1$@ in %2$@", entry.name, model.files.editor.name))
            }
        }
        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(model.themeColor(.foreground))
        .padding(.leading, CGFloat(depth) * 16 + 6).padding(.trailing, 6).padding(.vertical, subtitle == nil ? 0 : 4)
        .frame(minHeight: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(background(selected: selected)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? model.themeColor(.accent).opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .id(entry.path)
        .onHover { hovering = $0 }
        // A single tap answering every click: one that waited to rule out a double click (`exclusively(before:)`) held each
        // click back for the system's double-click interval. The second click of a double click is told apart by its count.
        .onTapGesture { clicked(count: Self.currentClickCount) }
        .onDrag { NSItemProvider(object: URL(fileURLWithPath: entry.path) as NSURL) }
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.name)
        .accessibilityValue(spokenValue(expanded: expanded))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { activate() }
        .accessibilityAction(named: L("Copy Path")) { model.copyFilePath(entry) }
        .accessibilityAction(named: L("Insert Path in Terminal")) { model.insertFilePath(entry) }
    }

    private var isTreeFolder: Bool { entry.isDirectory && subtitle == nil }

    private func background(selected: Bool) -> Color {
        if selected { return model.sidebarSelectionBackground }
        return hovering ? model.themeColor(.foreground).opacity(0.05) : .clear
    }

    private func spokenValue(expanded: Bool) -> String {
        guard let subtitle else { return entry.isDirectory ? (expanded ? L("folder, expanded") : L("folder, collapsed")) : L("file") }
        return entry.isDirectory ? (expanded ? L("folder, expanded, in %@", subtitle) : L("folder, collapsed, in %@", subtitle)) : L("file, in %@", subtitle)
    }

    /// The click count of the mouse event being handled, 1 when there is none: `clickCount` raises on any other event.
    private static var currentClickCount: Int {
        guard let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].contains(event.type) else { return 1 }
        return event.clickCount
    }

    /// A click selects at once; on a tree folder it opens or closes it too. The second click of a double click opens a file;
    /// on a tree folder it does nothing more, since the first click already opened or closed it.
    private func clicked(count: Int) {
        switch count {
        case ...1: if isTreeFolder { Task { await model.toggleFilesFolder(entry.path) } } else { model.selectFile(entry.path) }
        case 2 where !isTreeFolder: activate()
        default: break
        }
    }

    /// VoiceOver's default action (and a double click on a file) opens a file in the editor; a tree folder opens or closes.
    private func activate() {
        if isTreeFolder {
            Task { await model.toggleFilesFolder(entry.path) }
        } else {
            model.selectFile(entry.path)
            Task { await model.openFile(entry) }
        }
    }

    @ViewBuilder private var menu: some View {
        let editor = model.files.editor
        Button(L("Open in %@", editor.name)) { Task { await model.openFile(entry) } }
        // An editor tab is one click away whichever app is remembered; choosing it here isn't remembered (FR-ED09).
        if editor != .trellisEditor, !entry.isDirectory {
            Button(L("Open in %@", EditorApp.trellisEditor.name)) { Task { await model.openFile(entry, in: .trellisEditor, remember: false) } }
        }
        Menu(L("Open With")) {
            ForEach(model.files.editors) { app in Button(app.name) { Task { await model.openFile(entry, in: app) } } }
        }
        Button(L("Reveal in Finder")) { model.revealFile(entry) }
        Divider()
        Button(L("Copy Path")) { model.copyFilePath(entry) }
        Button(L("Copy Relative Path")) { model.copyFilePath(entry, style: .relative) }
        Button(L("Copy Name")) { model.copyFilePath(entry, style: .name) }
        Divider()
        Button(L("Insert Path in Terminal")) { model.insertFilePath(entry) }
        Button(entry.isDirectory ? L("Type cd to This Folder") : L("Type cd to Its Folder")) { model.typeChangeDirectory(entry) }
    }
}
