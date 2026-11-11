import AppKit
import SwiftUI
import TrellisCore

/// The sidebar's Changes view (FR-GC01–FR-GC08): the focused pane's uncommitted changes as a tree with lines added and
/// removed, a filter, per-file Stage and Unstage, and Return to review a file in the space's Review tab. State is in
/// words and letters, never color alone.
struct ChangesSidebarView: View {
    @ObservedObject var model: AppWorkspaceModel
    let paneID: UUID
    @FocusState private var filterFocused: Bool
    @FocusState private var listFocused: Bool
    /// A `cd` moves the view to another repository.
    private var refreshKey: [String?] { [paneID.uuidString, model.paneDirectory(paneID)] }

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(model: model, view: .changes) {
                Button {
                    model.collapseAllGitChanges()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").rotationEffect(.degrees(90))
                }
                .help(L("Collapse all folders")).accessibilityLabel(L("Collapse All Folders"))
                Button {
                    Task { await model.refreshGitChanges(paneID: paneID) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L("Read git status again")).accessibilityLabel(L("Reload Changes"))
            }
            Divider().overlay(model.separatorOverlay)
            content
        }
        .background(model.chromeFill(.surface))
        .accessibilityElement(children: .contain).accessibilityLabel(L("Changes"))
        .animation(.easeOut(duration: 0.15), value: model.gitChanges.status)
        .task(id: refreshKey) { await model.refreshGitChanges(paneID: paneID) }
        .onChange(of: model.gitChangesFocusRequest, initial: true) { DispatchQueue.main.async { filterFocused = true } }
        .onChange(of: model.gitChanges.status) { _, status in
            if let status { AccessibilityNotification.Announcement(status).post() }
        }
    }

    @ViewBuilder private var content: some View {
        let muted = model.themeColor(.mutedForeground)
        switch model.gitChanges.load {
        case .loaded(let list):
            summary(list)
            filterField
            Divider().overlay(model.separatorOverlay)
            tree(list)
            if let status = model.gitChanges.status {
                Text(status).font(.caption).lineLimit(2).padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(model.themeColor(.background)))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(model.themeColor(.border)))
                    .padding(.horizontal, 12).padding(.bottom, 6).transition(.opacity)
            }
            Divider().overlay(model.separatorOverlay)
            Text(L("↩ Review · ⌥↩ Open in %@ · ⇧⌘C Copy Path", model.files.editor.name))
                .font(.caption).foregroundStyle(muted).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
        case .noRepository(let folder):
            message(L("No repository"), L("%@ isn't inside a git repository. Changes follows the focused pane.", AppWorkspaceModel.abbreviatingHome(folder)))
        case .failed:
            message(L("Couldn't read git status"), L("Git isn't installed, or it took too long. Reload to try again."))
        case .idle:
            message(L("No folder"), L("The focused pane has no folder on this Mac yet. Its shell reports one after its first prompt."))
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(model.themeColor(.mutedForeground)).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Branch and totals (FR-GC02)

    private func summary(_ list: GitChangeList) -> some View {
        let muted = model.themeColor(.mutedForeground)
        let count = list.files.count
        let files = list.truncated ? L("first %@ files", count.formatted()) : count == 1 ? L("1 file") : L("%@ files", count.formatted())
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(muted).accessibilityHidden(true)
                Text(list.branch ?? list.commit.map { "(\($0))" } ?? L("(no commit)")).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if list.ahead > 0 || list.behind > 0 {
                    Text("↑\(list.ahead) ↓\(list.behind)").font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
                        .help(L("%1$d ahead of and %2$d behind the upstream", list.ahead, list.behind))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(list.branch.map { L("Branch %@", $0) } ?? list.commit.map { L("Detached at %@", $0) } ?? L("No commits yet"))
            .accessibilityValue(list.ahead > 0 || list.behind > 0 ? L("%1$d ahead, %2$d behind", list.ahead, list.behind) : "")
            HStack(spacing: 6) {
                Text(L("Uncommitted")).font(.system(size: 12, weight: .medium))
                LineCounts(model: model, added: list.added, removed: list.removed)
                Spacer(minLength: 4)
                Text(files).font(.caption).foregroundStyle(muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L("Uncommitted, %1$@, %2$d lines added, %3$d removed", files, list.added, list.removed))
        }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
    }

    private var filterField: some View {
        TextField(L("Filter changed files"), text: Binding(get: { model.gitChanges.filter }, set: { model.setGitChangesFilter($0) }))
            .textFieldStyle(.roundedBorder).focused($filterFocused).accessibilityLabel(L("Filter changed files"))
            .onKeyPress(phases: .down) { handleKey($0) }
            .padding(.horizontal, 12).padding(.bottom, 8)
    }

    // MARK: Tree (FR-GC02, FR-GC04)

    private func tree(_ list: GitChangeList) -> some View {
        let rows = model.gitChanges.rows
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if list.files.isEmpty {
                        Text(list.hasCommits ? L("Nothing to commit. The working tree matches HEAD.") : L("Nothing to commit. The working tree matches an empty repository."))
                            .font(.callout).foregroundStyle(model.themeColor(.mutedForeground)).padding(8).fixedSize(horizontal: false, vertical: true)
                    } else if rows.isEmpty {
                        Text(L("No changed file matches “%@”.", model.gitChanges.filter)).font(.callout).foregroundStyle(model.themeColor(.mutedForeground)).padding(8)
                    }
                    ForEach(rows) { row in ChangeRow(model: model, root: list.root, row: row) }
                }.padding(.horizontal, 6).padding(.vertical, 4)
            }
            .focusable().focused($listFocused).focusEffectDisabled()
            .onKeyPress(phases: .down) { handleKey($0) }
            .onChange(of: model.gitChanges.selection) { _, path in if let path { proxy.scrollTo("f:" + path) } }
            .accessibilityLabel(L("Changed files"))
        }
    }

    // MARK: Keyboard (FR-GC04, FR-GC05, FR-GC07)

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let file = model.gitChanges.selectedFile
        let root = model.gitChanges.list?.root
        switch press.key {
        case .downArrow: model.moveGitChangesSelection(by: 1)
        case .upArrow: model.moveGitChangesSelection(by: -1)
        case .return:
            guard let file, let root else { return .ignored }
            if press.modifiers.contains(.option) {
                Task { await model.openGitChange(root, file) }
            } else {
                Task { await model.reviewGitChange(file.path) }
            }
        case .escape:
            guard !model.gitChanges.filter.isEmpty else { return .ignored }
            model.setGitChangesFilter("")
        case .rightArrow, .leftArrow:
            // Folders fold from the row; the field's arrows move its cursor.
            return .ignored
        default:
            guard ["c", "ç"].contains(press.characters.lowercased()), press.modifiers == [.command, .shift] || press.modifiers == [.command, .shift, .option],
                let file, let root
            else { return .ignored }
            model.copyGitChangePath(root, file, relative: press.modifiers.contains(.option))
        }
        return .handled
    }
}

/// "+12 −3", the zeros dimmed but readable; the numbers are in the row's spoken value.
struct LineCounts: View {
    @ObservedObject var model: AppWorkspaceModel
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(Self.short(added))").foregroundStyle(added > 0 ? model.themeColor(.success) : model.themeColor(.mutedForeground))
            Text("−\(Self.short(removed))").foregroundStyle(removed > 0 ? model.themeColor(.error) : model.themeColor(.mutedForeground))
        }.font(.system(size: 11, design: .monospaced)).fixedSize().accessibilityHidden(true)
    }

    /// 1.2k past a thousand, so wide numbers fit the row.
    static func short(_ value: Int) -> String {
        value < 1000 ? "\(value)" : String(format: "%.1fk", Double(value) / 1000).replacingOccurrences(of: ".0k", with: "k")
    }
}

/// A file's status letter in a box, with its word as the tooltip.
struct ChangeStatusLetter: View {
    @ObservedObject var model: AppWorkspaceModel
    let kind: GitChangedFile.Kind

    var body: some View {
        let tint = Self.tint(kind, model)
        Text(kind.letter).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
            .frame(width: 16, height: 16).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.6), lineWidth: 1))
            .help(kind.word).accessibilityHidden(true)
    }

    static func tint(_ kind: GitChangedFile.Kind, _ model: AppWorkspaceModel) -> Color {
        switch kind {
        case .modified, .conflicted: model.themeColor(.warning)
        case .added: model.themeColor(.success)
        case .deleted: model.themeColor(.error)
        case .untracked: model.themeColor(.mutedForeground)
        }
    }
}

/// One folder or file line: disclosure or file icon, name, line counts, staged mark and status letter; Stage or Unstage on
/// hover or selection.
private struct ChangeRow: View {
    @ObservedObject var model: AppWorkspaceModel
    let root: String
    let row: GitChangeRow
    @State private var hovering = false

    var body: some View {
        if let file = row.file { fileRow(file) } else { folderRow }
    }

    private var folderRow: some View {
        let muted = model.themeColor(.mutedForeground)
        return HStack(spacing: 6) {
            Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(muted).frame(width: 10)
                .accessibilityHidden(true)
            Text(row.name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle).foregroundStyle(model.themeColor(.foreground))
            Spacer(minLength: 4)
            LineCounts(model: model, added: row.added, removed: row.removed).padding(.trailing, 22)
        }
        .padding(.leading, CGFloat(row.depth) * 14 + 6).padding(.trailing, 6).frame(minHeight: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? model.themeColor(.foreground).opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .id(row.id)
        .onHover { hovering = $0 }
        .onTapGesture { model.toggleGitChangesFolder(row.path) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.name)
        .accessibilityValue(row.isExpanded ? L("folder, expanded, %1$d lines added, %2$d removed", row.added, row.removed) : L("folder, collapsed, %1$d lines added, %2$d removed", row.added, row.removed))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.toggleGitChangesFolder(row.path) }
    }

    private func fileRow(_ file: GitChangedFile) -> some View {
        let selected = model.gitChanges.selection == file.path
        let busy = model.gitChanges.staging.contains(file.path)
        let muted = model.themeColor(.mutedForeground)
        return HStack(spacing: 6) {
            Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(selected ? model.themeColor(.foreground) : muted).frame(width: 14).accessibilityHidden(true)
            Text(file.name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                .strikethrough(file.kind == .deleted)
                .foregroundStyle(file.kind == .deleted ? muted : model.themeColor(.foreground))
            Spacer(minLength: 4)
            if hovering || selected || busy {
                Button {
                    Task { await model.toggleGitChangeStaged(file.path) }
                } label: {
                    if busy { ProgressView().controlSize(.mini) } else { Text(file.staging == .full ? L("Unstage") : L("Stage")).font(.system(size: 10.5, weight: .medium)) }
                }
                .buttonStyle(.bordered).controlSize(.mini).disabled(busy)
                .help(file.staging == .full ? L("Unstage %@", file.name) : L("Stage all of %@", file.name))
                .accessibilityLabel(file.staging == .full ? L("Unstage %@", file.name) : L("Stage %@", file.name))
            }
            if file.binary {
                Text(L("binary")).font(.system(size: 10.5)).foregroundStyle(muted).accessibilityHidden(true)
            } else {
                LineCounts(model: model, added: file.added ?? 0, removed: file.removed ?? 0)
            }
            if let staged = file.staging.word {
                // A filled dot for staged, a half one for partly; the word is the tooltip and the spoken value.
                Image(systemName: file.staging == .full ? "circle.fill" : "circle.lefthalf.filled").font(.system(size: 7))
                    .foregroundStyle(model.themeColor(.accent)).help(staged).accessibilityHidden(true)
            }
            ChangeStatusLetter(model: model, kind: file.kind)
        }
        .padding(.leading, CGFloat(row.depth) * 14 + 6).padding(.trailing, 6).frame(minHeight: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? model.sidebarSelectionBackground : hovering ? model.themeColor(.foreground).opacity(0.05) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? model.themeColor(.accent).opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .id(row.id)
        .onHover { hovering = $0 }
        .onTapGesture { Task { await model.reviewGitChange(file.path) } }
        .contextMenu { menu(file) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(file.name)
        .accessibilityValue(spoken(file))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { Task { await model.reviewGitChange(file.path) } }
        .accessibilityAction(named: file.staging == .full ? L("Unstage") : L("Stage")) { Task { await model.toggleGitChangeStaged(file.path) } }
        .accessibilityAction(named: L("Copy Path")) { model.copyGitChangePath(root, file) }
    }

    private func spoken(_ file: GitChangedFile) -> String {
        var parts = [file.kind.word]
        if let staged = file.staging.word { parts.append(staged) }
        parts.append(file.binary ? L("binary") : L("%1$d lines added, %2$d removed", file.added ?? 0, file.removed ?? 0))
        let folder = (file.path as NSString).deletingLastPathComponent
        if !folder.isEmpty { parts.append(L("in %@", folder)) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private func menu(_ file: GitChangedFile) -> some View {
        Button(L("Review Changes")) { Task { await model.reviewGitChange(file.path) } }
        Button(file.staging == .full ? L("Unstage") : L("Stage")) { Task { await model.toggleGitChangeStaged(file.path) } }
        Divider()
        Button(L("Open in %@", model.files.editor.name)) { Task { await model.openGitChange(root, file) } }
        Button(L("Reveal in Finder")) { model.revealFiles([URL(fileURLWithPath: root + "/" + file.path)]) }.disabled(file.kind == .deleted)
        Divider()
        Button(L("Copy Path")) { model.copyGitChangePath(root, file) }
        Button(L("Copy Relative Path")) { model.copyGitChangePath(root, file, relative: true) }
    }
}
