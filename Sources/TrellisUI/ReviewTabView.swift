import AppKit
import SwiftUI
import TrellisCore

/// A space's Review tab (FR-GC05): one file's unified diff with old and new line numbers, `+` and `−` marks and hunk
/// headers, the file's status and place in the list, Stage or Unstage, Open in, and `n`/`p`, `]`/`[` and Esc.
struct ReviewTabView: View {
    @ObservedObject var model: AppWorkspaceModel
    let review: ReviewTab
    @FocusState private var focused: Bool
    @State private var changeIndex: Int?
    @State private var jump: DiffJump?
    @State private var diffFocus = DiffFocusRequest()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(model.separatorOverlay)
            // Translucent, the diff follows the panes and the header and footer the chrome; one fill under each (FR-TH10).
            content.background(model.panesTranslucent ? model.terminalBackground.opacity(model.effectiveBackgroundOpacity) : .clear)
            Divider().overlay(model.separatorOverlay)
            footer
        }
        .background(model.panesTranslucent ? .clear : model.terminalBackground)
        .accessibilityElement(children: .contain).accessibilityLabel(L("Review %@", review.file.name))
        .onAppear {
            diffFocus.pending = true
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: review.file) { _, _ in
            changeIndex = nil; jump = nil
        }
        // Staging from here must say how it went with the sidebar hidden too; the Changes view announces it when shown.
        .onChange(of: model.gitChanges.status) { _, status in
            if let status, model.visibleSidebarView != .changes { AccessibilityNotification.Announcement(status).post() }
        }
    }

    // MARK: Header

    private var header: some View {
        let muted = model.themeColor(.mutedForeground)
        let file = review.file
        let folder = (file.path as NSString).deletingLastPathComponent
        let busy = model.gitChanges.staging.contains(file.path)
        return HStack(spacing: 10) {
            HStack(spacing: 0) {
                if !folder.isEmpty { Text(folder + "/").foregroundStyle(muted) }
                Text(file.name).fontWeight(.semibold).strikethrough(file.kind == .deleted)
            }
            .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head).help(file.path)
            .accessibilityElement(children: .combine).accessibilityLabel(file.path)
            HStack(spacing: 5) {
                Text(file.kind.letter).font(.system(size: 11, weight: .semibold, design: .monospaced))
                Text(file.kind.word).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(ChangeStatusLetter.tint(file.kind, model)).padding(.horizontal, 6).frame(height: 20)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ChangeStatusLetter.tint(file.kind, model).opacity(0.6), lineWidth: 1))
            .accessibilityElement(children: .combine)
            if file.binary {
                Text(L("binary")).font(.caption).foregroundStyle(muted)
            } else {
                LineCounts(model: model, added: file.added ?? 0, removed: file.removed ?? 0)
                    .accessibilityElement().accessibilityLabel(L("%1$d lines added, %2$d removed", file.added ?? 0, file.removed ?? 0))
            }
            if let staged = file.staging.word { Text(staged).font(.caption).foregroundStyle(muted) }
            Spacer(minLength: 8)
            if let position = model.reviewPosition {
                HStack(spacing: 2) {
                    Button {
                        Task { await model.reviewAdjacentFile(-1) }
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(position.index <= 1).help(L("Previous file ([)")).accessibilityLabel(L("Previous changed file"))
                    Text(L("%1$d of %2$d", position.index, position.count)).font(.caption).monospacedDigit().foregroundStyle(muted).frame(minWidth: 50)
                    Button {
                        Task { await model.reviewAdjacentFile(1) }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(position.index >= position.count).help(L("Next file (])")).accessibilityLabel(L("Next changed file"))
                }.buttonStyle(.borderless)
            }
            Button(file.staging == .full ? L("Unstage") : L("Stage")) { Task { await model.toggleGitChangeStaged(file.path) } }
                .controlSize(.small).disabled(busy || model.gitChanges.list?.root != review.root)
                .help(file.staging == .full ? L("Unstage %@", file.name) : L("Stage all of %@", file.name))
            Button {
                Task { await model.openGitChange(review.root, file) }
            } label: {
                Label(L("Open in %@", model.files.editor.name), systemImage: "arrow.up.forward.app")
            }
            .controlSize(.small).disabled(file.kind == .deleted).help(L("Open %1$@ in %2$@ (Return)", file.name, model.files.editor.name))
            Button {
                Task { await model.reloadReview() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless).help(L("Read the diff again")).accessibilityLabel(L("Reload diff"))
        }
        .padding(.horizontal, 14).padding(.vertical, 8).background(model.chromeFill(.surface))
    }

    // MARK: Diff

    @ViewBuilder private var content: some View {
        switch review.diff?.body {
        case nil:
            if review.failed {
                notice(L("Couldn't read the diff"), L("Git failed or took too long. Reload to try again."))
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .binary?: notice(L("Binary file"), L("Binary file; no text diff."))
        case .tooLarge?: notice(L("Diff too large"), L("This diff is over 2 MB or 20,000 lines. Open the file to see it."))
        case .unchanged?: notice(L("No changes"), L("%@ no longer differs from HEAD.", review.file.name))
        case .lines(let lines)?: diff(lines)
        }
    }

    private func notice(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(model.themeColor(.mutedForeground))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).focusable().focused($focused).focusEffectDisabled().onKeyPress(phases: .down) { handleKey($0) }
        // A notice takes the keyboard a diff was asked to take, so `]` from a diff onto a binary file keeps working, and
        // the request doesn't wait for some later diff.
        .onAppear {
            guard diffFocus.pending else { return }
            diffFocus.pending = false
            DispatchQueue.main.async { focused = true }
        }
        .accessibilityElement(children: .combine)
    }

    private func diff(_ lines: [GitDiffLine]) -> some View {
        DiffTextView(
            lines: lines, palette: DiffPalette(model), accessibilityName: L("Unified diff of %@", review.file.name), jump: jump, reduceMotion: model.reduceMotion,
            focus: diffFocus, onKey: { handleKey($0) })
    }

    private var footer: some View {
        HStack(spacing: 16) {
            hint("n / p", L("next or previous change"))
            hint("] / [", L("next or previous file"))
            hint("↩", L("open in %@", model.files.editor.name))
            hint("esc", L("back to the terminal"))
            Spacer(minLength: 0)
            if let status = model.gitChanges.status { Text(status).foregroundStyle(model.themeColor(.foreground)).truncationMode(.middle).layoutPriority(1) }
        }
        .font(.caption).foregroundStyle(model.themeColor(.mutedForeground)).lineLimit(1)
        .padding(.horizontal, 14).padding(.vertical, 6).background(model.chromeFill(.surface))
    }

    private func hint(_ keys: String, _ text: String) -> some View {
        (Text(keys).fontWeight(.semibold).foregroundColor(model.themeColor(.foreground)) + Text(" " + text)).fixedSize()
    }

    // MARK: Keyboard

    /// A notice's keys, through SwiftUI.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.subtracting([.shift, .numericPad]).isEmpty || press.key == .escape else { return .ignored }
        switch press.key {
        case .escape: return perform("\u{1B}") ? .handled : .ignored
        case .return: return perform("\r") ? .handled : .ignored
        default: return perform(press.characters) ? .handled : .ignored
        }
    }

    /// The diff's keys, from its text view.
    private func handleKey(_ event: NSEvent) -> Bool {
        let escape = event.keyCode == 53
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty || escape else { return false }
        return perform(escape ? "\u{1B}" : [36, 76].contains(event.keyCode) ? "\r" : event.charactersIgnoringModifiers ?? "")
    }

    private func perform(_ key: String) -> Bool {
        switch key {
        case "\u{1B}": model.hideReview()
        case "\r": Task { await model.openGitChange(review.root, review.file) }
        // The file these lead to takes the keyboard, as this one has it.
        case "]", "[":
            diffFocus.pending = true
            Task { await model.reviewAdjacentFile(key == "]" ? 1 : -1) }
        case "n", "p":
            guard case .lines? = review.diff?.body, let starts = review.diff?.changeStarts, !starts.isEmpty else { return false }
            let next: Int
            if let current = changeIndex {
                next = min(max(current + (key == "n" ? 1 : -1), 0), starts.count - 1)
            } else {
                next = key == "n" ? 0 : starts.count - 1
            }
            changeIndex = next
            jump = DiffJump(line: starts[next])
        default: return false
        }
        return true
    }
}
