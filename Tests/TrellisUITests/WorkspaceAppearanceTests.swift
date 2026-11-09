import AppKit
import XCTest
import TrellisCore
@testable import TrellisUI

final class WorkspaceAppearanceTests: XCTestCase {
    @MainActor
    func testAppearancePersistsAndAppliesToExistingAndRestoredPanes() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-appearance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppWorkspaceModel(store: try WorkspaceStore(), persistence: WorkspacePersistence(directory: directory))
        _ = await model.loadWorkspace()
        await model.createSpace(startSession: false)
        let native = try XCTUnwrap(model.activeTerminal)
        let snapshot = model.snapshot
        var settings = AppearanceSettings()
        settings.chromeMode = .dark; settings.fontName = "Menlo"; settings.fontSize = 17
        settings.lightThemeID = "saved-light-choice"; settings.darkThemeID = "saved-dark-choice"
        var modes: [ChromeMode] = []
        model.onChromeModeChanged = { modes.append($0) }
        XCTAssertTrue(model.applyAppearance(settings))
        XCTAssertTrue(model.activeTerminal === native)
        XCTAssertEqual(model.snapshot, snapshot)
        XCTAssertEqual(modes, [.dark])
        let saved = await model.flushWorkspaceSave()
        XCTAssertTrue(saved)
        let restored = AppWorkspaceModel(store: try WorkspaceStore(), persistence: WorkspacePersistence(directory: directory))
        _ = await restored.loadWorkspace()
        XCTAssertEqual(restored.appearance, settings)
        XCTAssertFalse(try XCTUnwrap(restored.activeTerminal).isRunning)
        restored.zoomTerminalFont(by: 1)
        XCTAssertEqual(restored.appearance.fontSize, 18)
        restored.zoomTerminalFont(by: 0, reset: true)
        XCTAssertEqual(restored.appearance.fontSize, 13)
    }
    @MainActor
    func testTranslucentBackgroundFollowsAccessibilityAndConfiguresTheWindow() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-translucency-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppWorkspaceModel(store: try WorkspaceStore(), persistence: WorkspacePersistence(directory: directory))
        _ = await model.loadWorkspace()
        await model.createSpace(startSession: false)
        let native = try XCTUnwrap(model.activeTerminal)
        var windowStates: [Bool] = []
        model.onWindowTranslucencyChanged = { windowStates.append($0) }
        var settings = model.appearance
        settings.backgroundOpacity = 0.3
        XCTAssertFalse(
            model.applyAppearance(
                {
                    var bad = settings; bad.backgroundOpacity = 0.1; return bad
                }()))
        XCTAssertEqual(model.effectiveBackgroundOpacity, 1, "A rejected opacity changes nothing")
        XCTAssertTrue(model.applyAppearance(settings))
        XCTAssertEqual(model.effectiveBackgroundOpacity, 0.3)
        XCTAssertTrue(model.effectiveBackgroundBlur)
        XCTAssertEqual(native.backgroundOpacity, 0.3)
        settings.backgroundOpacity = 0.7
        XCTAssertTrue(model.applyAppearance(settings))
        XCTAssertEqual(native.backgroundOpacity, 0.7)
        XCTAssertEqual(windowStates, [true], "Only the opaque/translucent switch reconfigures the space")
        // Reduce Transparency and Increase Contrast keep panes opaque without changing the saved setting.
        model.accessibilityDisplayOptionsDidChange(increaseContrast: false, reduceMotion: false, reduceTransparency: true)
        XCTAssertEqual(model.effectiveBackgroundOpacity, 1)
        XCTAssertFalse(model.effectiveBackgroundBlur)
        XCTAssertEqual(native.backgroundOpacity, 1)
        XCTAssertEqual(model.appearance.backgroundOpacity, 0.7)
        model.accessibilityDisplayOptionsDidChange(increaseContrast: true, reduceMotion: false, reduceTransparency: false)
        XCTAssertEqual(native.backgroundOpacity, 1)
        model.accessibilityDisplayOptionsDidChange(increaseContrast: false, reduceMotion: false, reduceTransparency: false)
        XCTAssertEqual(model.effectiveBackgroundOpacity, 0.7)
        XCTAssertEqual(native.backgroundOpacity, 0.7)
        XCTAssertEqual(windowStates, [true, false, true])
        settings.backgroundBlur = false
        XCTAssertTrue(model.applyAppearance(settings))
        XCTAssertFalse(model.effectiveBackgroundBlur)
        let saved = await model.flushWorkspaceSave()
        XCTAssertTrue(saved)
        let restored = AppWorkspaceModel(store: try WorkspaceStore(), persistence: WorkspacePersistence(directory: directory))
        _ = await restored.loadWorkspace()
        XCTAssertEqual(restored.appearance.backgroundOpacity, 0.7)
        XCTAssertEqual(restored.effectiveBackgroundOpacity, 0.7)
        XCTAssertEqual(try XCTUnwrap(restored.activeTerminal).backgroundOpacity, 0.7)
    }
    @MainActor
    func testWindowChromeFollowsTheBackgroundOpacityWithAReadableFloor() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-chrome-opacity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppWorkspaceModel(store: try WorkspaceStore(), persistence: WorkspacePersistence(directory: directory))
        _ = await model.loadWorkspace()
        XCTAssertEqual(model.chromeOpacity, 1, "opaque by default")
        var settings = model.appearance
        settings.backgroundOpacity = 0.8
        XCTAssertTrue(model.applyAppearance(settings))
        XCTAssertEqual(model.chromeOpacity, 0.8, "the chrome matches the panes")
        settings.backgroundOpacity = 0.3
        XCTAssertTrue(model.applyAppearance(settings))
        XCTAssertEqual(model.chromeOpacity, AppWorkspaceModel.minimumChromeOpacity, "but never drops below the readable floor")
        model.accessibilityDisplayOptionsDidChange(increaseContrast: false, reduceMotion: false, reduceTransparency: true)
        XCTAssertEqual(model.chromeOpacity, 1, "Reduce Transparency makes the whole space opaque")
        model.accessibilityDisplayOptionsDidChange(increaseContrast: false, reduceMotion: false, reduceTransparency: false)
        XCTAssertEqual(model.chromeOpacity, AppWorkspaceModel.minimumChromeOpacity)
    }
}
