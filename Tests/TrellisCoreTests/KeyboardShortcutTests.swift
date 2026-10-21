import XCTest
@testable import TrellisCore

final class KeyboardShortcutTests: XCTestCase {
    func testRejectShortcutCollision() throws {
        let previous = ShortcutMap.defaults
        XCTAssertThrowsError(try previous.binding(.newTab, to: KeyChord("d"))) { error in
            XCTAssertEqual(error as? ShortcutIssue, .conflict(KeyChord("d"), [.newTab, .splitLeftRight]))
            let message = (error as? ShortcutIssue)?.description ?? ""
            XCTAssertTrue(message.contains("New Tab") && message.contains("Split Left/Right"), message)
        }
        XCTAssertEqual(previous, ShortcutMap.defaults)
        XCTAssertEqual(previous[.newTab], KeyChord("t"))

        // A draft may conflict while editing; validation names both actions once.
        let draft = previous.assigning(KeyChord("d"), to: .newTab)
        XCTAssertEqual(draft.issues(), [.conflict(KeyChord("d"), [.newTab, .splitLeftRight])])
        // Swapping in two steps resolves the conflict.
        let swapped = draft.assigning(KeyChord("t"), to: .splitLeftRight)
        XCTAssertEqual(swapped.issues(), [])
    }

    func testDefaultsMatchSpecificationAndAreConflictFree() {
        let map = ShortcutMap.defaults
        XCTAssertEqual(map.issues(), [])
        XCTAssertEqual(map[.newWindow], KeyChord("n"))
        XCTAssertEqual(map[.newTab], KeyChord("t"))
        XCTAssertEqual(map[.closePane], KeyChord("w"))
        XCTAssertEqual(map[.closeTab], KeyChord("w", [.command, .shift]))
        XCTAssertEqual(map[.splitLeftRight], KeyChord("d"))
        XCTAssertEqual(map[.toggleSidebar], KeyChord("s", [.command, .control]))
        XCTAssertEqual(ShortcutAction.toggleSidebar.menu, .view)
        XCTAssertEqual(map[.splitTopBottom], KeyChord("d", [.command, .shift]))
        XCTAssertEqual(map[.findInPane], KeyChord("f"))
        XCTAssertEqual(map[.focusLeft], KeyChord("left", [.command, .option]))
        for (index, action) in ShortcutAction.allCases.filter({ $0.tabIndex != nil }).enumerated() {
            XCTAssertEqual(map[action], KeyChord("\(index + 1)"))
            XCTAssertEqual(action.title, "Select Tab \(index + 1)")
        }
        XCTAssertEqual(KeyChord("d", [.command, .shift]).description, "⇧⌘D")
        XCTAssertEqual(KeyChord("left", [.command, .option, .control]).description, "⌃⌥⌘←")
    }

    func testTerminalControlAndNativeEditingChordsAreProtected() {
        let map = ShortcutMap.defaults
        XCTAssertThrowsError(try map.binding(.newTab, to: KeyChord("c", [.control]))) {
            XCTAssertEqual($0 as? ShortcutIssue, .requiresCommand(KeyChord("c", [.control]), .newTab))
        }
        XCTAssertThrowsError(try map.binding(.newTab, to: KeyChord("v"))) {
            XCTAssertEqual($0 as? ShortcutIssue, .reserved(KeyChord("v"), .newTab, reservedFor: "Paste"))
        }
        XCTAssertThrowsError(try map.binding(.newTab, to: KeyChord("bogus"))) {
            XCTAssertEqual($0 as? ShortcutIssue, .unsupportedKey(KeyChord("bogus"), .newTab))
        }
        // Clearing is explicit and leaves the command available from its menu.
        XCTAssertNil(try map.binding(.splitTopBottom, to: nil)[.splitTopBottom])
    }

    func testKeyboardSettingsStoreOnlyOverridesAndIgnoreUnknownActions() throws {
        var settings = KeyboardSettings()
        XCTAssertFalse(settings.optionAsMeta)
        settings.optionAsMeta = true
        settings.shortcuts = settings.shortcuts.assigning(KeyChord("k", [.command, .shift]), to: .renameTab).assigning(nil, to: .splitTopBottom)
        let data = try JSONEncoder().encode(settings)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["overrides"] as? [String: Any])?.keys.sorted(), ["renameTab", "splitTopBottom"])
        XCTAssertEqual(try JSONDecoder().decode(KeyboardSettings.self, from: data), settings)

        let future = Data(#"{"optionAsMeta":false,"overrides":{"teleport":{"chord":{"key":"p","modifiers":1}}}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardSettings.self, from: future), KeyboardSettings())
    }

    func testANewDefaultYieldsToAChordTheUserAlreadyChose() throws {
        // Saved before ⌘↑ became Previous Prompt: the user's choice wins and the new action starts unbound.
        var saved = KeyboardSettings()
        saved.shortcuts = saved.shortcuts.assigning(KeyChord("up"), to: .focusUp).assigning(nil, to: .previousPrompt)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var overrides = try XCTUnwrap(json["overrides"] as? [String: Any])
        overrides.removeValue(forKey: "previousPrompt")
        json["overrides"] = overrides
        let loaded = try JSONDecoder().decode(KeyboardSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(loaded.shortcuts[.focusUp], KeyChord("up"))
        XCTAssertNil(loaded.shortcuts[.previousPrompt])
        XCTAssertEqual(loaded.shortcuts[.nextPrompt], KeyChord("down"))
        XCTAssertTrue(loaded.shortcuts.issues().isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardSettings.self, from: JSONEncoder().encode(loaded)), loaded)
    }

    func testToggleSidebarDefaultYieldsToASavedControlCommandS() throws {
        // Saved before ⌃⌘S became Toggle Sidebar: the map must still load instead of falling back to defaults.
        let data = Data(#"{"optionAsMeta":false,"overrides":{"saveWorkspace":{"chord":{"key":"s","modifiers":9}}}}"#.utf8)
        let loaded = try JSONDecoder().decode(KeyboardSettings.self, from: data)
        XCTAssertEqual(loaded.shortcuts[.saveWorkspace], KeyChord("s", [.command, .control]))
        XCTAssertNil(loaded.shortcuts[.toggleSidebar])
        XCTAssertTrue(loaded.shortcuts.issues().isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardSettings.self, from: Data(#"{"optionAsMeta":false,"overrides":{}}"#.utf8)).shortcuts[.toggleSidebar], KeyChord("s", [.command, .control]))
    }

    func testClearDefaultsToCommandKAndYieldsToASavedChord() throws {
        XCTAssertEqual(ShortcutMap.defaults[.clearPane], KeyChord("k"))
        XCTAssertEqual(ShortcutAction.clearPane.menu, .edit)
        XCTAssertTrue(ShortcutMap.defaults.issues().isEmpty)
        // Saved before ⌘K became Clear: the user's choice wins and Clear starts unbound.
        let data = Data(#"{"optionAsMeta":false,"overrides":{"renameTab":{"chord":{"key":"k","modifiers":1}}}}"#.utf8)
        let loaded = try JSONDecoder().decode(KeyboardSettings.self, from: data)
        XCTAssertEqual(loaded.shortcuts[.renameTab], KeyChord("k"))
        XCTAssertNil(loaded.shortcuts[.clearPane])
        XCTAssertTrue(loaded.shortcuts.issues().isEmpty)
    }

    func testOpenWorkspaceFileDefaultsToCommandOAndYieldsToASavedChord() throws {
        XCTAssertEqual(ShortcutMap.defaults[.openProjectFile], KeyChord("o"))
        XCTAssertEqual(ShortcutAction.openProjectFile.menu, .file)
        XCTAssertEqual(ShortcutAction.openProjectFile.title, "Open Project…")
        // Saved before ⌘O opened workspace files (FR-WF04): the user's choice wins.
        let data = Data(#"{"optionAsMeta":false,"overrides":{"showHosts":{"chord":{"key":"o","modifiers":1}}}}"#.utf8)
        let loaded = try JSONDecoder().decode(KeyboardSettings.self, from: data)
        XCTAssertEqual(loaded.shortcuts[.showHosts], KeyChord("o"))
        XCTAssertNil(loaded.shortcuts[.openProjectFile])
        XCTAssertTrue(loaded.shortcuts.issues().isEmpty)
        // Rebound before the rename to projects: the old raw value still decodes.
        let renamed = Data(#"{"optionAsMeta":false,"overrides":{"openWorkspaceFile":{"chord":{"key":"p","modifiers":1}}}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardSettings.self, from: renamed).shortcuts[.openProjectFile], KeyChord("p"))
    }

    func testAccessibilityStateReflectsSelection() throws {
        let windowA = UUID(), windowB = UUID(), tab1 = UUID(), tab2 = UUID(), tabB = UUID()
        let paneLeft = UUID(), paneRight = UUID(), paneOther = UUID(), paneB = UUID()
        let sessions = (0..<4).map { _ in UUID() }
        var snapshot = WorkspaceSnapshot()
        snapshot.windows = [
            ManagedWindow(id: windowA, name: "Project", tabIDs: [tab1, tab2], activeTabID: tab1),
            ManagedWindow(id: windowB, name: "Operations", tabIDs: [tabB], activeTabID: tabB)
        ]
        snapshot.activeWindowID = windowA
        snapshot.tabs = [
            tab1: WorkspaceTab(
                id: tab1, windowID: windowA, title: "Build",
                root: .split(id: UUID(), axis: .x, ratio: 0.5, children: [.pane(paneLeft), .pane(paneRight)]), activePaneID: paneRight),
            tab2: WorkspaceTab(id: tab2, windowID: windowA, title: "Logs", root: .pane(paneOther), activePaneID: paneOther),
            tabB: WorkspaceTab(id: tabB, windowID: windowB, title: "SSH", root: .pane(paneB), activePaneID: paneB)
        ]
        for (pane, (tab, session)) in zip([paneLeft, paneRight, paneOther, paneB], zip([tab1, tab1, tab2, tabB], sessions)) {
            snapshot.panes[pane] = WorkspacePane(id: pane, tabID: tab, sessionID: session, title: pane == paneLeft ? "Server" : nil)
            snapshot.sessions[session] = WorkspaceSession(id: session)
        }
        let projection = WorkspaceAccessibility(
            snapshot: snapshot,
            live: [paneLeft: .init(state: .running), paneRight: .init(state: .exited, exitCode: 7)],
            windowsWithOutput: [windowB], windowsWithExit: [])

        XCTAssertEqual(projection.windows.map(\.label), ["Window Project", "Window Operations"])
        XCTAssertEqual(projection.windows.map(\.isSelected), [true, false])
        XCTAssertEqual(projection.windows.map(\.value), ["2 tabs", "1 tab, new output"])
        XCTAssertEqual(projection.tabs.map(\.label), ["Tab Build", "Tab Logs"])
        XCTAssertEqual(projection.tabs.map(\.value), ["1 of 2", "2 of 2"])
        XCTAssertEqual(projection.tabs.map(\.isSelected), [true, false])
        XCTAssertEqual(projection.panes.map(\.label), ["Terminal Server", "Terminal pane 2"])
        XCTAssertEqual(projection.panes.map(\.isSelected), [false, true])
        // Exit is described in words; nothing depends on the status color.
        XCTAssertEqual(projection.panes.map(\.value), ["Running", "Exited (7), focused"])
        XCTAssertEqual(projection.status, "Exited (7)")

        let stored = WorkspaceAccessibility(snapshot: snapshot, windowsWithExit: [windowB])
        XCTAssertEqual(stored.status, "Stopped")
        XCTAssertEqual(stored.windows[1].value, "1 tab, a session exited")
        XCTAssertEqual(SessionStatusText.describe(.failed, exitCode: nil), "Failed to start")
        XCTAssertEqual(WorkspaceAccessibility(snapshot: WorkspaceSnapshot()).status, "No session")
    }
}
