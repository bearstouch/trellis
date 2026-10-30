import AppKit
import SwiftUI
import TrellisControl
import TrellisCore

/// The project library window (FR-PL01–FR-PL04): a searchable list, and the selected project's form or JSON editor.
public struct ProjectLibraryView: View {
    @ObservedObject private var model: ProjectListModel
    @ObservedObject private var workspace: AppWorkspaceModel
    /// The stored project being edited; nil for a new, captured or imported one.
    @State private var selection: UUID?
    @State private var draft: ProjectDefinition
    /// What the draft was loaded as; nil for a captured or imported project, which stays unsaved until added.
    @State private var baseline: ProjectDefinition?
    @State private var place = ProjectDefinition.Place.project
    @State private var showsJSON = false
    @State private var jsonText = ""
    @State private var jsonProblems: [String]?
    @State private var message: String?
    @State private var warnings: [String] = []
    @State private var saving = false
    @State private var confirmingDelete = false
    /// A selection or a captured/imported project that arrived while the draft had unsaved changes.
    private enum PendingChange { case select(UUID?), draft(ProjectCapture) }
    @State private var pendingChange: PendingChange?
    @FocusState private var listFocused: Bool
    public init(model: ProjectListModel, workspace: AppWorkspaceModel) {
        self.model = model; self.workspace = workspace
        let blank = ProjectDefinition(name: "New Project")
        _draft = State(initialValue: blank); _baseline = State(initialValue: blank)
    }

    private var stored: ProjectDefinition? { selection.flatMap { id in model.projects.first { $0.id == id } } }
    private var issues: [ProjectDefinition.Issue] { draft.normalized.issues }
    /// The form's changes, plus in JSON mode any edit of the text the form's project was shown as.
    private var isDirty: Bool { (baseline.map { draft.normalized != $0.normalized } ?? true) || (showsJSON && jsonText != Self.json(draft)) }
    private static func json(_ project: ProjectDefinition) -> String { String(decoding: ProjectJSON.encode(project.normalized), as: UTF8.self) }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(workspace.themeColor(.border)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(stored == nil ? "New Project" : "Edit Project").font(.system(size: 22, weight: .semibold))
                        Text("Tabs, splits, folders, commands and repositories. Launch it on this Mac or a saved host.")
                            .font(.callout).foregroundStyle(workspace.themeColor(.mutedForeground))
                    }
                    Spacer()
                    Picker("Editor", selection: Binding(get: { showsJSON }, set: switchEditor)) {
                        Text("Form").tag(false)
                        Text("JSON").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 140).accessibilityLabel("Editor")
                }
                .padding(28)
                Divider().padding(.horizontal, 28)
                if showsJSON { jsonEditor.padding(28) } else { form.padding(.horizontal, 28).padding(.vertical, 18) }
                footer.padding(.horizontal, 28).padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(workspace.themeColor(.foreground))
            .background(workspace.themeColor(.background))
        }
        .tint(workspace.chromeTint)
        .preferredColorScheme(workspace.effectiveChromeMode.colorScheme)
        .frame(minWidth: 900, minHeight: 600)
        .task { await model.load() }
        .onChange(of: model.pendingDraft) { _, capture in takePendingDraft(capture) }
        .onAppear { takePendingDraft(model.pendingDraft) }
        .onChange(of: isDirty, initial: true) { _, dirty in model.editorDirty = dirty }
        .onChange(of: model.saveRequests) { save(then: model.takeAfterRequestedSave()) }
        .onChange(of: model.discardRequests) { select(selection, force: true) }
        .confirmationDialog("Delete “\(stored?.name ?? "")”?", isPresented: $confirmingDelete) {
            Button("Delete Project", role: .destructive, action: delete)
        } message: {
            Text("Only the project definition is removed. Its folders, repositories and open windows are not changed.")
        }
        .confirmationDialog(
            "Save changes to “\(draft.name)”?", isPresented: Binding(get: { pendingChange != nil }, set: { if !$0 { pendingChange = nil } })
        ) {
            Button("Save") {
                let change = pendingChange
                save { apply(change) }
            }
            Button("Discard Changes", role: .destructive) { apply(pendingChange) }
        } message: {
            Text("The project has changes that aren't saved.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PROJECTS").font(.system(size: 11, weight: .semibold)).foregroundStyle(workspace.themeColor(.mutedForeground))
                .padding(.horizontal, 12).padding(.top, 24).padding(.bottom, 6)
            TextField("Search projects", text: $model.query).textFieldStyle(.roundedBorder).accessibilityLabel("Search projects")
                .accessibilityHint("Matches names, notes and repository URLs").padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) { ForEach(model.visibleProjects) { projectRow($0) } }
                }
                .focusable().focused($listFocused)
                .onKeyPress(.upArrow) { moveSelection(-1, proxy) }
                .onKeyPress(.downArrow) { moveSelection(1, proxy) }
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Projects")
            .overlay {
                if model.visibleProjects.isEmpty {
                    Text(model.projects.isEmpty ? "No projects yet" : "No matching projects").foregroundStyle(workspace.themeColor(.mutedForeground))
                }
            }
            sidebarAction("New Project", symbol: "plus") { select(nil) }
            sidebarAction("New from Window…", symbol: "macwindow") { captureActiveWindow() }
                .disabled(workspace.snapshot.activeWindowID == nil).help("Make a project from the workspace's active window")
            sidebarAction("Import JSON…", symbol: "square.and.arrow.down") { importJSON() }
            sidebarAction("Export JSON…", symbol: "square.and.arrow.up") { exportJSON() }
                .disabled(stored == nil).help(stored == nil ? "Save the project first" : "Save the selected project as a JSON file")
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
        .frame(width: 250)
        .background(workspace.themeColor(.sidebarBackground))
    }

    private func projectRow(_ project: ProjectDefinition) -> some View {
        let selected = selection == project.id
        let details = [model.summary(project), model.lastLaunched(project)].compactMap { $0 }
        return Button {
            select(project.id); listFocused = true
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).lineLimit(1).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(workspace.themeColor(selected ? .activeTabForeground : .foreground))
                ForEach(details, id: \.self) { Text($0).font(.caption).foregroundStyle(workspace.themeColor(.mutedForeground)).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
            .background(selected ? workspace.themeColor(.activeTabBackground) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).id(project.id)
        .accessibilityElement(children: .combine).accessibilityLabel("Project \(project.name)").accessibilityValue(details.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func moveSelection(_ step: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = model.visibleProjects.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let index = selection.flatMap { ids.firstIndex(of: $0) }.map { min(max($0 + step, 0), ids.count - 1) } ?? (step > 0 ? 0 : ids.count - 1)
        select(ids[index]); proxy.scrollTo(ids[index])
        return .handled
    }

    private func sidebarAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
            }
            .font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
            .foregroundStyle(workspace.themeColor(.foreground))
        }
        .buttonStyle(.plain)
    }

    // MARK: Form (FR-PL02)

    private var form: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Layout").font(.headline)
                    Spacer()
                    toolButton("Add Tab", symbol: "plus.rectangle") { place = .tab(draft.addTab()) }.disabled(draft.tabs.count >= ProjectDefinition.maximumTabs)
                    toolButton("Split Right", symbol: "rectangle.split.2x1") { split(.x) }.disabled(!selectionIsPane || draft.paneCount >= ProjectDefinition.maximumPanes)
                    toolButton("Split Down", symbol: "rectangle.split.1x2") { split(.y) }.disabled(!selectionIsPane || draft.paneCount >= ProjectDefinition.maximumPanes)
                    toolButton("Remove", symbol: "minus") { remove() }.disabled(!canRemove)
                    toolButton("Move Up", symbol: "arrow.up") { moveTab(-1) }.disabled(!canMoveTab(-1))
                    toolButton("Move Down", symbol: "arrow.down") { moveTab(1) }.disabled(!canMoveTab(1))
                }
                ScrollView { outline.frame(maxWidth: .infinity, alignment: .leading) }
                    .padding(6).background(workspace.themeColor(.sidebarBackground), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain).accessibilityLabel("Project layout")
            }
            .frame(width: 330)
            ScrollView { detail.frame(maxWidth: .infinity, alignment: .leading) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var outline: some View {
        VStack(alignment: .leading, spacing: 1) {
            outlineRow("Project", detail: model.summary(draft.normalized), depth: 0, at: .project, symbol: "folder")
            ForEach(Array(draft.tabs.enumerated()), id: \.offset) { index, tab in
                outlineRow(
                    tab.title.isEmpty ? "Untitled tab" : tab.title, detail: tab.repository.map { "⎇ " + GitRepository.shortName($0.url) }, depth: 1, at: .tab(index),
                    symbol: "rectangle.on.rectangle", color: tab.color)
                nodeRows(tab.root, tab: index, path: [], depth: 2)
            }
        }
    }

    private func nodeRows(_ node: ProjectNode, tab: Int, path: [Int], depth: Int) -> AnyView {
        switch node {
        case .pane(let pane):
            let detail = pane.command ?? pane.repository.map { "⎇ " + GitRepository.shortName($0.url) } ?? pane.directory
            return AnyView(outlineRow(pane.title ?? "Pane", detail: detail, depth: depth, at: .node(tab: tab, path: path), symbol: "terminal"))
        case .split(let axis, _, let first, let second):
            return AnyView(
                VStack(alignment: .leading, spacing: 1) {
                    outlineRow(
                        axis == .x ? "Split right" : "Split down", detail: nil, depth: depth, at: .node(tab: tab, path: path),
                        symbol: axis == .x ? "rectangle.split.2x1" : "rectangle.split.1x2")
                    nodeRows(first, tab: tab, path: path + [0], depth: depth + 1)
                    nodeRows(second, tab: tab, path: path + [1], depth: depth + 1)
                })
        }
    }

    private func outlineRow(_ title: String, detail: String?, depth: Int, at row: ProjectDefinition.Place, symbol: String, color: TabColor? = nil) -> some View {
        let selected = place == row
        let flagged = issues.contains { $0.place == row }
        return Button {
            place = row
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color.map { AnyShapeStyle($0.swatchColor) } ?? AnyShapeStyle(workspace.themeColor(.mutedForeground)))
                    .frame(width: 16).accessibilityHidden(true)
                Text(title).lineLimit(1).fontWeight(depth <= 1 ? .semibold : .regular)
                if flagged { Image(systemName: "exclamationmark.circle").foregroundStyle(.red).accessibilityHidden(true) }
                Spacer(minLength: 8)
                if let detail { Text(detail).font(.system(size: 11, design: .monospaced)).lineLimit(1).foregroundStyle(workspace.themeColor(.mutedForeground)) }
            }
            .font(.system(size: 12.5)).padding(.leading, CGFloat(depth) * 14 + 6).padding(.trailing, 6).padding(.vertical, 5).contentShape(Rectangle())
            .background(selected ? workspace.themeColor(.activeTabBackground) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title).accessibilityValue([detail, flagged ? "has problems" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toolButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 18, height: 16) }.help(title).accessibilityLabel(title)
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.loadFailed {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ProjectListModel.message(for: .readOnly)).font(.callout)
                    Button("Reset Project Library") {
                        Task { message = await model.resetUnreadable() ? "The unreadable file was kept beside the new library." : "The project library could not be reset." }
                    }
                }
            }
            switch place {
            case .project: projectDetail
            case .tab(let index) where draft.tabs.indices.contains(index): tabDetail(index)
            case .node(let tab, let path) where draft.tabs.indices.contains(tab):
                switch draft.tabs[tab].root[path] {
                case .pane(let pane)?: paneDetail(pane, tab: tab, path: path)
                case .split(let axis, let ratio, _, _)?: splitDetail(axis: axis, ratio: ratio, tab: tab, path: path)
                case nil: EmptyView()
                }
            default: EmptyView()
            }
            ForEach(warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).fixedSize(horizontal: false, vertical: true) }
        }
    }

    @ViewBuilder private var projectDetail: some View {
        Text("Project").font(.headline)
        field("Name", text: Binding(get: { draft.name }, set: { draft.name = $0 }), error: issue(.project, .name), prompt: "Shop")
        VStack(alignment: .leading, spacing: 3) {
            Text("Notes (optional)").font(.caption).foregroundStyle(workspace.themeColor(.mutedForeground))
            TextEditor(text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0 })).font(.body).frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(workspace.themeColor(.border))).accessibilityLabel("Notes")
            errorLabel(issue(.project, .notes))
        }
        repositoryFields(
            "Project repository", note: "The project folder itself is a checkout.", repository: draft.repository, at: .project,
            set: { draft.repository = $0 })
    }

    @ViewBuilder private func tabDetail(_ index: Int) -> some View {
        let tab = draft.tabs[index]
        Text("Tab").font(.headline)
        field("Title", text: Binding(get: { tab.title }, set: { draft.tabs[index].title = $0 }), error: issue(.tab(index), .title), prompt: "API")
        Picker("Color", selection: Binding(get: { tab.color }, set: { draft.tabs[index].color = $0 })) {
            Text("None").tag(TabColor?.none)
            ForEach(TabColor.allCases, id: \.self) { color in
                Label {
                    Text(color.displayName)
                } icon: {
                    color.swatchImage
                }.tag(TabColor?.some(color))
            }
        }
        .frame(width: 240)
        field(
            "Folder (optional)", text: optional(Binding(get: { tab.directory }, set: { draft.tabs[index].directory = $0 })), error: issue(.tab(index), .directory),
            prompt: "api", note: "Where the tab's panes without a folder start, relative to the project folder.")
        repositoryFields(
            "Tab repository", note: "The tab's folder is a checkout.", repository: tab.repository, at: .tab(index), set: { draft.tabs[index].repository = $0 })
    }

    @ViewBuilder private func paneDetail(_ pane: ProjectPane, tab: Int, path: [Int]) -> some View {
        let at = ProjectDefinition.Place.node(tab: tab, path: path)
        Text("Pane").font(.headline)
        field("Title (optional)", text: optional(Binding(get: { pane.title }, set: { value in draft.updatePane(tab: tab, path: path) { $0.title = value } })), error: issue(at, .title), prompt: "API server")
        field(
            "Folder (optional)", text: optional(Binding(get: { pane.directory }, set: { value in draft.updatePane(tab: tab, path: path) { $0.directory = value } })),
            error: issue(at, .directory), prompt: draft.tabs[tab].directory ?? "api",
            note: "Relative to the project folder chosen at launch. Empty uses the tab's folder.")
        field(
            "Command (optional)", text: optional(Binding(get: { pane.command }, set: { value in draft.updatePane(tab: tab, path: path) { $0.command = value } })),
            error: issue(at, .command), prompt: "make dev", monospaced: true, note: "Typed into the shell after its first prompt.")
        repositoryFields(
            "Pane repository", note: "The pane's folder is a checkout.", repository: pane.repository, at: at,
            set: { value in draft.updatePane(tab: tab, path: path) { $0.repository = value } })
    }

    @ViewBuilder private func splitDetail(axis: SplitAxis, ratio: Double, tab: Int, path: [Int]) -> some View {
        Text("Split").font(.headline)
        Picker("Direction", selection: Binding(get: { axis }, set: { draft.updateSplit(tab: tab, path: path, axis: $0, ratio: ratio) })) {
            Text("Side by side").tag(SplitAxis.x)
            Text("Top and bottom").tag(SplitAxis.y)
        }
        .pickerStyle(.segmented).frame(width: 280)
        VStack(alignment: .leading, spacing: 3) {
            Text("First pane's share: \(Int((ratio * 100).rounded()))%").font(.caption).foregroundStyle(workspace.themeColor(.mutedForeground))
            Slider(value: Binding(get: { ratio }, set: { draft.updateSplit(tab: tab, path: path, axis: axis, ratio: ($0 * 100).rounded() / 100) }), in: 0.1...0.9)
                .frame(width: 280).accessibilityLabel("First pane's share")
        }
    }

    @ViewBuilder private func repositoryFields(
        _ title: String, note: String, repository: ProjectRepository?, at: ProjectDefinition.Place, set: @escaping (ProjectRepository?) -> Void
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(note, isOn: Binding(get: { repository != nil }, set: { set($0 ? ProjectRepository(url: "") : nil) }))
                if let repository {
                    field(
                        "URL", text: Binding(get: { repository.url }, set: { set(ProjectRepository(url: $0, branch: repository.branch)) }), error: issue(at, .repositoryURL),
                        prompt: "git@github.com:acme/api.git", monospaced: true)
                    field(
                        "Branch (optional)", text: optional(Binding(get: { repository.branch }, set: { set(ProjectRepository(url: repository.url, branch: $0)) })),
                        error: issue(at, .repositoryBranch), prompt: "The remote's default")
                    Text("Cloned by Set Up when its folder is missing, with the target's own git and credentials.")
                        .font(.caption).foregroundStyle(workspace.themeColor(.mutedForeground)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        } label: {
            Text(title)
        }
    }

    // MARK: JSON (FR-PL03)

    private var jsonEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScratchpadEditor(
                text: $jsonText, language: .json, font: editorFont, palette: workspace.effectiveTheme.terminal, issueLines: [], focusRequest: 0,
                commands: ScratchpadEditorCommands(validate: validateJSON, save: { save() }), accessibilityName: "Project JSON editor", contentNoun: "project",
                maximumBytes: ProjectJSON.maximumBytes
            )
            .frame(maxHeight: .infinity)
            if let jsonProblems {
                VStack(alignment: .leading, spacing: 4) {
                    if jsonProblems.isEmpty { Label("The project is valid.", systemImage: "checkmark.circle").font(.callout) }
                    ForEach(jsonProblems, id: \.self) { Label($0, systemImage: "xmark.octagon").font(.callout).fixedSize(horizontal: false, vertical: true) }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .onChange(of: jsonText) { jsonProblems = nil }
    }

    private var editorFont: NSFont {
        NSFont(name: workspace.appearance.fontName, size: CGFloat(workspace.appearance.fontSize))
            ?? .monospacedSystemFont(ofSize: CGFloat(workspace.appearance.fontSize), weight: .regular)
    }

    private func switchEditor(_ json: Bool) {
        guard json != showsJSON else { return }
        if json {
            jsonText = Self.json(draft); jsonProblems = nil; showsJSON = true
        } else if let parsed = parsedJSON() {
            draft = parsed; showsJSON = false
        }
    }

    /// The JSON as the draft's project, keeping its identity; nil after showing the problems.
    private func parsedJSON() -> ProjectDefinition? {
        switch ProjectJSON.parse(Data(jsonText.utf8)) {
        case .failure(let error): jsonProblems = error.problems; return nil
        case .success(var parsed):
            parsed.id = draft.id; parsed.revision = draft.revision; parsed.lastFolders = draft.lastFolders
            return parsed
        }
    }

    private func validateJSON() { if parsedJSON() != nil { jsonProblems = [] } }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message { Text(message).font(.caption).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("projects.result") }
            HStack {
                if stored != nil { Button("Delete…", role: .destructive) { confirmingDelete = true }.disabled(saving || model.loadFailed) }
                Spacer()
                if isDirty, stored != nil { Text("Unsaved changes").font(.caption).foregroundStyle(workspace.themeColor(.mutedForeground)) }
                Button(stored == nil ? "Add Project" : "Save") { save() }.keyboardShortcut("s", modifiers: .command)
                    .disabled(saving || model.loadFailed || (!showsJSON && !issues.isEmpty))
                Button("Launch…") { if let stored { model.onLaunch?(stored) } }.keyboardShortcut(.defaultAction)
                    .disabled(stored == nil || isDirty || model.onLaunch == nil).help(isDirty ? "Save the project before launching it" : "Choose where to run the project")
            }
        }
    }

    // MARK: Actions

    private var selectionIsPane: Bool {
        guard case .node(let tab, let path) = place, draft.tabs.indices.contains(tab), case .pane? = draft.tabs[tab].root[path] else { return false }
        return true
    }

    private var canRemove: Bool {
        switch place {
        case .project: false
        case .tab: draft.tabs.count > 1
        case .node(_, let path): !path.isEmpty
        }
    }

    private func canMoveTab(_ offset: Int) -> Bool {
        guard case .tab(let index) = place else { return false }
        return draft.tabs.indices.contains(index + offset)
    }

    private func split(_ axis: SplitAxis) {
        guard case .node(let tab, let path) = place, let added = draft.split(tab: tab, path: path, axis: axis) else { return }
        place = .node(tab: tab, path: added)
    }

    private func remove() {
        switch place {
        case .tab(let index): if let next = draft.remove(tab: index, path: []) { place = next }
        case .node(let tab, let path): if let next = draft.remove(tab: tab, path: path) { place = next }
        case .project: break
        }
    }

    private func moveTab(_ offset: Int) {
        guard case .tab(let index) = place else { return }
        place = .tab(draft.moveTab(index, by: offset))
    }

    /// `next`: `.some(nil)` for a new project. Asks before dropping unsaved changes unless `force`.
    private func select(_ next: UUID?, force: Bool = false) {
        guard force || !isDirty else { pendingChange = .select(next); return }
        selection = next
        load(next.flatMap { id in model.projects.first { $0.id == id } } ?? ProjectDefinition(name: "New Project"))
    }

    private func apply(_ change: PendingChange?) {
        switch change {
        case .select(let next)?: select(next, force: true)
        case .draft(let capture)?: takePendingDraft(capture, force: true)
        case nil: break
        }
    }

    private func load(_ project: ProjectDefinition, clean: Bool = true) {
        draft = project; baseline = clean ? project : nil; place = .project; message = nil; warnings = []; jsonProblems = nil
        if showsJSON { jsonText = Self.json(project) }
    }

    private func takePendingDraft(_ capture: ProjectCapture?, force: Bool = false) {
        guard let capture else { return }
        model.pendingDraft = nil
        guard force || !isDirty else { pendingChange = .draft(capture); return }
        selection = nil
        load(capture.project, clean: false)
        warnings = capture.warnings
        message = "Not saved yet. Review the project, then add it."
    }

    private func captureActiveWindow() {
        guard let id = workspace.snapshot.activeWindowID else { return }
        guard let capture = workspace.captureProject(windowID: id) else { message = "That window can't be captured."; return }
        model.pendingDraft = capture
    }

    /// The saved project, in the form Import JSON… reads; unsaved edits aren't included (FR-PL04).
    private func exportJSON() {
        guard let stored else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = ProjectListModel.exportFileName(stored)
        panel.message = isDirty ? "Exports the saved project; your unsaved changes aren't included." : "Exports “\(stored.name)” for Import JSON… on another Mac."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportJSON(stored).write(to: url, options: .atomic)
            message = "Exported to \(url.lastPathComponent)."
        } catch { message = "The project could not be written there. Check the folder's permissions and try again." }
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a project exported as JSON."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? OwnerOnlyFile.read(url, limit: ProjectJSON.maximumBytes) ?? nil else { message = "The file could not be read."; return }
        switch model.importJSON(data) {
        case .success(let project): model.pendingDraft = ProjectCapture(project: project, warnings: [])
        case .failure(let error): message = "The file isn't a valid project: " + error.problems.joined(separator: " ")
        }
    }

    /// `then` runs after a successful save of the project shown when it started.
    private func save(then: (() -> Void)? = nil) {
        var project = draft
        if showsJSON {
            guard let parsed = parsedJSON() else { return }
            project = parsed
        }
        saving = true
        let origin = selection
        Task {
            let result = await model.save(project)
            saving = false
            guard selection == origin else { return }
            switch result {
            case .success(let saved):
                selection = saved.id; load(saved)
                message = "Saved."
                then?()
            case .failure(let error):
                message = ProjectListModel.message(for: error)
                if case .invalid(let found) = error { jsonProblems = found.map { ProjectJSON.describe($0, in: project) } }
            }
        }
    }

    private func delete() {
        guard let stored else { return }
        Task {
            if let failure = await model.delete(stored) { message = ProjectListModel.message(for: failure); return }
            select(nil, force: true)
        }
    }

    // MARK: Fields

    private func issue(_ at: ProjectDefinition.Place, _ field: ProjectDefinition.Field) -> String? {
        issues.first { $0.place == at && $0.field == field }?.message
    }

    /// A text field over an optional value: empty text is nil.
    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func field(_ title: String, text: Binding<String>, error: String?, prompt: String, monospaced: Bool = false, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(workspace.themeColor(.mutedForeground))
            TextField(title, text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder).labelsHidden()
                .font(monospaced ? .system(size: 12, design: .monospaced) : .body)
                .accessibilityLabel(title).accessibilityValue(error.map { "\(text.wrappedValue). Error: \($0)" } ?? text.wrappedValue)
            if let note { Text(note).font(.caption).foregroundStyle(workspace.themeColor(.mutedForeground)).fixedSize(horizontal: false, vertical: true) }
            errorLabel(error)
        }
    }

    @ViewBuilder private func errorLabel(_ error: String?) -> some View {
        if let error {
            Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityHidden(true)
        }
    }
}
