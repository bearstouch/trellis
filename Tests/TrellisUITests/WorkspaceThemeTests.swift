import AppKit
import XCTest
import TrellisCore
import SwiftTerm
@testable import TrellisUI

@MainActor
final class WorkspaceThemeTests: XCTestCase {
    func testBuiltInChromeReturnsAfterCustomPreviewInBothAppearances() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        for slot in ThemeAppearance.allCases {
            model.useTheme(ResolvedTheme.builtIn(slot).id)
            XCTAssertTrue(model.usesNativeChrome)
            XCTAssertNil(model.chromeTint)
            let terminalPalette = model.effectiveTheme.terminal
            let document = try ThemeValidator.validate(ThemeExamples.data(slot == .light ? .light : .dark))
            model.previewThemeInWorkspace(document)
            XCTAssertFalse(model.usesNativeChrome)
            XCTAssertNotNil(model.chromeTint)
            XCTAssertEqual(model.effectiveTheme, document.resolved())
            model.cancelThemePreview()
            XCTAssertTrue(model.usesNativeChrome)
            XCTAssertEqual(model.effectiveTheme.terminal, terminalPalette)
        }
    }
    func testS016_UT03_cancelPreviewRestoresEffectivePalette() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-theme-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ThemeLibrary(directory: directory.appendingPathComponent("Themes"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), persistence: WorkspacePersistence(directory: directory), themeLibrary: library)
        _ = await model.loadWorkspace()
        await model.createWindow(startSession: false)
        let dark = try ThemeValidator.validate(ThemeExamples.data(.dark))
        let saved = await model.saveTheme(dark)
        XCTAssertTrue(saved)
        let terminal = try XCTUnwrap(model.activeTerminal)
        let settings = model.appearance, effective = model.effectiveTheme, snapshot = model.snapshot
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = terminal.view
        XCTAssertTrue(window.makeFirstResponder(terminal.view))
        terminal.adapter.receive(Data("selected Unicode 漢字\r\n".utf8))
        terminal.searchQuery = "Unicode 漢字"; XCTAssertTrue(terminal.findInPane(reset: true))
        let preview = try ThemeValidator.validate(ThemeExamples.data(.light))
        model.previewThemeInWorkspace(preview)
        XCTAssertEqual(model.effectiveTheme, preview.resolved())
        XCTAssertEqual(model.appearance, settings)
        XCTAssertEqual(model.snapshot, snapshot)
        XCTAssertTrue(window.firstResponder === terminal.view)
        XCTAssertEqual(terminal.view.accessibilitySelectedText(), "Unicode 漢字")
        XCTAssertTrue(terminal.findInPane(reset: true))
        let persisted = await model.flushWorkspaceSave()
        XCTAssertTrue(persisted)
        model.cancelThemePreview()
        XCTAssertEqual(model.effectiveTheme, effective)
        XCTAssertEqual(model.appearance, settings)
        XCTAssertTrue(model.activeTerminal === terminal)
        XCTAssertTrue(window.firstResponder === terminal.view)
        XCTAssertEqual(terminal.view.accessibilitySelectedText(), "Unicode 漢字")
        XCTAssertNil(terminal.processID)
        let restored = AppWorkspaceModel(store: try WorkspaceStore(), persistence: WorkspacePersistence(directory: directory), themeLibrary: ThemeLibrary(directory: directory.appendingPathComponent("Themes")))
        _ = await restored.loadWorkspace()
        XCTAssertEqual(restored.effectiveTheme, effective)
        XCTAssertEqual(restored.appearance, settings)
        XCTAssertFalse(try XCTUnwrap(restored.activeTerminal).isRunning)
    }
    func testInvalidReloadRetainsColorsAndDeleteOrMissingLaunchFallsBack() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-theme-fallback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let themes = directory.appendingPathComponent("Themes")
        let model = AppWorkspaceModel(store: try WorkspaceStore(), persistence: WorkspacePersistence(directory: directory), themeLibrary: ThemeLibrary(directory: themes))
        _ = await model.loadWorkspace()
        let document = try ThemeValidator.validate(ThemeExamples.data(.dark))
        _ = await model.saveTheme(document)
        let before = model.effectiveTheme
        try Data("invalid".utf8).write(to: themes.appendingPathComponent("my-dark.theme.json"))
        await model.reloadThemes()
        XCTAssertEqual(model.effectiveTheme, before)
        XCTAssertTrue(model.themeNotice?.contains("my-dark.theme.json") == true)
        let persisted = await model.flushWorkspaceSave(); XCTAssertTrue(persisted)
        try FileManager.default.removeItem(at: themes.appendingPathComponent("my-dark.theme.json"))
        let restored = AppWorkspaceModel(store: try WorkspaceStore(), persistence: WorkspacePersistence(directory: directory), themeLibrary: ThemeLibrary(directory: themes))
        _ = await restored.loadWorkspace()
        XCTAssertEqual(restored.appearance.darkThemeID, "trellis-dark")
        XCTAssertEqual(restored.effectiveTheme, .builtIn(.dark))
        XCTAssertTrue(restored.themeNotice?.contains("my-dark") == true)
        _ = await model.saveTheme(document, replace: true)
        await model.deleteTheme(document.id)
        XCTAssertEqual(model.appearance.darkThemeID, "trellis-dark")
        XCTAssertEqual(model.effectiveTheme, .builtIn(.dark))
        XCTAssertTrue(model.themeNotice?.contains("unavailable") == true)
    }
    func testZoomKeepsCustomColorsAndSystemResolvesSeparateSlots() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-theme-system-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppWorkspaceModel(store: try WorkspaceStore(), themeLibrary: ThemeLibrary(directory: directory))
        _ = await model.loadWorkspace()
        await model.createWindow(startSession: false)
        let dark = try ThemeValidator.validate(ThemeExamples.data(.dark)), light = try ThemeValidator.validate(ThemeExamples.data(.light))
        _ = await model.saveTheme(dark); _ = await model.saveTheme(light)
        var settings = model.appearance; settings.chromeMode = .system
        _ = model.applyAppearance(settings)
        model.systemAppearanceDidChange(isDark: true)
        XCTAssertEqual(model.effectiveTheme, dark.resolved())
        model.systemAppearanceDidChange(isDark: false)
        XCTAssertEqual(model.effectiveTheme, light.resolved())
        model.zoomTerminalFont(by: 1)
        XCTAssertEqual(model.effectiveTheme, light.resolved())
        XCTAssertEqual(model.appearance.fontSize, 14)
    }
    func testThemeUseSaveAndSlotsPreserveNegotiatedCursorAndLiveProcess() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-theme-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppWorkspaceModel(store: try WorkspaceStore(), themeLibrary: ThemeLibrary(directory: directory))
        await model.createWindow(startSession: false)
        let native = try XCTUnwrap(model.activeTerminal)
        await native.start(configuration: LocalLaunchConfiguration(executable: "/bin/zsh", arguments: ["-f", "-c", "read -r line; exit 42"], directory: "/tmp"))
        defer { native.requestTermination(force: true) }
        let pid = try XCTUnwrap(native.processID)
        let surface = try XCTUnwrap(native.view as? TerminalView)
        native.adapter.receive(Data("\u{1b}[3 q\u{1b}[?2004hLIVE".utf8))
        let style = surface.getTerminal().options.cursorStyle
        XCTAssertEqual(style, .blinkUnderline)
        let document = try ThemeValidator.validate(ThemeExamples.data(.dark))
        let saved = await model.saveTheme(document)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.appearance.darkThemeID, document.id)
        model.useTheme("trellis-light")
        var settings = model.appearance; settings.darkThemeID = document.id
        _ = model.applyAppearance(settings)
        XCTAssertEqual(surface.getTerminal().options.cursorStyle, style)
        XCTAssertTrue(surface.getTerminal().bracketedPasteMode)
        XCTAssertEqual(native.processID, pid)
        XCTAssertTrue(native.isRunning)
    }
}
