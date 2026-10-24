import AppKit
import SwiftUI
import TrellisTerminal

struct TerminalSearchBar: View {
    @ObservedObject var terminal: NativeTerminal

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                PaneSearchField(terminal: terminal)
                    .frame(minHeight: 22, maxHeight: 22)
                    .onChange(of: terminal.searchQuery) { _, _ in terminal.findInPane(reset: true) }
                Button {
                    terminal.onFocused?(); terminal.findInPane(forward: false)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .accessibilityLabel("Previous Match").help("Previous Match (⇧⌘G)")
                Button {
                    terminal.onFocused?(); terminal.findInPane()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .accessibilityLabel("Next Match").help("Next Match (⌘G)")
                Button {
                    terminal.closeSearch()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Close Search").help("Close Search (Esc)")
            }
            Text(terminal.searchStatus).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                .frame(height: 24, alignment: .leading)
        }.buttonStyle(.plain).padding(7).background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SearchableTerminalSurface: View {
    @ObservedObject var terminal: NativeTerminal
    let isFocused: Bool
    let background: Color
    var body: some View {
        VStack(spacing: 0) {
            // Keyed by terminal: a reused surface (another tab of the same shape) must not keep the previous
            // pane's field, whose coordinator would type into, search and close that pane instead.
            if terminal.searchVisible { TerminalSearchBar(terminal: terminal).id(ObjectIdentifier(terminal)) }
            // Opening/selecting a pane with an active find field must not let
            // the native terminal host steal that field's first responder.
            NativeTerminalSurface(terminal: terminal, isFocused: isFocused && !terminal.searchVisible)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .background(background)
        }
    }
}

/// A focus request is an event, rather than a Boolean that can remain true after
/// AppKit moves first responder back to a terminal. Fulfill it after attachment.
private struct PaneSearchField: NSViewRepresentable {
    @ObservedObject var terminal: NativeTerminal
    func makeCoordinator() -> Coordinator { Coordinator(terminal) }
    func makeNSView(context: Context) -> SearchField {
        let field = SearchField()
        field.placeholderString = "Find in this pane"
        field.setAccessibilityLabel("Find in this pane")
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.onFocused = { [weak terminal] in terminal?.onFocused?() }
        return field
    }
    func updateNSView(_ field: SearchField, context: Context) {
        if field.stringValue != terminal.searchQuery { field.stringValue = terminal.searchQuery }
        field.requestFocus(terminal.searchFocusRequest)
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let terminal: NativeTerminal
        init(_ terminal: NativeTerminal) { self.terminal = terminal }
        func controlTextDidBeginEditing(_ notification: Notification) { terminal.onFocused?() }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            terminal.searchQuery = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                terminal.findInPane(); return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                terminal.closeSearch(); return true
            }
            return false
        }
    }
    final class SearchField: NSTextField {
        var onFocused: (() -> Void)?
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { onFocused?() }
            return accepted
        }
        private var request: UUID?
        private var pendingFocus = false
        func requestFocus(_ token: UUID) {
            guard request != token else { return }
            request = token
            pendingFocus = true
            scheduleFocus()
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleFocus() }
        private func scheduleFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingFocus, let window = self.window,
                    !self.isHiddenOrHasHiddenAncestor
                else { return }
                if window.makeFirstResponder(self) { self.pendingFocus = false }
            }
        }
    }
}
