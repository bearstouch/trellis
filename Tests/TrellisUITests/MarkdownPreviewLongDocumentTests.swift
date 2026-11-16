import AppKit
import SwiftUI
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// The Markdown preview with long documents (FR-ED13): it is drawn again only when its blocks or theme change, a long
/// document shows without laying every block out, and `#heading` links still reach blocks that aren't built yet.
final class MarkdownPreviewLongDocumentTests: XCTestCase {
    private var scratch: URL!
    private var project: String!
    private var shell: String!

    private struct Host: View {
        @ObservedObject var model: AppWorkspaceModel
        let id: UUID
        var body: some View { if let tab = model.editorTab(id) { EditorTabView(model: model, tab: tab, shown: true) } }
    }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-mp-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let manager = FileManager.default
        project = scratch.appendingPathComponent("project").path
        for folder in ["bin", "state", "project/.git"] { try manager.createDirectory(at: scratch.appendingPathComponent(folder), withIntermediateDirectories: true) }
        func document(_ sections: Int) -> String {
            (0..<sections).map { "## Section \($0)\n\nSome **bold** text with `code` and a [link](https://example.com/\($0)).\n\n- first item\n- second item\n\n```swift\nlet x = \($0)\n```\n\n" }.joined()
        }
        try document(600).write(toFile: project + "/long.md", atomically: true, encoding: .utf8)
        try document(30).write(toFile: project + "/short.md", atomically: true, encoding: .utf8)
        shell = scratch.appendingPathComponent("bin/sh").path
        try "#!/bin/sh\nprintf 'SHELL-UP\\n'\nexec /bin/cat\n".write(toFile: shell, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    @MainActor private func scrollViews(in view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) } }

    /// The preview's own scroll view: the tallest one that isn't the source editor's.
    @MainActor private func preview(in host: NSView) -> NSScrollView? {
        scrollViews(in: host).filter { !($0.documentView is NSTextView) && ($0.documentView?.frame.height ?? 0) > 1000 }.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    @MainActor
    private func waitFor(_ timeout: TimeInterval = 10, in host: NSView, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
        }
    }

    func testItemsCarryTheIdsHeadingLinksScrollTo() {
        let items = MarkdownPreviewItem.items(MarkdownDocument.parse("# Set *up*\n\ntext\n\n## Set up\n\n- a\n\n## Other\n"))
        XCTAssertEqual(items.map(\.id), ["heading-set-up", "block-1", "heading-set-up-1", "block-3", "heading-other"], "A repeated heading gets -1, as on GitHub")
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "Every block has its own id")
        let clash = MarkdownPreviewItem.items(MarkdownDocument.parse("## Step\n\n## Step\n\n## Step 1\n\n## Step\n"))
        XCTAssertEqual(clash.map(\.id), ["heading-step", "heading-step-1", "heading-step-1-1", "heading-step-2"], "A numbered heading that meets a repeated one still gets an id of its own")
    }

    @MainActor
    func testThePreviewIsDrawnAgainOnlyWhenItsBlocksOrThemeChange() async throws {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-mp-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        let tab = UUID()
        let items = MarkdownPreviewItem.items(MarkdownDocument.parse("# A\n\ntext\n"))
        func content(_ items: [MarkdownPreviewItem], anchor: EditorPreviewAnchor? = nil, reduceMotion: Bool = false) -> MarkdownPreviewContent {
            MarkdownPreviewContent(model: model, tabID: tab, items: items, style: MarkdownPreviewStyle(model), anchor: anchor, reduceMotion: reduceMotion)
        }
        XCTAssertTrue(content(items) == content(items), "Nothing the preview draws changed, so it isn't drawn again")
        XCTAssertTrue(content(items) == content(MarkdownPreviewItem.items(MarkdownDocument.parse("# A\n\ntext\n"))), "The same text read again draws the same")
        XCTAssertFalse(content(items) == content(MarkdownPreviewItem.items(MarkdownDocument.parse("# A\n\nother\n"))), "New text is drawn")
        XCTAssertFalse(content(items) == content(items, anchor: EditorPreviewAnchor(slug: "a")), "A heading link reaches it")
        let before = content(items)
        var appearance = model.appearance
        appearance.fontSize += 2
        XCTAssertTrue(model.applyAppearance(appearance))
        XCTAssertFalse(before == content(items), "A new font size is drawn")
    }

    @MainActor
    func testALongDocumentShowsAndItsHeadingLinksScroll() async throws {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-mp-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        _ = await model.loadWorkspace()
        model.confirmCloseSessions = { _ in true }
        model.workspaceIsFrontmost = { true }
        model.openFileInApp = { _, _ in }
        model.revealFiles = { _ in }
        let saved = await model.saveLaunchSettings(shell: shell, directory: project)
        XCTAssertTrue(saved)
        _ = await model.createSpace(name: "W")
        defer {
            model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }

        for (name, sections, lazy) in [("short.md", 30, false), ("long.md", 600, true)] {
            let opened = await model.openInEditor(path: project + "/" + name, projectRoot: project)
            XCTAssertTrue(opened)
            let tab = try XCTUnwrap(model.editorTabs.values.joined().first { $0.fileName == name })
            XCTAssertEqual(sections * 4 > MarkdownPreviewContent.wholeLayoutLimit, lazy, "\(name) is on the side of the limit this test means it to be")
            let host = NSHostingView(rootView: Host(model: model, id: tab.id).frame(width: 900, height: 700))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            model.toggleEditorPreview(tab.id)
            try await waitFor(in: host) { self.preview(in: host) != nil }
            let scroll = try XCTUnwrap(preview(in: host), "\(name): the preview shows")
            let height = try XCTUnwrap(scroll.documentView).frame.height
            XCTAssertGreaterThan(height, CGFloat(sections) * 100, "\(name): the whole document has room to scroll, not just the blocks built so far")
            XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1)

            // A `#heading` link far down the document, to a block a long document hasn't built yet.
            await model.openMarkdownLink("#section-\(sections - 5)", in: tab.id)
            try await waitFor(3, in: host) { scroll.contentView.bounds.origin.y > height / 2 }
            XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, height / 2, "\(name): the heading link scrolls to its heading")
            window.contentView = nil
        }
    }
}
