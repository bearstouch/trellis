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
        await model.createWindow(startSession: false)
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
}
