import AppKit
import XCTest
import TrellisCore
@testable import TrellisUI

final class WorkspacePasteTests: XCTestCase {
    @MainActor
    func testReviewCannotFollowFocusOrClosedPaneAndApprovedPasteTargetsOnePane() async throws {
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
                .configureStoppedSession(
                    paneID: id,
                    launch: .process(executable: "/bin/zsh", arguments: ["-f", "-c", "stty -echo; printf 'READY\\n'; exec /bin/cat"], directory: "/tmp")))
        }
        await model.refresh()
        await model.start(paneID: first); await model.start(paneID: second)
        defer {
            model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        let a = try XCTUnwrap(model.terminals[first]), b = try XCTUnwrap(model.terminals[second])
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let firstReady = try a.adapter.read(.retainedText).contains("READY")
            let secondReady = try b.adapter.read(.retainedText).contains("READY")
            if firstReady && secondReady { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await model.waitForUpdates()
        _ = await model.selectPane(first)
        // A clipboard action queued before a focus-away/back cycle must not
        // arrive late as a new review or silently target a replacement session.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = a.view
        window.makeFirstResponder(a.view)
        a.onPasteRequested?(.text("NEVER_QUEUED\n"))
        b.onFocused?()
        a.onFocused?()
        for _ in 0..<10 { await Task.yield() }
        await model.waitForUpdates()
        XCTAssertNil(model.pendingPaste)
        _ = await model.selectPane(first)
        model.requestPaste(.text("NEVER_CANCEL\n"), paneID: first)
        XCTAssertNotNil(model.pendingPaste)
        model.cancelPaste()
        model.requestPaste(.text("NEVER_STALE\n"), paneID: first)
        let stale = try XCTUnwrap(model.pendingPaste).id
        _ = await model.selectPane(second)
        XCTAssertNil(model.pendingPaste)
        _ = await model.selectPane(first)
        model.confirmPaste(stale)
        model.requestPaste(.text("NEVER_CLOSE\n"), paneID: first)
        let closed = try XCTUnwrap(model.pendingPaste).id
        await model.closePane(first)
        XCTAssertNil(model.pendingPaste)
        model.confirmPaste(closed)
        model.requestPaste(.text("APPROVED_ONE\n"), paneID: second)
        let approved = try XCTUnwrap(model.pendingPaste).id
        model.confirmPaste(approved)
        let sentDeadline = Date().addingTimeInterval(3)
        while !(try b.adapter.read(.retainedText)).contains("APPROVED_ONE"), Date() < sentDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let aText = try a.adapter.read(.retainedText)
        let bText = try b.adapter.read(.retainedText)
        XCTAssertFalse(aText.contains("NEVER_"), aText)
        XCTAssertFalse(bText.contains("NEVER_"), bText)
        XCTAssertTrue(bText.contains("APPROVED_ONE"), bText)
        XCTAssertFalse(aText.contains("APPROVED_ONE"), aText)
        XCTAssertNil(model.pendingPaste)
        XCTAssertNil(model.errorMessage)
    }
}
