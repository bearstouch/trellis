import AppKit
import SwiftUI
import TrellisCore

/// The floating palette (FR-CP01–FR-CP08). The field drives the keyboard; rows are buttons for the pointer and
/// VoiceOver. All state lives in the model, so closing restores the workspace exactly.
struct CommandPaletteView: View {
    @ObservedObject var model: AppWorkspaceModel
    static let rowHeight: CGFloat = 44
    static let headerHeight: CGFloat = 26

    var body: some View {
        let sections = model.commandPaletteSections
        let selected = model.commandPaletteSelectedMatch(in: sections)
        let count = sections.reduce(0) { $0 + $1.matches.count }
        GeometryReader { geometry in
            let top = min(96, geometry.size.height * 0.12)
            ZStack(alignment: .top) {
                Color.black.opacity(model.increaseContrast ? 0.3 : 0.18)
                    .contentShape(Rectangle())
                    .onTapGesture { model.closeCommandPalette() }
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    field(count: count)
                    Divider().overlay(model.separatorOverlay)
                    if sections.isEmpty {
                        emptyState
                    } else {
                        results(sections, selected: selected, maxHeight: max(Self.rowHeight * 2, geometry.size.height - top - 56 - 36 - 48))
                    }
                    Divider().overlay(model.separatorOverlay)
                    footer(selected)
                }
                .frame(width: min(640, max(280, geometry.size.width - 32)))
                .background(model.themeColor(.background))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(model.themeColor(.border), lineWidth: model.increaseContrast ? 1.5 : 0.5))
                .shadow(color: .black.opacity(0.28), radius: 32, y: 16)
                .padding(.top, top)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Command Palette")
                .accessibilityAddTraits(.isModal)
            }
        }
        .onChange(of: count) { _, value in
            NSAccessibility.post(
                element: NSApp as Any, notification: .announcementRequested,
                userInfo: [.announcement: value == 1 ? "1 result" : "\(value) results", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    private func field(count: Int) -> some View {
        HStack(spacing: 10) {
            if let scope = model.commandPaletteScope {
                Text("\(scope.chipTitle) ›")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(model.themeColor(.accent))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(model.sidebarSelectionBackground, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Scope \(scope.chipTitle)")
            } else {
                Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(model.themeColor(.mutedForeground)).accessibilityHidden(true)
            }
            CommandPaletteField(model: model)
            Text(count == 1 ? "1 result" : "\(count) results")
                .font(.system(size: 12)).foregroundStyle(model.themeColor(.mutedForeground)).monospacedDigit()
                .opacity(model.commandPaletteQuery.isEmpty && model.commandPaletteScope == nil ? 0 : 1)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 18).frame(height: 56)
    }

    private func results(_ sections: [CommandPaletteSection], selected: CommandPaletteMatch?, maxHeight: CGFloat) -> some View {
        let rows = sections.reduce(0) { $0 + $1.matches.count }
        let height = CGFloat(rows) * Self.rowHeight + CGFloat(sections.count) * Self.headerHeight + 12
        // The section whose first row is selected scrolls to its header, so the top of the list is always reachable.
        let anchor = { (id: String?) -> String? in
            guard let id else { return nil }
            return sections.first { $0.matches.first?.item.id == id }.map { "section:" + $0.id } ?? id
        }
        return ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: a lazy stack kept rows from the previous query and lost their scroll position. Results are
                // small, and a new query or scope starts a fresh list at the top.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        Text(section.title.uppercased())
                            .font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(model.themeColor(.mutedForeground))
                            .padding(.horizontal, 20).frame(height: Self.headerHeight, alignment: .bottomLeading)
                            .accessibilityAddTraits(.isHeader)
                            .id("section:" + section.id)
                        ForEach(section.matches, id: \.item.id) { match in
                            row(match, selected: match.item.id == selected?.item.id).id(match.item.id)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .id("\(model.commandPaletteScope?.rawValue ?? "all"):\(model.commandPaletteQuery)")
            .frame(height: min(height, min(maxHeight, 9 * Self.rowHeight + 3 * Self.headerHeight + 12)))
            .accessibilityLabel("Results")
            .onChange(of: selected?.item.id) { _, id in
                if let target = anchor(id) { withAnimation(nil) { proxy.scrollTo(target) } }
            }
        }
    }

    private func row(_ match: CommandPaletteMatch, selected: Bool) -> some View {
        let item = match.item
        let subtitle = match.matchedAlias.map { alias in item.subtitle.isEmpty ? "also “\(alias)”" : "\(item.subtitle) · also “\(alias)”" } ?? item.subtitle
        return Button {
            model.runCommandPaletteItem(item.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: Self.symbol(item))
                    .font(.system(size: 13)).frame(width: 26, height: 26)
                    .background(model.themeColor(.surface), in: RoundedRectangle(cornerRadius: 6))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.highlighted(item.title, match.titlePositions, accent: model.themeColor(.accent)))
                        .font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(model.themeColor(.mutedForeground)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let shortcut = item.shortcut { keycaps(shortcut) }
                if selected {
                    Text("↩").font(.system(size: 11, weight: .semibold)).foregroundStyle(model.accentForeground)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(model.themeColor(.accent), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 12).frame(height: Self.rowHeight)
            .background(selected ? model.sidebarSelectionBackground : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            // A scope row reads "Go to Tab…, 3 tabs in 2 windows", not "… windows action".
            [item.title, item.isScope ? subtitle : item.kind == .action ? "\(item.subtitle) action" : "\(item.kind.noun), \(subtitle)", item.shortcut?.description]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        )
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func keycaps(_ chord: KeyChord) -> some View {
        let glyphs = chord.description
        let modifiers = glyphs.prefix { "⌃⌥⇧⌘".contains($0) }
        let caps = modifiers.map(String.init) + [String(glyphs.dropFirst(modifiers.count))]
        return HStack(spacing: 3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap).font(.system(size: 11)).foregroundStyle(model.themeColor(.foreground))
                    .padding(.horizontal, 5).padding(.vertical, 2).frame(minWidth: 20)
                    .background(model.themeColor(.surface), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(model.themeColor(.border), lineWidth: 0.5))
            }
        }
        .accessibilityHidden(true)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(model.themeColor(.mutedForeground)).accessibilityHidden(true)
            Text("No matches for “\(model.commandPaletteQuery)”").font(.system(size: 15, weight: .semibold))
            Text(
                model.commandPaletteScope == nil
                    ? "Search covers actions, windows, tabs, panes, saved hosts, tasks and themes. Try fewer letters."
                    : "Press ⌫ in the empty field to search everything."
            )
            .font(.system(size: 13)).foregroundStyle(model.themeColor(.mutedForeground)).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .padding(.vertical, 40).padding(.horizontal, 32).frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func footer(_ selected: CommandPaletteMatch?) -> some View {
        var hints = ["↑↓ Navigate"]
        if let selected {
            switch selected.item.target {
            case .scope: hints.append("↩ Open")
            case .host: hints += ["↩ Connect", "⌘↩ New Window", "⌥↩ Split"]
            case .remoteWorkspace: hints.append("↩ Open")
            case .project: hints.append("↩ Launch")
            default: hints.append("↩ Run")
            }
        }
        if model.commandPaletteScope != nil { hints.append("⌫ Back") }
        hints.append("esc Close")
        return HStack(spacing: 16) {
            Text(selected.map { Self.verb($0.item) } ?? "Trellis").font(.system(size: 11.5, weight: .semibold))
            Spacer()
            ForEach(hints, id: \.self) { Text($0) }
        }
        .font(.system(size: 11.5)).foregroundStyle(model.themeColor(.mutedForeground))
        .padding(.horizontal, 16).frame(height: 36)
        .background(model.themeColor(.surface))
        .accessibilityHidden(true)
    }

    static func verb(_ item: CommandPaletteItem) -> String {
        switch item.target {
        case .action, .settings: item.title
        case .scope(let scope): scope.title
        case .window: "Go to Window"
        case .tab: "Go to Tab"
        case .pane: "Go to Pane"
        case .host: "Connect"
        case .remoteWorkspace: "Open Remote Workspace"
        case .project: "Launch Project"
        case .task: "Run Task"
        case .theme: "Use Theme"
        case .agent: "Launch Agent"
        }
    }

    static func symbol(_ item: CommandPaletteItem) -> String {
        switch item.target {
        case .action: "command"
        case .settings: "gearshape"
        case .scope: "arrow.forward.square"
        case .window: "macwindow"
        case .tab: "menubar.rectangle"
        case .pane: "rectangle.split.2x1"
        case .host: "server.rack"
        case .remoteWorkspace: "rectangle.connected.to.line.below"
        case .project: "folder.badge.gearshape"
        case .task: "play"
        case .theme: "paintpalette"
        case .agent: "sparkles"
        }
    }

    /// Matched letters are bold and underlined as well as tinted, never color alone.
    static func highlighted(_ title: String, _ positions: [Int], accent: Color) -> AttributedString {
        let marked = Set(positions)
        var result = AttributedString()
        for (index, character) in title.enumerated() {
            var piece = AttributedString(String(character))
            if marked.contains(index) {
                piece.font = .system(size: 14, weight: .bold)
                piece.underlineStyle = .single
                piece.foregroundColor = accent
            }
            result += piece
        }
        return result
    }
}

/// Shows the palette over the workspace, animated unless Reduce Motion is on.
struct CommandPaletteHost: ViewModifier {
    @ObservedObject var model: AppWorkspaceModel
    func body(content: Content) -> some View {
        content
            .overlay {
                if model.commandPaletteVisible {
                    CommandPaletteView(model: model).transition(model.reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
            .animation(model.reduceMotion ? nil : .easeOut(duration: 0.12), value: model.commandPaletteVisible)
    }
}

/// An AppKit field, so arrows, Return, Tab, ⌫ and Esc reach the palette before the field editor handles them.
private struct CommandPaletteField: NSViewRepresentable {
    @ObservedObject var model: AppWorkspaceModel

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.placeholderString = "Search actions, windows, tabs, hosts…"
        field.setAccessibilityLabel("Search commands")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.onResignKey = { [weak model] in model?.closeCommandPalette() }
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        if field.stringValue != model.commandPaletteQuery { field.stringValue = model.commandPaletteQuery }
        field.placeholderString = model.commandPaletteScope.map { "Search \($0.chipTitle.lowercased())…" } ?? "Search actions, windows, tabs, hosts…"
        field.requestFocus(model.commandPaletteFocusRequest)
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: AppWorkspaceModel
        init(_ model: AppWorkspaceModel) { self.model = model }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.setCommandPaletteQuery(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): model.moveCommandPaletteSelection(by: -1)
            case #selector(NSResponder.moveDown(_:)): model.moveCommandPaletteSelection(by: 1)
            case #selector(NSResponder.insertNewline(_:)):
                model.runCommandPaletteItem(modifier: NSApp.currentEvent?.modifierFlags.contains(.command) == true ? .command : .none)
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): model.runCommandPaletteItem(modifier: .option)
            case #selector(NSResponder.insertTab(_:)):
                if case .scope(let scope)? = model.commandPaletteSelectedMatch(in: model.commandPaletteSections)?.item.target {
                    model.enterCommandPaletteScope(scope)
                }
            case #selector(NSResponder.insertBacktab(_:)): break
            case #selector(NSResponder.cancelOperation(_:)): model.closeCommandPalette()
            case #selector(NSResponder.deleteBackward(_:)): return textView.string.isEmpty && model.leaveCommandPaletteScope()
            // ⌘⌫ clears the whole field, not only the text before the caret; still one undoable edit.
            case #selector(NSResponder.deleteToBeginningOfLine(_:)), #selector(NSResponder.deleteToBeginningOfParagraph(_:)):
                textView.selectAll(nil)
                textView.deleteBackward(nil)
            // ⌘Return has no text binding of its own; it arrives as noop.
            case Selector(("noop:")):
                guard let event = NSApp.currentEvent, event.type == .keyDown, [36, 76].contains(event.keyCode), event.modifierFlags.contains(.command) else { return false }
                model.runCommandPaletteItem(modifier: .command)
            default: return false
            }
            return true
        }
    }

    /// Focus requests are events, fulfilled once the field is in a window; losing key status closes the palette.
    final class Field: NSTextField {
        var onResignKey: (() -> Void)?
        private var request: Int?
        private var pendingFocus = false
        private var observer: NSObjectProtocol?

        func requestFocus(_ token: Int) {
            guard request != token else { return }
            request = token
            pendingFocus = true
            scheduleFocus()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Leaving the window (the palette closed) also removes the observer.
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = window.map { window in
                NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onResignKey?() }
                }
            }
            scheduleFocus()
        }

        private func scheduleFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let self, pendingFocus, let window, !isHiddenOrHasHiddenAncestor else { return }
                if window.makeFirstResponder(self) { pendingFocus = false }
            }
        }
    }
}
