import AppKit
import SwiftUI
import TrellisCore

/// The tool rail (FR-TD01): one button per tool, pressed while that tool is open in the selected tab.
struct ToolRail: View {
    @ObservedObject var model: AppWorkspaceModel

    var body: some View {
        VStack(spacing: 4) {
            ForEach(ToolDockTool.all) { tool in
                let state = model.selectedToolDock
                let pressed = state.isOpen && state.toolID == tool.id
                let edited = model.presentation.selectedTab.map { !model.dirtyBuffers(tabs: [$0.id]).isEmpty } ?? false
                Button {
                    model.toggleToolDock(tool)
                } label: {
                    Image(systemName: tool.symbol).font(.system(size: 14)).frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 6).fill(pressed ? model.sidebarSelectionBackground : .clear))
                        .overlay(alignment: .bottomTrailing) {
                            if edited { Circle().fill(model.themeColor(.warning)).frame(width: 6, height: 6).offset(x: -3, y: -3).accessibilityHidden(true) }
                        }
                }
                .buttonStyle(.plain).foregroundStyle(pressed ? model.themeColor(.accent) : model.themeColor(.mutedForeground))
                .help((model.keyboard.shortcuts[.toggleFiles].map { "\(tool.title) (\($0.description))" } ?? tool.title) + (edited ? " · Edited" : ""))
                .accessibilityLabel(tool.title).accessibilityValue(edited ? "Edited" : "")
                .accessibilityAddTraits(pressed ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(.vertical, 6).frame(width: 38).frame(maxHeight: .infinity).background(model.themeColor(.sidebarBackground))
        .accessibilityElement(children: .contain).accessibilityLabel("Tools")
    }
}

/// The dock for one tab (FR-TD01–FR-TD17): the Files tool's tree and editor.
struct ToolDockView: View {
    @ObservedObject var model: AppWorkspaceModel
    let tabID: UUID
    let floating: Bool

    private var state: ToolDockState { model.toolDock(tabID) }
    private var context: ToolDockContext { model.toolDockContext(tabID) }

    var body: some View {
        HStack(spacing: 0) {
            if !(state.activeFile != nil && state.treeHidden) {
                VStack(spacing: 0) {
                    header
                    Divider().overlay(model.separatorOverlay)
                    // With a file open, the editor shows it instead.
                    if state.activeFile.flatMap({ model.buffer(tabID, $0) }) == nil { OpenFailureBanner(model: model, tabID: tabID) }
                    treeArea
                }
                .frame(width: state.activeFile == nil ? nil : ToolDockLayout.treeOnlyWidth)
                if state.activeFile != nil { Divider().overlay(model.separatorOverlay) }
            }
            if let path = state.activeFile, let buffer = model.buffer(tabID, path) {
                EditorArea(model: model, tabID: tabID, buffer: buffer, floating: floating)
            }
        }
        .background(model.themeColor(.surface))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(floating ? "Files, floating over the panes" : "Files")
    }

    private var header: some View {
        HStack(spacing: 6) {
            switch context {
            case .project(let root, _):
                Text((root as NSString).lastPathComponent).fontWeight(.semibold).lineLimit(1).help(root)
                Text("Local").foregroundStyle(model.themeColor(.mutedForeground))
            case .remote(let host, _):
                Text(host).fontWeight(.semibold).lineLimit(1)
            default:
                Text("Files").fontWeight(.semibold)
            }
            Spacer(minLength: 4)
            if let title = followedPane {
                Image(systemName: "scope").font(.system(size: 11)).foregroundStyle(model.themeColor(.mutedForeground))
                    .help("Follows \(title): the tree shows the focused pane's project").accessibilityLabel("Follows \(title)")
            }
            let side = model.appearance.toolDockSide.other
            Button {
                model.moveToolDockToOtherSide()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.plain).help("Move Dock to the \(side.displayName)").accessibilityLabel("Move Dock to the \(side.displayName)")
            Button {
                model.closeToolDock()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain).help("Close Dock").accessibilityLabel("Close Dock")
        }
        .font(.system(size: 12)).foregroundStyle(model.themeColor(.foreground))
        .padding(.leading, 10).padding(.trailing, 8).frame(height: 30)
    }

    private var followedPane: String? {
        switch context {
        case .project(_, let title), .notAProject(let title), .needsShellIntegration(let title), .remote(_, let title): title
        case .noPane: nil
        }
    }

    @ViewBuilder private var treeArea: some View {
        switch context {
        case .project(let root, _):
            FileTreeView(model: model, tabID: tabID, root: root).id(root)
        case .remote(let host, _):
            DockMessage(model: model, symbol: "network", title: "Files on \(host) aren't available yet", detail: "The editor works on this Mac only for now. Open files stay open; focus a local pane to browse again.")
        case .needsShellIntegration:
            DockMessage(model: model, symbol: "terminal", title: "Shell integration is needed", detail: "The tree follows the directory the pane's shell reports. Turn on shell integration, or start a supported shell.")
        case .notAProject:
            DockMessage(model: model, symbol: "house", title: "Not a project folder", detail: "Your home folder and / aren't shown. cd into a project to browse it.")
        case .noPane:
            DockMessage(model: model, symbol: "rectangle.dashed", title: "No pane is focused", detail: "")
        }
    }
}

/// Why a file didn't open, with Open in Default App (FR-TD10); shown above the tree or the editor.
struct OpenFailureBanner: View {
    @ObservedObject var model: AppWorkspaceModel
    let tabID: UUID
    var body: some View {
        if let failure = model.toolDock(tabID).openFailure {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(model.themeColor(.warning)).accessibilityHidden(true)
                Text("\((failure.path as NSString).lastPathComponent) didn't open: \(failure.message)").lineLimit(2)
                Spacer(minLength: 4)
                Button("Open in Default App") { model.openRefusedFileInDefaultApp(tabID: tabID) }
                Button("Dismiss") { model.dismissOpenFailure(tabID: tabID) }
            }
            .controlSize(.small).font(.system(size: 12)).foregroundStyle(model.themeColor(.foreground)).padding(.horizontal, 10).padding(.vertical, 6)
            .background(model.themeColor(.surface)).accessibilityElement(children: .contain)
        }
    }
}

struct DockMessage: View {
    @ObservedObject var model: AppWorkspaceModel
    let symbol: String, title: String, detail: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(model.themeColor(.mutedForeground)).accessibilityHidden(true)
            Text(title).fontWeight(.semibold)
            if !detail.isEmpty { Text(detail).font(.system(size: 11.5)).foregroundStyle(model.themeColor(.mutedForeground)).multilineTextAlignment(.center) }
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityElement(children: .combine)
    }
}

/// Folder listings for one root, read when a folder is first shown and again every second while visible, so the tree
/// follows changes on disk (FR-TD08).
@MainActor
final class FileTreeModel: ObservableObject {
    let root: String
    @Published private(set) var listings: [String: FileTreeListing] = [:]
    @Published private(set) var filtered: FileTreeListing?
    private var refresh: Timer?

    init(root: String) { self.root = root }

    func listing(_ directory: String) -> FileTreeListing {
        if let cached = listings[directory] { return cached }
        let listing = FileTreeReader.list(directory, root: root)
        DispatchQueue.main.async { [weak self] in self?.listings[directory] = listing }
        return listing
    }

    func start() {
        refresh?.invalidate()
        refresh = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for directory in self.listings.keys {
                    let fresh = FileTreeReader.list(directory, root: self.root)
                    if fresh != self.listings[directory] { self.listings[directory] = fresh }
                }
            }
        }
    }

    func stop() { refresh?.invalidate(); refresh = nil }

    func applyFilter(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        filtered = trimmed.isEmpty ? nil : FileTreeReader.filter(root: root, query: trimmed)
    }
}

struct FileTreeView: View {
    @ObservedObject var model: AppWorkspaceModel
    let tabID: UUID
    let root: String
    @StateObject private var tree: FileTreeModel
    @FocusState private var filterFocused: Bool

    init(model: AppWorkspaceModel, tabID: UUID, root: String) {
        self.model = model; self.tabID = tabID; self.root = root
        _tree = StateObject(wrappedValue: FileTreeModel(root: root))
    }

    private var state: ToolDockState { model.toolDock(tabID) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(model.themeColor(.mutedForeground)).accessibilityHidden(true)
                TextField("Filter files", text: Binding(get: { state.filter }, set: { model.setToolDockFilter($0, tabID: tabID) }))
                    .textFieldStyle(.plain).accessibilityLabel("Filter files").focused($filterFocused)
            }
            .font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(model.themeColor(.border)))
            .padding(8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let filtered = tree.filtered {
                        ForEach(filtered.entries, id: \.path) { entry in row(entry, depth: 0, subtitle: relative(entry.path)) }
                        if filtered.entries.isEmpty { Text("No matches").foregroundStyle(model.themeColor(.mutedForeground)).padding(10) }
                        if filtered.truncated { truncatedNote }
                    } else {
                        rows(in: root, depth: 0)
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 8)
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Project files")
        }
        .onAppear {
            tree.start(); tree.applyFilter(state.filter)
            if state.activeFile == nil { filterFocused = true }
        }
        .onDisappear { tree.stop() }
        .onChange(of: state.filter) { _, next in tree.applyFilter(next) }
        // FR-TD01: opening the dock without a file puts focus in the tree; Esc there closes the dock.
        .onChange(of: model.toolDockFocusRequest) { _, _ in if state.activeFile == nil { filterFocused = true } }
        .onExitCommand { model.closeToolDock() }
    }

    private var truncatedNote: some View {
        Text("Only the first \(FileTreeReader.maximumEntries) entries are shown.").font(.system(size: 11)).foregroundStyle(model.themeColor(.mutedForeground)).padding(8)
    }

    private func relative(_ path: String) -> String? {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.count > root.count ? String(folder.dropFirst(root.count + 1)) : nil
    }

    private func rows(in directory: String, depth: Int) -> AnyView {
        let listing = tree.listing(directory)
        return AnyView(
            Group {
                ForEach(listing.entries, id: \.path) { entry in
                    row(entry, depth: depth, subtitle: nil)
                    if entry.isDirectory, state.expanded.contains(entry.path) { rows(in: entry.path, depth: depth + 1) }
                }
                if listing.truncated { truncatedNote.padding(.leading, CGFloat(depth * 13)) }
            }
        )
    }

    private func row(_ entry: FileTreeEntry, depth: Int, subtitle: String?) -> some View {
        let selected = state.activeFile == entry.path
        let expanded = state.expanded.contains(entry.path)
        let edited = model.buffer(tabID, entry.path)?.isDirty == true
        return Button {
            if entry.isDirectory { model.toggleToolDockFolder(entry.path, tabID: tabID) } else if entry.opensAsFile { model.openFileInToolDock(entry.path, tabID: tabID) }
        } label: {
            HStack(spacing: 5) {
                if entry.isDirectory {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(model.themeColor(.mutedForeground)).frame(width: 10)
                } else {
                    Color.clear.frame(width: 10)
                }
                Image(systemName: symbol(entry)).foregroundStyle(model.themeColor(.mutedForeground)).frame(width: 14)
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                if let subtitle { Text(subtitle).foregroundStyle(model.themeColor(.mutedForeground)).lineLimit(1).truncationMode(.head) }
                Spacer(minLength: 4)
                if edited { Text("Edited").font(.system(size: 10.5)).foregroundStyle(model.themeColor(.mutedForeground)) }
            }
            .font(.system(size: 12)).padding(.leading, CGFloat(4 + depth * 13)).padding(.trailing, 6).frame(height: 23)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? model.sidebarSelectionBackground : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(entry.opensAsFile || entry.isDirectory ? model.themeColor(.foreground) : model.themeColor(.mutedForeground))
        .help(entry.path)
        .accessibilityLabel(accessibilityName(entry, edited: edited))
        .accessibilityValue(entry.isDirectory ? (expanded ? "expanded" : "collapsed") : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func symbol(_ entry: FileTreeEntry) -> String {
        switch entry.kind {
        case .directory: "folder"
        case .file: "doc"
        case .link: "arrow.up.right.square"
        }
    }

    private func accessibilityName(_ entry: FileTreeEntry, edited: Bool) -> String {
        let kind: String
        switch entry.kind {
        case .directory: kind = "folder"
        case .file: kind = "file"
        case .link(let isDirectory, let inside): kind = isDirectory ? "link to a folder" : inside ? "link to a file" : "link outside the project"
        }
        return [entry.name, kind, edited ? "Edited" : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Open files' tabs, the active file's bar, banners and editor (FR-TD10–FR-TD15).
struct EditorArea: View {
    @ObservedObject var model: AppWorkspaceModel
    let tabID: UUID
    @ObservedObject var buffer: EditorBuffer
    let floating: Bool

    private var state: ToolDockState { model.toolDock(tabID) }

    var body: some View {
        VStack(spacing: 0) {
            fileTabs
            Divider().overlay(model.separatorOverlay)
            bar
            Divider().overlay(model.separatorOverlay)
            if floating { info("Floating over the panes, so their size doesn't change.") }
            banners
            FileEditor(
                text: $buffer.text, fileName: buffer.name, languageName: buffer.file.language?.displayName ?? "Plain text", font: editorFont,
                palette: model.effectiveTheme.terminal, isEditable: buffer.file.isWritable, markedLine: state.markedLines[buffer.path],
                revealRequest: state.revealRequest, focusRequest: model.toolDockFocusRequest, saveChord: model.keyboard.shortcuts[.saveWorkspace],
                save: { model.saveFile(buffer.path, tabID: tabID) }
            )
            .id(buffer.path)
            Divider().overlay(model.separatorOverlay)
            footer
        }
        .background(model.terminalBackground)
    }

    private var editorFont: NSFont {
        NSFont(name: model.appearance.fontName, size: CGFloat(model.appearance.fontSize)) ?? .monospacedSystemFont(ofSize: CGFloat(model.appearance.fontSize), weight: .regular)
    }

    private var fileTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(state.openFiles, id: \.self) { path in
                    let selected = path == state.activeFile
                    let edited = model.buffer(tabID, path)?.isDirty == true
                    HStack(spacing: 4) {
                        Button((path as NSString).lastPathComponent) { model.selectFile(path, tabID: tabID) }.buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                            .accessibilityValue(edited ? "Edited" : "")
                        if edited { Text("Edited").font(.system(size: 10.5)).foregroundStyle(model.themeColor(.warning)).accessibilityHidden(true) }
                        Button {
                            model.closeFile(path, tabID: tabID)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9))
                        }
                        .buttonStyle(.plain).accessibilityLabel("Close \((path as NSString).lastPathComponent)")
                    }
                    .font(.system(size: 12)).padding(.horizontal, 10).frame(height: 28)
                    .foregroundStyle(selected ? model.themeColor(.foreground) : model.themeColor(.mutedForeground))
                    .background(selected ? model.terminalBackground : model.themeColor(.surface))
                    .help(path)
                    Divider().overlay(model.separatorOverlay)
                }
            }
        }
        .scrollIndicators(.hidden).frame(height: 28).background(model.themeColor(.surface))
        .accessibilityElement(children: .contain).accessibilityLabel("Open files")
    }

    private var bar: some View {
        HStack(spacing: 8) {
            let treeLabel = state.treeHidden ? "Show File Tree" : "Hide File Tree"
            Button {
                model.setToolDockTreeHidden(!state.treeHidden, tabID: tabID)
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.plain).help(treeLabel).accessibilityLabel(treeLabel)
            Text(displayPath).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head).help(buffer.path)
            Spacer(minLength: 4)
            if buffer.isDirty { Text("Edited").font(.system(size: 11)).foregroundStyle(model.themeColor(.warning)) }
            if !buffer.file.isWritable { Text("Read Only").font(.system(size: 11)).foregroundStyle(model.themeColor(.mutedForeground)).help("You can't write to this file.") }
            let blocked = model.insertPathBlockedReason
            Button("Insert Path") { model.insertPath(buffer.path) }
                .disabled(blocked != nil).help(blocked ?? "Type this path at the focused pane's prompt")
            Button("Save") { model.saveFile(buffer.path, tabID: tabID) }
                .disabled(!buffer.isDirty && !buffer.missingOnDisk || !buffer.file.isWritable)
                .help(model.keyboard.shortcuts[.saveWorkspace].map { "Save (\($0.description))" } ?? "Save")
        }
        .controlSize(.small).font(.system(size: 12)).foregroundStyle(model.themeColor(.mutedForeground))
        .padding(.horizontal, 10).frame(height: 30).background(model.themeColor(.surface))
    }

    private var displayPath: String {
        let home = NSHomeDirectory()
        return buffer.path.hasPrefix(home + "/") ? "~" + buffer.path.dropFirst(home.count) : buffer.path
    }

    @ViewBuilder private var banners: some View {
        OpenFailureBanner(model: model, tabID: tabID)
        switch buffer.conflict {
        case .changedWhileEditing:
            banner("\(buffer.name) changed on disk while you were editing it.") {
                Button("Reload from Disk") { model.reloadFile(buffer.path, tabID: tabID) }
                Button("Keep My Edits") { model.keepEdits(buffer.path, tabID: tabID) }
            }
        case .saveWouldOverwrite:
            banner("\(buffer.name) changed on disk since you opened it. Saving replaces that change.") {
                Button("Overwrite") { model.saveFile(buffer.path, tabID: tabID, overwrite: true) }
                Button("Reload") { model.reloadFile(buffer.path, tabID: tabID) }
                Button("Cancel") { model.keepEdits(buffer.path, tabID: tabID) }
            }
        case nil: EmptyView()
        }
        if buffer.missingOnDisk { banner("\(buffer.name) is no longer on disk. Save recreates it.") { EmptyView() } }
        if let message = buffer.message { banner(message) { EmptyView() } }
    }

    private func banner<Actions: View>(_ text: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(model.themeColor(.warning)).accessibilityHidden(true)
            Text(text).lineLimit(2)
            Spacer(minLength: 4)
            actions()
        }
        .controlSize(.small).font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6).background(model.themeColor(.surface))
        .accessibilityElement(children: .contain)
    }

    private func info(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(model.themeColor(.mutedForeground)).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 5).background(model.themeColor(.surface))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(buffer.file.language?.displayName ?? "Plain text")
            Text(buffer.file.hasByteOrderMark ? "UTF-8 with BOM" : "UTF-8")
            Text(buffer.file.lineEnding.rawValue)
            Spacer()
        }
        .font(.system(size: 10.5)).foregroundStyle(model.themeColor(.mutedForeground)).padding(.horizontal, 10).frame(height: 20)
        .background(model.themeColor(.surface))
    }
}
