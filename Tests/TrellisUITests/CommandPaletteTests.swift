import AppKit
import XCTest
import TrellisCore
@testable import TrellisUI

@MainActor
final class CommandPaletteTests: XCTestCase {
    private func makeModel() async throws -> AppWorkspaceModel {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: try XCTUnwrap(UserDefaults(suiteName: "trellis.tests.\(UUID())")))
        await model.createWindow(name: "api-server", startSession: false)
        return model
    }

    /// Rows run after the palette's focus change, on a later main-queue turn.
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testOpeningListsOnlyEnabledActionsAndSuspendsTerminalInput() async throws {
        let model = try await makeModel()
        let terminal = try XCTUnwrap(model.activeTerminal)
        model.canPerformShortcutAction = { [.newTab, .splitLeftRight, .commandPalette, .selectTab1].contains($0) }
        model.openCommandPalette()
        XCTAssertTrue(model.commandPaletteVisible)
        XCTAssertTrue(terminal.inputSuspended)
        let actions = model.commandPaletteItems.compactMap { if case .action(let action) = $0.target { action } else { nil } }
        // The palette and Select Tab N are covered by the palette itself and its tab rows.
        XCTAssertEqual(actions, [.newTab, .splitLeftRight])
        XCTAssertEqual(model.commandPaletteItems.first { $0.target == .action(.newTab) }?.shortcut, KeyChord("t"))
        model.closeCommandPalette()
        XCTAssertFalse(model.commandPaletteVisible)
        XCTAssertFalse(terminal.inputSuspended)
    }

    func testRunningAnActionClosesFirstThenUsesTheMenuPathAndBecomesRecent() async throws {
        let model = try await makeModel()
        var performed: [ShortcutAction] = []
        var visibleWhenPerformed: Bool?
        model.canPerformShortcutAction = { _ in true }
        model.performShortcutAction = { action in
            performed.append(action); visibleWhenPerformed = model.commandPaletteVisible
        }
        model.openCommandPalette()
        model.setCommandPaletteQuery("spl")
        XCTAssertEqual(model.commandPaletteSelectedMatch(in: model.commandPaletteSections)?.item.target, .action(.splitLeftRight))
        model.runCommandPaletteItem()
        XCTAssertFalse(model.commandPaletteVisible)
        try await eventually { performed == [.splitLeftRight] }
        XCTAssertEqual(visibleWhenPerformed, false)
        model.openCommandPalette()
        XCTAssertEqual(model.commandPaletteSections.first?.title, "Recent")
        XCTAssertEqual(model.commandPaletteSections.first?.matches.first?.item.target, .action(.splitLeftRight))
        XCTAssertEqual(model.commandPaletteQuery, "")
    }

    func testGoToTabJumpsAcrossWindowsAndAScopeIsEnteredAndLeft() async throws {
        let model = try await makeModel()
        let first = try XCTUnwrap(model.snapshot.activeWindowID)
        let firstTab = try XCTUnwrap(model.presentation.selectedTab?.id)
        await model.createWindow(name: "web-client", startSession: false)
        let second = try XCTUnwrap(model.snapshot.activeWindowID)
        XCTAssertNotEqual(first, second)
        model.openCommandPalette()
        let scopes = model.commandPaletteSections.flatMap(\.matches).compactMap { if case .scope(let scope) = $0.item.target { scope } else { nil } }
        XCTAssertEqual(scopes.prefix(3), [.windows, .tabs, .panes])
        model.runCommandPaletteItem("scope:tabs")
        XCTAssertTrue(model.commandPaletteVisible)
        XCTAssertEqual(model.commandPaletteScope, .tabs)
        // The current window's tabs come first, under its name.
        XCTAssertEqual(model.commandPaletteSections.map(\.title), ["web-client", "api-server"])
        XCTAssertTrue(model.leaveCommandPaletteScope())
        XCTAssertNil(model.commandPaletteScope)
        XCTAssertFalse(model.leaveCommandPaletteScope())
        model.enterCommandPaletteScope(.tabs)
        model.moveCommandPaletteSelection(by: 1)
        XCTAssertEqual(model.commandPaletteSelectedMatch(in: model.commandPaletteSections)?.item.target, .tab(windowID: first, tabID: firstTab))
        // Wraps at both ends.
        model.moveCommandPaletteSelection(by: 1)
        XCTAssertEqual(model.commandPaletteSelectedMatch(in: model.commandPaletteSections)?.item.groupTitle, "web-client")
        model.moveCommandPaletteSelection(by: -1)
        model.runCommandPaletteItem()
        try await eventually { model.snapshot.activeWindowID == first }
        XCTAssertEqual(model.presentation.selectedTab?.id, firstTab)
    }

    func testThemePreviewIsRestoredExactlyAndASettingsPreviewIsLeftAlone() async throws {
        let model = try await makeModel()
        let document = try ThemeValidator.validate(XCTUnwrap(model.allThemes.first { $0.id == "trellis-dracula-dark" }).encoded())
        // A fresh model resolves its committed theme on the first refresh; settle it before taking the baseline.
        model.previewThemeInWorkspace(document)
        model.cancelThemePreview()
        let settings = model.appearance, theme = model.effectiveTheme
        model.openCommandPalette()
        model.setCommandPaletteQuery("theme nord dark")
        XCTAssertEqual(model.commandPaletteSelectedMatch(in: model.commandPaletteSections)?.item.target, .theme("trellis-nord-dark"))
        XCTAssertEqual(model.effectiveTheme.id, "trellis-nord-dark")
        XCTAssertEqual(model.appearance, settings)
        model.closeCommandPalette()
        XCTAssertNil(model.previewedTheme)
        XCTAssertEqual(model.effectiveTheme, theme)
        XCTAssertEqual(model.appearance, settings)

        model.previewThemeInWorkspace(document)
        model.openCommandPalette()
        model.setCommandPaletteQuery("theme nord dark")
        XCTAssertEqual(model.effectiveTheme.id, "trellis-dracula-dark")
        model.closeCommandPalette()
        XCTAssertEqual(model.previewedTheme, document)
    }

    func testApplyingAThemeCommitsIt() async throws {
        let model = try await makeModel()
        model.openCommandPalette()
        model.setCommandPaletteQuery("theme nord dark")
        model.runCommandPaletteItem()
        try await eventually { model.appearance.darkThemeID == "trellis-nord-dark" }
        XCTAssertNil(model.previewedTheme)
        XCTAssertEqual(model.effectiveTheme.id, "trellis-nord-dark")
    }

    func testHostsAndUnknownQueriesAndClosedPaletteAreSafe() async throws {
        let model = try await makeModel()
        let draft = HostDraft(name: "api-prod", destination: "api-prod.example.com", user: "deploy", port: "2222")
        let host = SavedHost(id: UUID(), draft: try draft.validated { _ in true }, revision: 1)
        model.commandPaletteHosts = { [host] }
        model.openCommandPalette()
        model.setCommandPaletteQuery("api-prod")
        let row = try XCTUnwrap(model.commandPaletteSections.flatMap(\.matches).first { $0.item.kind == .host })
        XCTAssertEqual(row.item.subtitle, "deploy@api-prod.example.com · port 2222")
        model.setCommandPaletteQuery("xyzzy-nothing")
        XCTAssertTrue(model.commandPaletteSections.isEmpty)
        let snapshot = model.snapshot
        model.runCommandPaletteItem()
        XCTAssertTrue(model.commandPaletteVisible)
        model.closeCommandPalette()
        // Nothing runs or changes while the palette is closed.
        model.runCommandPaletteItem("action:newTab")
        model.setCommandPaletteQuery("new")
        XCTAssertEqual(model.commandPaletteQuery, "xyzzy-nothing")
        XCTAssertEqual(model.snapshot, snapshot)
    }

    func testTabRenameAndNewTerminalsKeepInputSuspendedUntilBothEnd() async throws {
        let model = try await makeModel()
        let tab = try XCTUnwrap(model.presentation.selectedTab?.id)
        await model.beginTabRename(tab)
        model.openCommandPalette()
        _ = await model.createTab(startSessions: false)
        let terminals = Array(model.terminals.values)
        XCTAssertEqual(terminals.count, 2)
        XCTAssertTrue(terminals.allSatisfy(\.inputSuspended))
        await model.finishTabRename(tab, draft: "", action: .cancel)
        XCTAssertTrue(terminals.allSatisfy(\.inputSuspended), "the open palette still owns the keyboard")
        model.closeCommandPalette()
        XCTAssertTrue(terminals.allSatisfy { !$0.inputSuspended })
    }

    func testAStaleRowRunsNothingAndAnActionDisabledSinceOpeningIsSkipped() async throws {
        let model = try await makeModel()
        var enabled = true, performed: [ShortcutAction] = []
        model.canPerformShortcutAction = { _ in enabled }
        model.performShortcutAction = { performed.append($0) }
        model.openCommandPalette()
        model.runCommandPaletteItem("tab:\(UUID().uuidString)")
        XCTAssertTrue(model.commandPaletteVisible)
        model.runCommandPaletteItem("action:newTab")
        enabled = false
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(performed, [])
    }

    func testOpeningWithARecentThemeOnTopDoesNotPreviewIt() async throws {
        let model = try await makeModel()
        model.openCommandPalette()
        model.setCommandPaletteQuery("theme nord dark")
        model.runCommandPaletteItem()
        try await eventually { model.appearance.darkThemeID == "trellis-nord-dark" }
        model.useTheme("trellis-dracula-dark")
        let theme = model.effectiveTheme
        model.openCommandPalette()
        XCTAssertEqual(model.commandPaletteSelectedMatch(in: model.commandPaletteSections)?.item.target, .theme("trellis-nord-dark"))
        XCTAssertNil(model.previewedTheme, "opening isn't moving the selection")
        XCTAssertEqual(model.effectiveTheme, theme)
        model.moveCommandPaletteSelection(by: 1)
        model.moveCommandPaletteSelection(by: -1)
        XCTAssertEqual(model.effectiveTheme.id, "trellis-nord-dark")
        model.closeCommandPalette()
        XCTAssertEqual(model.effectiveTheme, theme)
    }

    func testClosingReturnsFocusToTheScratchpadEditorElseTheActivePane() async throws {
        let model = try await makeModel()
        let terminal = try XCTUnwrap(model.activeTerminal)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let paletteField = NSTextField(frame: NSRect(x: 0, y: 200, width: 200, height: 24))
        terminal.view.frame = NSRect(x: 250, y: 0, width: 200, height: 100)
        [editor, paletteField, terminal.view].forEach { window.contentView?.addSubview($0) }
        // The editor had focus; the palette's field takes it while open.
        XCTAssertTrue(window.makeFirstResponder(editor))
        model.openCommandPalette()
        window.makeFirstResponder(paletteField)
        model.closeCommandPalette()
        try await eventually { window.firstResponder === editor }
        // From a terminal (or a field editor), focus goes to the active pane.
        XCTAssertTrue(window.makeFirstResponder(terminal.view))
        model.openCommandPalette()
        window.makeFirstResponder(paletteField)
        model.closeCommandPalette()
        try await eventually { window.firstResponder === terminal.view }
    }
}
