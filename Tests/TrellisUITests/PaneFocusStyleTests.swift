import AppKit
import SwiftUI
import XCTest
import TrellisCore
@testable import TrellisUI

@MainActor
final class PaneFocusStyleTests: XCTestCase {
    private func style(_ model: AppWorkspaceModel, _ pane: UUID, _ tab: UUID, active: Bool = true, contrast: Bool = false) -> PaneFocusStyle {
        model.paneFocusStyle(paneID: pane, tabID: tab, windowActive: active, increasedContrast: contrast)
    }

    private func splitModel() async throws -> (AppWorkspaceModel, tab: UUID, left: UUID, right: UUID) {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        await model.createWindow(name: "Focus", startSession: false)
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        let left = tab.activePaneID
        await model.splitPane(left, axis: .x, startSession: false)
        await model.waitForUpdates()
        let split = try XCTUnwrap(model.presentation.selectedTab)
        let right = try XCTUnwrap(split.root.paneIDs.first { $0 != left })
        return (model, split.id, left, right)
    }

    func testOnlyTheFocusedPaneIsLitAndOnlyItsNeighborsDimmed() async throws {
        let (model, tab, left, right) = try await splitModel()
        await model.selectPane(left)
        XCTAssertEqual(style(model, left, tab).header, .focused)
        XCTAssertEqual(style(model, left, tab).dim, 0)
        XCTAssertEqual(style(model, right, tab).header, .receded)
        XCTAssertEqual(style(model, right, tab).dim, PaneFocusStyle.neighborDim)
    }

    func testCuesFollowFocus() async throws {
        let (model, tab, left, right) = try await splitModel()
        await model.selectPane(left)
        await model.selectPane(right)
        XCTAssertEqual(style(model, right, tab).header, .focused)
        XCTAssertEqual(style(model, right, tab).dim, 0)
        XCTAssertEqual(style(model, left, tab).header, .receded)
        XCTAssertEqual(style(model, left, tab).dim, PaneFocusStyle.neighborDim)
    }

    func testASinglePaneLooksAsBefore() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        await model.createWindow(name: "One", startSession: false)
        await model.waitForUpdates()
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        XCTAssertEqual(style(model, tab.activePaneID, tab.id).header, .plain)
        XCTAssertEqual(style(model, tab.activePaneID, tab.id).dim, 0)
    }

    func testMaximizedPaneLooksAsBeforeAndRestoreBringsCuesBack() async throws {
        let (model, tab, left, right) = try await splitModel()
        await model.selectPane(left)
        await model.toggleMaximize(left)
        XCTAssertEqual(style(model, left, tab).header, .plain)
        await model.toggleMaximize(left)
        XCTAssertEqual(style(model, left, tab).header, .focused)
        XCTAssertEqual(style(model, right, tab).dim, PaneFocusStyle.neighborDim)
    }

    func testInactiveWindowAndIncreasedContrastKeepHeadersButNeverDim() async throws {
        let (model, tab, left, right) = try await splitModel()
        await model.selectPane(left)
        for (active, contrast) in [(false, false), (true, true), (false, true)] {
            XCTAssertEqual(style(model, left, tab, active: active, contrast: contrast).header, .focused)
            XCTAssertEqual(style(model, right, tab, active: active, contrast: contrast).header, .receded)
            XCTAssertEqual(style(model, right, tab, active: active, contrast: contrast).dim, 0)
        }
    }

    func testAnUnknownTabShowsNoCues() async throws {
        let (model, _, left, _) = try await splitModel()
        XCTAssertEqual(style(model, left, UUID()).header, .plain)
    }

    /// The native tint is translucent, and behind a pane tree are the split dividers' color and the dark terminal canvas.
    func testNativeLightFocusedHeaderStaysLightOverTheDarkCanvas() async throws {
        let (model, tab, left, right) = try await splitModel()
        await model.selectPane(left)
        await model.waitForUpdates()
        XCTAssertTrue(model.usesNativeChrome)
        let layout = try XCTUnwrap(model.presentation.selectedTab?.root)
        let tree = PaneTreeView(model: model, layout: layout, activePaneID: left, tabID: tab)
            .frame(width: 800, height: 400).background(model.terminalBackground).environment(\.colorScheme, .light)
        let image = try XCTUnwrap(ImageRenderer(content: tree).cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        // Low in each 30-point header, below its text and clear of the line on its bottom edge.
        func headerBrightness(x: Int) throws -> CGFloat { try XCTUnwrap(bitmap.colorAt(x: x, y: 24)?.usingColorSpace(.sRGB)).brightnessComponent }
        XCTAssertNotNil(model.terminals[right])
        XCTAssertGreaterThan(try headerBrightness(x: 200), 0.7, "focused header")
        XCTAssertGreaterThan(try headerBrightness(x: 600), 0.7, "receded header")
    }

    func testATerminalUnderTheDimStaysTheHitTarget() async throws {
        let (model, _, left, right) = try await splitModel()
        await model.selectPane(right)
        await model.waitForUpdates()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSHostingView(rootView: WorkspaceRootView(model: model))
        window.contentView = root
        defer { window.close() }
        window.orderFront(nil)
        root.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let dimmed = try XCTUnwrap(model.terminals[left]?.view)
        let frame = root.convert(dimmed.bounds, from: dimmed)
        XCTAssertGreaterThan(frame.width, 0)
        // Clear of the stopped pane's centered Start Session button.
        let point = root.convert(NSPoint(x: frame.minX + 24, y: frame.minY + 24), to: root.superview)
        let hit = try XCTUnwrap(root.hitTest(point))
        XCTAssertTrue(hit === dimmed || hit.isDescendant(of: dimmed), "hit \(type(of: hit))")
    }
}
