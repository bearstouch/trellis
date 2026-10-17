import AppKit
import XCTest
import TrellisControl
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

final class ThemeAutomationTests: XCTestCase {
    private var themes: URL!

    override func setUpWithError() throws {
        themes = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-themes-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: themes) }

    private func theme(_ id: String, appearance: String = "dark", background: String = "#101820") -> [String: Any] {
        ["version": 1, "id": id, "name": "Theme \(id)", "appearance": appearance, "terminal": ["background": background, "foreground": "#E8EEF4"]]
    }

    @MainActor
    func testThemePermissionMatrix() async throws {
        let h = try Harness(themeDirectory: themes)
        defer { h.discardPreferences() }
        try await h.grant("full")
        let window: String = try await h.value("windowId", "window.create", ["name": "W"])
        try await h.grant("read", [.themeRead])
        try await h.grant("layout", [.metadataRead, .layoutWrite])
        try await h.grant("scoped", [.themeRead, .themeWrite], scope: .windows([UUID(uuidString: window)!]))
        try await h.grant("global", [.themeRead, .themeWrite])
        let reads: [(String, [String: Any])] = [
            ("theme.list", [:]), ("theme.get", ["id": "trellis-dark"]), ("theme.validate", ["document": theme("probe")]),
            ("theme.export", ["id": "trellis-light"]), ("appearance.get", [:])
        ]
        let writes: [(String, [String: Any])] = [
            ("theme.import", ["document": theme("granted")]), ("appearance.set", ["mode": "dark"]), ("theme.delete", ["id": "granted"])
        ]
        for (grant, readExpect, writeExpect) in [("read", "OK", "PERMISSION_DENIED"), ("layout", "PERMISSION_DENIED", "PERMISSION_DENIED"), ("scoped", "OK", "PERMISSION_DENIED"), ("global", "OK", "OK")] {
            for (method, params) in reads {
                let code = try await h.code(method, params, as: grant)
                XCTAssertEqual(code, readExpect, "\(grant) \(method)")
            }
            for (method, params) in writes {
                let code = try await h.code(method, params, as: grant)
                XCTAssertEqual(code, writeExpect, "\(grant) \(method)")
            }
        }
        XCTAssertEqual(h.model.appearance.chromeMode, .dark, "Only the global grant changed appearance")
    }

    @MainActor
    func testRejectWrongAppearanceSlot() async throws {
        let h = try Harness(themeDirectory: themes)
        defer { h.discardPreferences() }
        try await h.grant("full")
        _ = try result(try await h.call("theme.import", ["document": theme("lit", appearance: "light", background: "#FFFFFF")]))
        let before = h.model.appearance, revision = h.model.appearanceRevision
        for params in [["lightThemeId": "trellis-dark"], ["darkThemeId": "lit"], ["mode": "light", "lightThemeId": "trellis-light", "darkThemeId": "trellis-light"]] as [[String: Any]] {
            let response = try await h.call("appearance.set", params)
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602, "\(params)")
        }
        let missing = try await h.code("appearance.set", ["darkThemeId": "missing-theme"])
        XCTAssertEqual(missing, "NOT_FOUND")
        XCTAssertEqual(h.model.appearance, before, "All appearance settings are preserved")
        XCTAssertEqual(h.model.appearanceRevision, revision)
        let set = try result(try await h.call("appearance.set", ["mode": "light", "lightThemeId": "lit", "expectedRevision": Int(revision)]))
        XCTAssertEqual(set["lightThemeId"] as? String, "lit")
        XCTAssertEqual(set["effectiveThemeId"] as? String, "lit")
    }

    @MainActor
    func testProtectBuiltInsAndRevision() async throws {
        let h = try Harness(themeDirectory: themes)
        defer { h.discardPreferences() }
        try await h.grant("full")
        for replace in [false, true] {
            let code = try await h.code("theme.import", ["document": theme("trellis-dark"), "replace": replace])
            XCTAssertNotEqual(code, "OK", "Built-ins can never be replaced (replace: \(replace))")
        }
        let deleteBuiltIn = try await h.code("theme.delete", ["id": "trellis-light"])
        XCTAssertEqual(deleteBuiltIn, "INVALID_STATE")
        _ = try result(try await h.call("theme.import", ["document": theme("mine")]))
        let duplicate = try await h.code("theme.import", ["document": theme("mine", background: "#202020")])
        XCTAssertEqual(duplicate, "CONFLICT")
        let replaced = try await h.code("theme.import", ["document": theme("mine", background: "#202020"), "replace": true])
        XCTAssertEqual(replaced, "OK")
        let exported = try result(try await h.call("theme.export", ["id": "mine"]))
        XCTAssertEqual(((exported["document"] as? [String: Any])?["terminal"] as? [String: Any])?["background"] as? String, "#202020")

        let before = h.model.appearance
        let revision = h.model.appearanceRevision
        // Dark is the default, so switching to light is a real change that bumps the revision.
        _ = try result(try await h.call("appearance.set", ["mode": "light"]))
        let stale = try await h.call("appearance.set", ["mode": "dark", "expectedRevision": Int(revision)])
        XCTAssertEqual(errorCode(stale), "CONFLICT")
        XCTAssertEqual(h.model.appearance.chromeMode, .light, "A stale revision changes nothing")
        XCTAssertNotEqual(h.model.appearance, before)
        let invalid = try await h.call("theme.validate", ["document": ["version": 1, "id": "Bad ID", "name": "x", "appearance": "dark"]])
        XCTAssertEqual(try result(invalid)["valid"] as? Bool, false)
        // Raw text reaches the same validator as file import, including duplicate keys.
        let duplicateKeys = try await h.call("theme.validate", ["documentText": #"{"version":1,"id":"dup","id":"dup2","name":"D","appearance":"dark"}"#])
        XCTAssertEqual(try result(duplicateKeys)["valid"] as? Bool, false)
        let rejected = try await h.code("theme.import", ["documentText": #"{"version":1,"id":"dup","id":"dup2","name":"D","appearance":"dark"}"#])
        XCTAssertNotEqual(rejected, "OK")
        let library = try FileManager.default.contentsOfDirectory(atPath: themes.path).filter { $0.hasSuffix(".theme.json") }
        XCTAssertEqual(library, ["mine.theme.json"], "Failed operations wrote nothing")
    }

    @MainActor
    func testAppearanceSetKeepsTextRenderingSettings() async throws {
        let h = try Harness(themeDirectory: themes)
        defer { h.discardPreferences() }
        try await h.grant("full")
        var settings = h.model.appearance
        settings.fontLigatures = false; settings.boldAsBright = false; settings.allowBoldFont = false
        settings.allowItalicFont = false; settings.blinkingText = false
        XCTAssertTrue(h.model.applyAppearance(settings))
        _ = try result(try await h.call("appearance.set", ["mode": "dark"]))
        var expected = settings
        expected.chromeMode = .dark
        XCTAssertEqual(h.model.appearance, expected, "appearance.set changes only the mode and theme slots")
    }

    @MainActor
    func testAppearanceEventHasNoProcessEffects() async throws {
        let h = try Harness(themeDirectory: themes)
        defer {
            h.model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }; h.discardPreferences()
        }
        try await h.grant("full")
        _ = try await h.code("window.create", ["name": "Live"])
        let pane = try XCTUnwrap(h.model.presentation.activePane?.id)
        _ = try await h.model.service.execute(
            .configureStoppedSession(paneID: pane, launch: .process(executable: "/bin/zsh", arguments: ["-f", "-c", AutomationSessionTests.byteEcho], directory: "/tmp")))
        await h.model.refresh()
        _ = try await h.code("session.start", ["paneId": pane.uuidString])
        let terminal = NativeTerminalHandle(try XCTUnwrap(h.model.terminals[pane]))
        try await terminal.waitFor("READY")
        let pid = terminal.native.processID, session = terminal.native.sessionID
        _ = try result(try await h.call("theme.import", ["document": theme("calm", background: "#0A0A14")]))
        var events: [String] = []
        h.model.onAppearanceChanged = { events.append(h.model.effectiveTheme.id) }
        h.model.previewThemeInWorkspace(try ThemeValidator.validate(JSONSerialization.data(withJSONObject: theme("peek"))))
        h.model.cancelThemePreview()
        XCTAssertEqual(events, [], "A preview is not a committed change")
        let revision = h.model.appearanceRevision
        let params: [String: Any] = ["mode": "dark", "darkThemeId": "calm", "idempotencyKey": "theme-1"]
        let first = try result(try await h.call("appearance.set", params))
        let retry = try result(try await h.call("appearance.set", params))
        XCTAssertEqual(first["revision"] as? Int, retry["revision"] as? Int, "The keyed retry replays the committed result")
        XCTAssertEqual(events, ["calm"], "One event per commit, after the effective theme settled; the retry committed nothing new")
        XCTAssertEqual(h.model.appearanceRevision, revision + 1)
        XCTAssertEqual(h.model.effectiveTheme.id, "calm")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(terminal.native.processID, pid)
        XCTAssertEqual(terminal.native.sessionID, session)
        XCTAssertEqual(terminal.native.sessionState, .running)
        XCTAssertEqual(try terminal.output().trimmingCharacters(in: .whitespacesAndNewlines), "READY", "No input reached the session")
    }
}
