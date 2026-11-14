import AppKit
import SwiftUI
import TrellisCore

/// An editor tab's content (FR-ED01–FR-ED06): a header with the file and its actions, a banner when the file changed,
/// and the editor itself. Colors and font follow the theme (FR-ED11). Mounted while hidden, so undo survives switching tabs.
struct EditorTabView: View {
    @ObservedObject var model: AppWorkspaceModel
    let tab: EditorTab
    let shown: Bool
    /// The cursor's "Ln, Col", updated on every key and cursor move straight on its AppKit button: as SwiftUI state, each
    /// update laid the whole window out again (most of a key's cost once typing stopped publishing).
    @State private var cursor = EditorCursorReadout()
    @State private var goToLineShown = false
    @State private var goToLineText = ""

    private var muted: Color { model.themeColor(.mutedForeground) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(model.separatorOverlay)
            if let banner = tab.banner { bannerView(banner) }
            ZStack {
                ScratchpadEditor(
                    text: Binding(get: { model.editorTab(tab.id)?.text ?? "" }, set: { model.updateEditorText(tab.id, $0) }), language: tab.language,
                    font: editorFont, palette: model.effectiveTheme.terminal, issueLines: [], focusRequest: model.editorFocusRequest,
                    commands: ScratchpadEditorCommands(
                        saveFile: { Task { await model.saveEditor(tab.id) } }, goToLine: { beginGoToLine() },
                        togglePreview: tab.isMarkdown ? { model.toggleEditorPreview(tab.id) } : nil),
                    accessibilityName: L("Editor, %@", tab.fileName), contentNoun: L("file"), maximumBytes: EditorDocument.maximumBytes,
                    highlightsCurrentLine: true, jump: tab.jump, onJumped: { model.clearEditorJump(tab.id) },
                    onCursor: { [cursor] in cursor.update(line: $0, column: $1) }, highlightLimit: EditorDocument.maximumHighlightedBytes, acceptsFocus: shown && !tab.showsPreview
                )
                // The source stays mounted under the preview, so its undo, cursor and scroll survive (FR-ED12).
                .opacity(tab.showsPreview ? 0 : 1).allowsHitTesting(!tab.showsPreview).accessibilityHidden(tab.showsPreview)
                if tab.isMarkdown, tab.showsPreview { MarkdownPreviewView(model: model, tab: tab, visible: shown) }
            }
        }
        .background(Color(nsColor: NSColor(rgb: model.effectiveTheme.terminal.background)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Editor tab, %@", tab.fileName))
        // Back from another app, the file may have changed (FR-ED06).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if shown { model.checkEditorOnDisk(tab.id) } }
        // A banner is announced, as it appears without focus moving to it (FR-ED10).
        .onChange(of: tab.banner) { _, banner in
            guard shown, let banner else { return }
            NSAccessibility.post(
                element: NSApp as Any, notification: .announcementRequested,
                userInfo: [.announcement: bannerText(banner), .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    private func bannerText(_ banner: EditorTab.Banner) -> String {
        switch banner {
        case .changedOnDisk: L("%@ changed on disk while you had unsaved edits.", tab.fileName)
        case .deleted: L("%@ was deleted. Save creates it again.", tab.fileName)
        case .saveFailed(let message): L("%1$@ wasn't saved. %2$@", tab.fileName, message)
        }
    }

    private var editorFont: NSFont {
        NSFont(name: model.appearance.fontName, size: CGFloat(model.appearance.fontSize)) ?? .monospacedSystemFont(ofSize: CGFloat(model.appearance.fontSize), weight: .regular)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text").foregroundStyle(muted).accessibilityHidden(true)
            pathLabel
            if tab.isDirty {
                Text(L("Unsaved")).font(.caption).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(model.themeColor(.border).opacity(0.35)))
            }
            Spacer(minLength: 8)
            Text(tab.language.displayName).font(.caption).foregroundStyle(muted)
                .padding(.horizontal, 7).padding(.vertical, 2).overlay(RoundedRectangle(cornerRadius: 4).stroke(model.themeColor(.border).opacity(0.6)))
                .accessibilityLabel(L("Language: %@", tab.language.displayName))
            if tab.isMarkdown { previewToggle }
            if !tab.showsPreview {
                EditorCursorButton(readout: cursor, color: NSColor(muted)) { beginGoToLine() }
                    .frame(width: EditorCursorButton.width, alignment: .trailing)
                    .popover(isPresented: $goToLineShown, arrowEdge: .bottom) { goToLinePopover }
            }
            openWithMenu
            Button {
                model.revealFiles([URL(fileURLWithPath: tab.document.path)])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless).help(L("Reveal in Finder")).accessibilityLabel(L("Reveal %@ in Finder", tab.fileName))
            Button(L("Save")) { Task { await model.saveEditor(tab.id) } }
                .controlSize(.small)
                .disabled(!shown || (!tab.isDirty && tab.banner != .deleted)).help(L("Save %@ (⌘S)", tab.fileName))
        }
        .padding(.horizontal, 14).padding(.vertical, 7).background(model.chromeFill(.surface))
    }

    private var pathLabel: some View {
        let parts = tab.displayPath.split(separator: "/").map(String.init)
        return HStack(spacing: 4) {
            ForEach(Array(parts.dropLast().enumerated()), id: \.offset) { _, part in
                Text(part).foregroundStyle(muted)
                Text("›").foregroundStyle(muted.opacity(0.7)).accessibilityHidden(true)
            }
            Text(parts.last ?? tab.fileName).fontWeight(.semibold)
        }
        .font(.system(size: 12)).lineLimit(1).truncationMode(.head)
        .help(tab.document.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.displayPath)
        .accessibilityValue(tab.isDirty ? L("unsaved") : "")
    }

    private var openWithMenu: some View {
        Menu {
            ForEach(model.files.editors.filter { $0 != .trellisEditor && $0 != .newTab }) { app in
                Button(app.name) { Task { await model.openFile(FileEntry(path: tab.document.path, isDirectory: false), in: app, remember: false) } }
            }
        } label: {
            Label(L("Open With"), systemImage: "arrow.up.forward.app")
        }
        .menuStyle(.borderlessButton).fixedSize().controlSize(.small).help(L("Open %@ in another app", tab.fileName))
        .onAppear { if model.files.editors.isEmpty { model.loadEditorChoices() } }
    }

    /// Preview / Edit for a Markdown tab (FR-ED12); ⇧⌘V also works while the source has the keyboard.
    private var previewToggle: some View {
        Button {
            model.toggleEditorPreview(tab.id)
        } label: {
            Label(tab.showsPreview ? L("Edit") : L("Preview"), systemImage: tab.showsPreview ? "pencil" : "eye")
        }
        .controlSize(.small).keyboardShortcut("v", modifiers: [.command, .shift]).disabled(!shown)
        .help(tab.showsPreview ? L("Edit the source (⇧⌘V)") : L("Preview the Markdown (⇧⌘V)"))
        .accessibilityValue(tab.showsPreview ? L("showing the preview") : L("showing the source"))
    }

    // MARK: Go to line

    private func beginGoToLine() {
        goToLineText = ""
        goToLineShown = true
    }

    private var goToLinePopover: some View {
        HStack(spacing: 8) {
            Text(L("Go to line:"))
            TextField(L("Line"), text: $goToLineText).frame(width: 80).textFieldStyle(.roundedBorder)
                .onSubmit {
                    if let number = Int(goToLineText.trimmingCharacters(in: .whitespaces)), number > 0 { model.goToLine(tab.id, line: number) }
                    goToLineShown = false
                    model.focusEditor()
                }
        }.padding(12)
    }

    // MARK: Banner (FR-ED04, FR-ED06)

    private func bannerView(_ banner: EditorTab.Banner) -> some View {
        let tint = banner == .deleted || banner == .changedOnDisk ? model.themeColor(.warning) : model.themeColor(.error)
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tint).accessibilityHidden(true)
            switch banner {
            case .changedOnDisk:
                Text(bannerText(banner))
                Spacer(minLength: 8)
                Button(L("Reload from Disk")) { Task { await model.reloadEditor(tab.id) } }.controlSize(.small)
                Button(L("Keep Mine")) { model.keepEditorChanges(tab.id) }.controlSize(.small)
            case .deleted:
                Text(bannerText(banner))
                Spacer(minLength: 8)
            case .saveFailed:
                Text(bannerText(banner))
                Spacer(minLength: 8)
                Button(L("Try Again")) { Task { await model.saveEditor(tab.id) } }.controlSize(.small)
            }
        }
        .font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 7)
        .background(tint.opacity(0.14))
        .overlay(alignment: .bottom) { tint.opacity(0.4).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// The editor's cursor position, shown on its button without SwiftUI: the text view reports it on every key.
@MainActor final class EditorCursorReadout {
    private(set) var line = 1
    private(set) var column = 1
    weak var button: NSButton? { didSet { show() } }

    func update(line: Int, column: Int) {
        guard line != self.line || column != self.column else { return }
        (self.line, self.column) = (line, column)
        show()
    }

    var title: String { L("Ln %1$d, Col %2$d", line, column) }
    private func show() { button?.title = title }
}

/// "Ln, Col" as a borderless AppKit button that opens Go to Line. Its width is fixed, so a new position never changes the
/// header's layout.
struct EditorCursorButton: NSViewRepresentable {
    let readout: EditorCursorReadout
    let color: NSColor
    let action: () -> Void

    static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
    /// Wide enough for a five-digit line and a four-digit column in the current language.
    static var width: CGFloat { ceil((L("Ln %1$d, Col %2$d", 88_888, 8_888) as NSString).size(withAttributes: [.font: font]).width) + 8 }
    /// One line of the caption font.
    static var height: CGFloat { ceil(("Ln 0" as NSString).size(withAttributes: [.font: font]).height) + 2 }

    final class Button: NSButton {
        var onPress: () -> Void = {}
        // A fixed size: a new title must not ask the window to lay out again. Retitling invalidates the intrinsic size,
        // which SwiftUI's host passes up as a layout of the whole window (it is one hosting view), so that is ignored too.
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: EditorCursorButton.height) }
        override func invalidateIntrinsicContentSize() {}
        @objc func press() { onPress() }
    }

    func makeNSView(context: Context) -> Button {
        let button = Button(title: readout.title, target: nil, action: nil)
        button.target = button
        button.action = #selector(Button.press)
        button.isBordered = false
        button.font = Self.font
        button.alignment = .right
        button.lineBreakMode = .byClipping
        button.toolTip = L("Go to Line (⌘L)")
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        readout.button = button
        update(button)
        return button
    }

    func updateNSView(_ button: Button, context: Context) { update(button) }

    /// Its exact size, so SwiftUI never stretches it: without one, it took a share of the editor's height.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Button, context: Context) -> CGSize? { CGSize(width: Self.width, height: Self.height) }

    private func update(_ button: Button) {
        button.onPress = action
        button.contentTintColor = color
        if button.title != readout.title { button.title = readout.title }
    }
}
