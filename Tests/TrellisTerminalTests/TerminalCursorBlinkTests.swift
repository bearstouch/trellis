import AppKit
import Metal
import XCTest
import SwiftTerm
import TrellisCore
@testable import TrellisTerminal

/// FR-TX06: a blinking cursor blinks at the chosen speed under both renderers, and the speed applies live.
final class TerminalCursorBlinkTests: XCTestCase {
    private static func blinking(_ speed: TerminalCursorBlinkSpeed?, metal: Bool = false) -> AppearanceSettings {
        var settings = AppearanceSettings()
        settings.cursorBlinks = speed != nil
        if let speed { settings.cursorBlinkSpeed = speed }
        settings.gpuRendering = metal
        return settings
    }

    /// A terminal in a window that blinks without key focus (a test runner's windows never become key).
    @MainActor
    private func hostedTerminal(_ settings: AppearanceSettings) -> (NativeTerminal, TerminalView) {
        _ = NSApplication.shared
        let native = NativeTerminal()
        let view = native.view as! TerminalView
        view.caretViewTracksFocus = false
        native.applyAppearance(settings)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        addTeardownBlock { @MainActor in
            native.adapter.detach()
            window.close()
        }
        return (native, view)
    }

    func testSpeedsAreOrderedAndNormalKeepsTheOriginalRate() {
        XCTAssertEqual(TerminalCursorBlinkSpeed.normal.phaseSeconds, 0.7, "Normal is the rate the cursor blinked at before FR-TX06")
        XCTAssertGreaterThan(TerminalCursorBlinkSpeed.slow.phaseSeconds, TerminalCursorBlinkSpeed.normal.phaseSeconds)
        XCTAssertLessThan(TerminalCursorBlinkSpeed.fast.phaseSeconds, TerminalCursorBlinkSpeed.normal.phaseSeconds)
        XCTAssertEqual(AppearanceSettings().cursorBlinkSpeed, .normal)
    }

    @MainActor
    func testCoreGraphicsCaretBlinksAtTheChosenSpeedAndAppliesLive() {
        let (native, view) = hostedTerminal(Self.blinking(.fast))
        XCTAssertEqual(view.cursorBlinkInterval, 0.4)
        XCTAssertEqual(view.cursorBlinkTimingForTesting.caret, 0.4)
        native.applyAppearance(Self.blinking(.slow))
        XCTAssertEqual(view.cursorBlinkTimingForTesting.caret, 1.0, "a running blink restarts at the new speed")
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .blinkBlock)
        native.applyAppearance(Self.blinking(nil))
        XCTAssertNil(view.cursorBlinkTimingForTesting.caret, "Off is steady")
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBlock)
        native.applyAppearance(Self.blinking(.normal))
        view.cursorBlinkInterval = 60
        XCTAssertEqual(view.cursorBlinkTimingForTesting.caret, 5, "a clamped interval still restarts the running blink")
    }

    @MainActor
    func testMetalCursorBlinksAtTheChosenSpeedAndAppliesLive() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let (native, view) = hostedTerminal(Self.blinking(.fast, metal: true))
        XCTAssertTrue(native.isUsingMetalRenderer)
        func metalInterval() -> TimeInterval? {
            let deadline = Date().addingTimeInterval(3)
            while view.cursorBlinkTimingForTesting.metal == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            return view.cursorBlinkTimingForTesting.metal
        }
        XCTAssertEqual(metalInterval(), 0.4)
        native.applyAppearance(Self.blinking(.slow, metal: true))
        XCTAssertEqual(metalInterval(), 1.0, "the running timer is replaced at the new speed")
    }

    @MainActor
    func testBlinkIntervalIsClampedToAUsableRange() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.cursorBlinkInterval = 0
        XCTAssertEqual(view.cursorBlinkInterval, 0.1)
        view.cursorBlinkInterval = 60
        XCTAssertEqual(view.cursorBlinkInterval, 5)
        view.cursorBlinkInterval = .nan
        XCTAssertEqual(view.cursorBlinkInterval, 0.7)
    }
}
