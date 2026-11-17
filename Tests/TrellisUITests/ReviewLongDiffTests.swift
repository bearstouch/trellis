import AppKit
import SwiftUI
import XCTest
import TrellisCore
@testable import TrellisUI

/// The Review tab with a long diff (FR-GC09): the diff as one text, its scroll height exact once laid out, `n`/`p` from
/// the text view, and the gutter's room kept when it scrolls.
final class ReviewLongDiffTests: XCTestCase {
    private func diffText(hunks: Int) -> String {
        var out = "diff --git a/big.swift b/big.swift\nindex 111..222 100644\n--- a/big.swift\n+++ b/big.swift\n"
        for hunk in 0..<hunks {
            out += "@@ -\(hunk * 40 + 1),8 +\(hunk * 40 + 1),9 @@ func section\(hunk)()\n"
            for index in 0..<5 { out += "     let context\(index) = value(\(hunk), \(index))\n" }
            out += "-    let removed = oldCall(argument: \(hunk)) // a comment long enough to wrap in a narrow tab, so lines differ in height from each other\n"
            out += "+    let añadido = newCall(argument: \(hunk)) // 🙂\n"
            out += "+\n"
            for index in 0..<2 { out += "     let tail\(index) = done(\(hunk))\n" }
        }
        return out
    }

    private func lines(hunks: Int) throws -> (GitFileDiff, [GitDiffLine]) {
        let diff = GitChanges.parseDiff(diffText(hunks: hunks))
        guard case .lines(let lines) = diff.body else { throw XCTSkip("The sample diff should parse as lines") }
        return (diff, lines)
    }

    func testTheDiffAsOneTextMapsPlacesBackToLines() throws {
        let (_, lines) = try lines(hunks: 3)
        let diff = DiffText(lines)
        let text = diff.text as NSString
        XCTAssertEqual(diff.length, text.length)
        XCTAssertEqual(diff.text.split(separator: "\n", omittingEmptySubsequences: false).count, lines.count, "One line of text per diff line, the empty added line too")
        for (index, line) in lines.enumerated() {
            let range = diff.range(ofLine: index)
            XCTAssertEqual(text.substring(with: range), line.text, "Line \(index) is found by UTF-16 offsets, accents and emoji before it or not")
            XCTAssertEqual(diff.lineIndex(at: range.location), index)
            XCTAssertEqual(diff.lineIndex(at: NSMaxRange(range)), index, "A line's newline, or the end of the text, belongs to it")
        }
        XCTAssertNil(DiffText([]).lineIndex(at: 0))
        XCTAssertEqual(diff.lineIndices(in: NSRange(location: diff.starts[2], length: diff.starts[5] - diff.starts[2])), 2...4)
    }

    func testVoiceOverReadsWholeLinesInWords() throws {
        let (_, lines) = try lines(hunks: 1)
        let diff = DiffText(lines)
        let text = diff.text as NSString
        let removed = try XCTUnwrap(lines.firstIndex { $0.kind == .removed }), added = removed + 1
        XCTAssertEqual(diff.spoken(for: diff.range(ofLine: removed), in: text), lines[removed].spoken)
        XCTAssertTrue(try XCTUnwrap(diff.spoken(for: diff.range(ofLine: added), in: text)).hasPrefix("Added line 6: "), "FR-GC08's words, with the new file's line number")
        var withNewline = diff.range(ofLine: removed)
        withNewline.length += 1
        XCTAssertEqual(diff.spoken(for: withNewline, in: text), lines[removed].spoken, "A line asked for with its newline reads the same")
        let both = NSRange(location: diff.starts[removed], length: NSMaxRange(diff.range(ofLine: added)) - diff.starts[removed])
        XCTAssertEqual(diff.spoken(for: both, in: text), lines[removed].spoken + "\n" + lines[added].spoken)

        // A wrapped line is asked for a piece at a time: its first piece says what the line is, the rest is plain text.
        let first = NSRange(location: diff.starts[removed], length: 20)
        XCTAssertEqual(diff.spoken(for: first, in: text), "Removed line 6: " + text.substring(with: first))
        XCTAssertNil(diff.spoken(for: NSRange(location: diff.starts[removed] + 20, length: 10), in: text), "The middle of a line reads as its own text")
        XCTAssertNil(diff.spoken(for: NSRange(location: diff.starts[removed], length: 0), in: text), "An empty range has nothing to read")
        XCTAssertNil(diff.spoken(for: NSRange(location: diff.starts[removed], length: diff.length), in: text), "A range past the text is left to the text view")
    }

    @MainActor
    func testAnEmptyLastLineTabsAndANewThemeAreDrawnInPlace() async throws {
        _ = NSApplication.shared
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-rl-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-rl-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch))
        // A tab far along a line, and an added empty line at the very end.
        let lines = [
            GitDiffLine(id: 0, kind: .hunk, old: nil, new: nil, text: "@@ -1,2 +1,3 @@"),
            GitDiffLine(id: 1, kind: .context, old: 1, new: 1, text: "let a = 1" + String(repeating: " ", count: 60) + "\t// far"),
            GitDiffLine(id: 2, kind: .context, old: 2, new: 2, text: "\tindented"),
            GitDiffLine(id: 3, kind: .added, old: nil, new: 3, text: "")
        ]
        let textView = DiffNSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(textView)
        textView.show(DiffText(lines), colors: DiffColors(DiffPalette(model)))
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))

        let visible = textView.visibleLines(in: textView.bounds)
        XCTAssertEqual(visible.map(\.index), [0, 1, 2, 3], "The empty last line is there to number, mark and tint")
        XCTAssertGreaterThan(visible[3].rect.height, 10)
        XCTAssertGreaterThan(visible[3].rect.minY, visible[2].rect.minY)
        XCTAssertEqual(visible[1].rect.height, visible[2].rect.height, accuracy: 0.5, "A tab past column 47 doesn't break its line")
        let style = try XCTUnwrap(textView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertTrue(style.tabStops.isEmpty)
        XCTAssertGreaterThan(style.defaultTabInterval, 20)

        // A new theme recolors the same text: selection and layout stay.
        textView.setSelectedRange(NSRange(location: 3, length: 4))
        let hunkColor = try XCTUnwrap(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        var palette = DiffColors(DiffPalette(model))
        palette = DiffColors(foreground: .systemPink, muted: palette.muted, accent: .systemTeal, added: palette.added, removed: palette.removed)
        textView.recolor(palette)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 4))
        XCTAssertEqual(textView.string, DiffText(lines).text)
        XCTAssertNotEqual(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, hunkColor)
        XCTAssertEqual(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemTeal, "A hunk header takes the accent")
        XCTAssertEqual(textView.textStorage?.attribute(.foregroundColor, at: 20, effectiveRange: nil) as? NSColor, .systemPink)
    }

    @MainActor private final class ReviewBox: ObservableObject {
        @Published var review: ReviewTab
        init(_ review: ReviewTab) { self.review = review }
    }

    private struct ReviewHost: View {
        let model: AppWorkspaceModel
        @ObservedObject var box: ReviewBox
        var body: some View { ReviewTabView(model: model, review: box.review) }
    }

    @MainActor private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        for child in view.subviews { if let found = find(type, in: child) { return found } }
        return nil
    }

    @MainActor
    private func waitFor(_ timeout: TimeInterval = 10, in host: NSView, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
        }
    }

    @MainActor private func press(_ characters: String, in textView: NSTextView) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: textView.window?.windowNumber ?? 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
        textView.keyDown(with: event)
    }

    @MainActor
    func testALongDiffHasItsExactHeightAndKeysScrollIt() async throws {
        _ = NSApplication.shared
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-rl-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-rl-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch))
        let (diff, lines) = try lines(hunks: 500)
        let review = ReviewTab(root: "/tmp/repo", file: GitChangedFile(path: "Sources/big.swift", kind: .modified, staging: .none, added: 1000, removed: 500), hasCommits: true, diff: diff)
        let box = ReviewBox(review)
        let host = NSHostingView(rootView: ReviewHost(model: model, box: box).frame(width: 700, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(find(DiffNSTextView.self, in: host))
        let scroll = try XCTUnwrap(textView.enclosingScrollView)
        XCTAssertEqual(textView.diff.lines.count, lines.count)
        XCTAssertFalse(textView.isEditable)
        try await waitFor(in: host) { textView.laidOut == textView.diff.length && window.firstResponder === textView }
        XCTAssertEqual(textView.laidOut, textView.diff.length, "The whole diff is laid out shortly after it opens")
        XCTAssertTrue(window.firstResponder === textView, "The diff takes the keyboard when the tab appears")

        // Laid out through, the height is exact: scrolling to any part of it changes nothing.
        let height = textView.frame.height
        let gutter = scroll.contentView.bounds.origin.x
        XCTAssertLessThan(gutter, -100, "The text starts right of the gutter")
        XCTAssertGreaterThan(height, CGFloat(lines.count) * 14)
        var offset: CGFloat = 0
        while offset < height - 600 {
            scroll.contentView.scroll(to: NSPoint(x: gutter, y: offset)); scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(textView.frame.height, height, accuracy: 1, "Scrolling to \(offset) changed the diff's height, which moves the scroller")
            XCTAssertEqual(scroll.contentView.bounds.origin.y, offset, accuracy: 1)
            offset += height / 12
        }
        XCTAssertFalse(textView.visibleLines(in: textView.visibleRect).isEmpty)

        // `n` from the text view goes to the next change, a quarter of the way down, and keeps the gutter's room.
        scroll.contentView.scroll(to: NSPoint(x: gutter, y: 0))
        for _ in 0..<40 {
            try press("n", in: textView)
            // One redraw per key, as when typed.
            try await Task.sleep(for: .milliseconds(5))
            host.layoutSubtreeIfNeeded()
        }
        let fortieth = try XCTUnwrap(diff.changeStarts.dropFirst(39).first)
        try await waitFor(3, in: host) { textView.visibleLines(in: textView.visibleRect).contains { $0.index == fortieth } }
        let shown = try XCTUnwrap(textView.visibleLines(in: textView.visibleRect).first { $0.index == fortieth }, "The fortieth change is on screen")
        XCTAssertEqual(shown.rect.minY - textView.visibleRect.minY, textView.visibleRect.height * 0.25, accuracy: 30)
        XCTAssertEqual(scroll.contentView.bounds.origin.x, gutter, accuracy: 0.5, "Scrolling never slides the text under the gutter")
        let down = scroll.contentView.bounds.origin.y
        try press("p", in: textView)
        try await waitFor(3, in: host) { scroll.contentView.bounds.origin.y < down - 1 }
        XCTAssertLessThan(scroll.contentView.bounds.origin.y, down, "`p` goes back up")
        XCTAssertEqual(textView.frame.height, height, accuracy: 1)

        // Read again (the next file, a reload, a refresh), the diff is a new view: it takes the keyboard the old one had.
        box.review.diff = nil
        try await waitFor(3, in: host) { self.find(DiffNSTextView.self, in: host) == nil }
        box.review.diff = diff
        try await waitFor(3, in: host) { (self.find(DiffNSTextView.self, in: host)).map { window.firstResponder === $0 } ?? false }
        let reloaded = try XCTUnwrap(find(DiffNSTextView.self, in: host))
        XCTAssertFalse(reloaded === textView)
        XCTAssertTrue(window.firstResponder === reloaded, "Keys keep working after the diff is read again")

        let other = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x",
                isARepeat: false, keyCode: 7))
        XCTAssertFalse(try XCTUnwrap(reloaded.onKey)(other))
        window.contentView = nil
    }
}
