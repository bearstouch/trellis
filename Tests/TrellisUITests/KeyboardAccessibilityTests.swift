import AppKit
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

final class KeyboardAccessibilityTests: XCTestCase {
    private let noReplacement = NSRange(location: NSNotFound, length: 0)

    @MainActor
    func testS017_UT02_editingConsumesRenameKeys() async throws {
        _ = NSApplication.shared
        let store = try WorkspaceStore()
        let model = AppWorkspaceModel(store: store)
        model.confirmCloseSessions = { _ in true }
        model.confirmForceSessions = { _ in true }
        await model.createWindow(startSession: false)
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        _ = try await store.execute(
            .configureStoppedSession(
                paneID: pane, launch: .process(executable: "/bin/zsh", arguments: ["-f", "-c", "stty -echo; printf 'READY\\n'; exec /bin/cat"], directory: "/tmp")))
        await model.refresh()
        await model.start(paneID: pane)
        let terminal = try XCTUnwrap(model.terminals[pane])
        defer { terminal.requestTermination(force: true); terminal.adapter.detach() }
        try await waitFor("READY", in: terminal)
        let input = try XCTUnwrap(terminal.view as? NSTextInputClient)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = terminal.view
        window.makeFirstResponder(terminal.view)

        // Enter commits the title; keys that reach the terminal during editing are dropped.
        await model.beginTabRename(tab.id)
        XCTAssertEqual(model.editingTabID, tab.id)
        XCTAssertEqual(model.tabRenameDraft, tab.title)
        input.insertText("NEVER_ENTER", replacementRange: noReplacement)
        terminal.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        model.tabRenameDraft = "Build"
        await model.finishTabRename(tab.id, draft: model.tabRenameDraft, action: .commit)
        XCTAssertNil(model.editingTabID)
        XCTAssertEqual(model.presentation.selectedTab?.title, "Build")

        // Escape cancels without changing the title or sending ESC to the PTY.
        await model.beginTabRename(tab.id)
        input.insertText("NEVER_ESCAPE", replacementRange: noReplacement)
        terminal.view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        model.tabRenameDraft = "Discarded"
        await model.finishTabRename(tab.id, draft: model.tabRenameDraft, action: .cancel)
        XCTAssertNil(model.editingTabID)
        XCTAssertEqual(model.presentation.selectedTab?.title, "Build")

        // Terminal input resumes after editing; only the later line reaches cat.
        input.insertText("AFTER\r", replacementRange: noReplacement)
        try await waitFor("AFTER", in: terminal)
        let output = try terminal.adapter.read(.retainedText)
        XCTAssertFalse(output.contains("NEVER"), output)
        XCTAssertFalse(output.contains("\u{1b}"), output)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testConflictingShortcutsAreNotSavedAndPreviousMapStaysActive() throws {
        _ = NSApplication.shared
        let suite = "trellis.tests.keyboard.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences)
        var rebuilt = 0
        model.onKeyboardSettingsChanged = { rebuilt += 1 }
        XCTAssertEqual(model.keyboard, KeyboardSettings())

        var conflicting = model.keyboard
        conflicting.shortcuts = conflicting.shortcuts.assigning(KeyChord("d"), to: .newTab)
        XCTAssertEqual(model.saveKeyboardSettings(conflicting), [.conflict(KeyChord("d"), [.newTab, .splitLeftRight])])
        XCTAssertEqual(model.keyboard, KeyboardSettings())
        XCTAssertNil(preferences.data(forKey: "keyboard.settings"))
        XCTAssertEqual(rebuilt, 0)

        var valid = model.keyboard
        valid.optionAsMeta = true
        valid.shortcuts = valid.shortcuts.assigning(KeyChord("r", [.command, .shift]), to: .renameTab)
        XCTAssertEqual(model.saveKeyboardSettings(valid), [])
        XCTAssertEqual(model.keyboard, valid)
        XCTAssertEqual(rebuilt, 1)
        XCTAssertEqual(AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences).keyboard, valid)

        // A conflicting stored map (edited externally) is never applied.
        var stored = KeyboardSettings()
        stored.shortcuts = stored.shortcuts.assigning(KeyChord("t"), to: .closePane)
        preferences.set(try JSONEncoder().encode(stored), forKey: "keyboard.settings")
        let reloaded = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences)
        XCTAssertEqual(reloaded.keyboard.shortcuts, .defaults)
        XCTAssertNotNil(reloaded.keyboardNotice)
    }

    @MainActor
    func testSettingsReachLiveTerminalsAndReduceMotionStopsBlinking() async throws {
        _ = NSApplication.shared
        let suite = "trellis.tests.keyboard.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences)
        await model.createWindow(startSession: false)
        let terminal = try XCTUnwrap(model.activeTerminal)
        defer { terminal.adapter.detach() }
        XCTAssertFalse(terminal.optionAsMeta)
        var settings = model.keyboard
        settings.optionAsMeta = true
        settings.shortcuts = settings.shortcuts.assigning(KeyChord("e", [.command, .shift]), to: .findInPane)
        model.saveKeyboardSettings(settings)
        XCTAssertTrue(terminal.optionAsMeta)
        XCTAssertEqual(terminal.searchShortcut, KeyChord("e", [.command, .shift]))

        var appearance = model.appearance
        appearance.cursorBlinks = true
        XCTAssertTrue(model.applyAppearance(appearance))
        XCTAssertTrue(model.terminalAppearance.cursorBlinks)
        model.accessibilityDisplayOptionsDidChange(increaseContrast: true, reduceMotion: true)
        XCTAssertFalse(model.terminalAppearance.cursorBlinks)
        XCTAssertTrue(model.appearance.cursorBlinks, "Reduce Motion must not rewrite the saved preference")
        XCTAssertTrue(model.increaseContrast)

        // VoiceOver hears the pane name and a word status, not a color.
        await model.refresh()
        XCTAssertEqual(terminal.view.accessibilityLabel(), "Terminal pane 1, Stopped")
    }

    @MainActor
    private func waitFor(_ text: String, in terminal: NativeTerminal) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(try terminal.adapter.read(.retainedText)).contains(text), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(try terminal.adapter.read(.retainedText).contains(text))
    }
}
