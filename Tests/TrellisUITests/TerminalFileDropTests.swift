import AppKit
import SwiftUI
import XCTest
import TrellisCore
@testable import TrellisTerminal
@testable import TrellisUI

/// FR-C08 through the real drag callbacks. The drag is mocked and the key state faked, so a real Finder drag stays a manual check.
final class TerminalFileDropTests: XCTestCase {
    private final class DropWindow: NSWindow {
        var fakeKey = true
        override var isKeyWindow: Bool { fakeKey }
        override var canBecomeKey: Bool { true }
    }

    private final class MockDrag: NSObject, NSDraggingInfo {
        private let board: NSPasteboard, mask: NSDragOperation
        init(_ board: NSPasteboard, mask: NSDragOperation = .every) { self.board = board; self.mask = mask }
        var draggingPasteboard: NSPasteboard { board }
        var draggingSourceOperationMask: NSDragOperation { mask }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    private func board(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        fill(board)
        let name = board.name
        addTeardownBlock { NSPasteboard(name: name).releaseGlobally() }
        return board
    }

    private func fileBoard(_ paths: String...) -> NSPasteboard { board { $0.writeObjects(paths.map { NSURL(fileURLWithPath: $0) }) } }

    /// Lets SwiftUI apply focus and selection, so a view that pulled first responder back would show up in the assertions.
    @MainActor
    private func settle(_ window: NSWindow, until condition: () throws -> Bool) async rethrows {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if try condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
    }

    @MainActor
    private func assertDropReachesThePaneUnderIt(windowIsKey: Bool) async throws {
        _ = NSApplication.shared
        let store = try WorkspaceStore()
        let model = AppWorkspaceModel(store: store)
        model.confirmCloseSessions = { _ in true }
        model.confirmForceSessions = { _ in true }
        await model.createWindow(startSession: false)
        let first = try XCTUnwrap(model.presentation.activePane?.id)
        await model.splitPane(first, axis: .x, startSession: false)
        let second = try XCTUnwrap(model.presentation.activePane?.id)
        for id in [first, second] {
            _ = try await store.execute(
                .configureStoppedSession(paneID: id, launch: .process(executable: "/bin/zsh", arguments: ["-f", "-c", "stty -echo -icanon; printf 'READY\\n'; exec /bin/cat"], directory: "/tmp")))
        }
        await model.refresh()
        await model.start(paneID: first); await model.start(paneID: second)
        defer {
            model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        _ = await model.selectPane(first)
        let a = try XCTUnwrap(model.terminals[first]), b = try XCTUnwrap(model.terminals[second])
        let window = DropWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.fakeKey = windowIsKey
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceRootView(model: model))
        defer { window.close() }
        window.orderFront(nil)
        try await settle(window) { try a.view.window === window && b.view.window === window && b.adapter.read(.retainedText).contains("READY") }
        XCTAssertTrue(b.view.window === window)
        window.makeFirstResponder(a.view)
        // A focus change queues a deferred grab (TerminalContainerView.display). One landing after the drop takes focus back
        // and the path is lost, a known limit (docs/overview/status.md), so setup must finish first. A deliberate wait, not a condition.
        var passes = 0
        await settle(window) {
            passes += 1
            return passes >= 20
        }
        XCTAssertTrue(window.firstResponder === a.view)

        let view = try XCTUnwrap(b.view as? AccessibleTerminalView)
        let drag = MockDrag(fileBoard("/tmp/DROP one.png", "/tmp/DROP two.png"))
        XCTAssertEqual(view.draggingEntered(drag), .copy)
        XCTAssertEqual(view.draggingUpdated(drag), .copy)
        XCTAssertTrue(view.performDragOperation(drag))
        // performDragOperation raises the real window, so the fake is what keeps the "in the background" start state honest.
        try await settle(window) { try b.adapter.read(.retainedText).contains("DROP two") && model.presentation.activePane?.id == second }
        XCTAssertTrue(try b.adapter.read(.retainedText).contains("'/tmp/DROP one.png' '/tmp/DROP two.png'"))
        XCTAssertFalse(try a.adapter.read(.retainedText).contains("DROP"))
        XCTAssertEqual(model.presentation.activePane?.id, second)
        XCTAssertTrue(window.firstResponder === b.view)
        XCTAssertNil(model.pendingPaste)

        // A newline in a name would run the line it ended, so it goes to review and nothing is sent.
        XCTAssertTrue(view.performDragOperation(MockDrag(fileBoard("/tmp/NEWLINE\nrm -rf x"))))
        await settle(window) { model.pendingPaste != nil }
        XCTAssertNotNil(model.pendingPaste)
        XCTAssertFalse(try b.adapter.read(.retainedText).contains("NEWLINE"))
        model.cancelPaste()
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testDropReachesThePaneUnderItInAKeyWindow() async throws { try await assertDropReachesThePaneUnderIt(windowIsKey: true) }

    @MainActor
    func testDropReachesThePaneUnderItInABackgroundWindow() async throws { try await assertDropReachesThePaneUnderIt(windowIsKey: false) }

    @MainActor
    func testDragCallbacksRefuseWhatAPaneCannotTake() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        var received = 0
        view.onPasteRequested = { _ in received += 1 }
        let files = MockDrag(fileBoard("/tmp/a.png"))

        // The real gate, on a session that was never started.
        XCTAssertEqual(view.draggingEntered(files), [])
        XCTAssertFalse(view.performDragOperation(files))

        view.canAcceptFileDrop = { true }
        XCTAssertEqual(view.draggingEntered(files), .copy, "Everything below is refused for its own reason")
        XCTAssertEqual(view.draggingEntered(MockDrag(fileBoard("/tmp/a.png"), mask: .move)), [])
        XCTAssertEqual(view.draggingEntered(MockDrag(board { $0.setString("/tmp/a.png", forType: .string) })), [])
        XCTAssertEqual(view.draggingEntered(MockDrag(board { $0.writeObjects([NSURL(string: "https://example.com/a.png")!]) })), [])
        let promise = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")
        XCTAssertEqual(
            view.draggingEntered(
                MockDrag(
                    board {
                        $0.declareTypes([promise], owner: nil); $0.setString("public.png", forType: promise)
                    })), [])

        // A second drop must not replace a review that is waiting on an answer.
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet)
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertEqual(view.draggingEntered(files), [])
        XCTAssertFalse(view.performDragOperation(files))
        window.endSheet(sheet)
        XCTAssertEqual(received, 0)
    }
}
