import Foundation
import XCTest
@testable import TrellisCore

final class ProductRenameTests: XCTestCase {
    func testLegacyThemesUsingNewReservedPrefixKeepColorsAndSelections() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("trellis-rename-\(UUID())")
        defer { try? files.removeItem(at: root) }
        let legacy = root.appendingPathComponent("dev.uterm.feasibility")
        let themes = legacy.appendingPathComponent("Themes")
        try files.createDirectory(at: themes, withIntermediateDirectories: true)
        var expected: [ThemeDocument] = []
        for (example, id) in [(ThemeExample.light, "trellis-light"), (.dark, "trellis-night")] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ThemeExamples.data(example)) as? [String: Any])
            object["id"] = id
            let data = try JSONSerialization.data(withJSONObject: object)
            expected.append(try ThemeValidator.validate(data))
            try data.write(to: themes.appendingPathComponent(id + ".theme.json"))
        }
        var appearance = AppearanceSettings()
        appearance.lightThemeID = "trellis-light"; appearance.darkThemeID = "trellis-night"
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(WorkspaceSettings(appearance: appearance))) as? [String: Any])
        let workspace = try JSONSerialization.data(withJSONObject: ["settings": settings])
        for name in ["workspace.json", "workspace.backup.json"] { try workspace.write(to: legacy.appendingPathComponent(name)) }
        let destination = try ApplicationSupportLocation.prepare(root: root, bundleIdentifier: "com.bearstouch.trellis")
        let catalog = await ThemeLibrary(directory: destination.appendingPathComponent("Themes")).reload()
        XCTAssertTrue(catalog.issues.isEmpty)
        XCTAssertEqual(catalog.documents.count, 2)
        for name in ["workspace.json", "workspace.backup.json"] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent(name))) as? [String: Any])
            let restored = try JSONDecoder().decode(WorkspaceSettings.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(object["settings"])))
            let light = try XCTUnwrap(catalog.documents[restored.appearance.lightThemeID])
            let dark = try XCTUnwrap(catalog.documents[restored.appearance.darkThemeID])
            for (migrated, original) in zip([light, dark], expected) {
                XCTAssertEqual(migrated.name, original.name)
                XCTAssertEqual(migrated.terminal, original.terminal)
                XCTAssertEqual(migrated.ui, original.ui)
            }
        }
        XCTAssertTrue(files.fileExists(atPath: themes.appendingPathComponent("trellis-light.theme.json").path))
    }
    func testMigrationCopiesWorkspaceAndThemesWithoutChangingLegacyData() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("trellis-rename-\(UUID())")
        defer { try? files.removeItem(at: root) }
        let legacy = root.appendingPathComponent("dev.uterm.feasibility")
        try files.createDirectory(at: legacy.appendingPathComponent("Themes"), withIntermediateDirectories: true)
        let workspace = Data("saved workspace".utf8), theme = Data("custom theme".utf8)
        try workspace.write(to: legacy.appendingPathComponent("workspace.json"))
        try theme.write(to: legacy.appendingPathComponent("Themes/custom.theme.json"))
        let destination = try ApplicationSupportLocation.prepare(root: root, bundleIdentifier: "com.bearstouch.trellis")
        XCTAssertEqual(destination.lastPathComponent, "com.bearstouch.trellis")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("workspace.json")), workspace)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Themes/custom.theme.json")), theme)
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("workspace.json")), workspace)
        let updated = Data("new Trellis workspace".utf8)
        try updated.write(to: destination.appendingPathComponent("workspace.json"))
        _ = try ApplicationSupportLocation.prepare(root: root, bundleIdentifier: "com.bearstouch.trellis")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("workspace.json")), updated)
    }

    func testOtherBundleIdentityKeepsIndependentState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-rename-\(UUID())")
        let destination = try ApplicationSupportLocation.prepare(root: root, bundleIdentifier: "com.bearstouch.trellis.review")
        XCTAssertEqual(destination, root.appendingPathComponent("com.bearstouch.trellis.review", isDirectory: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPreviousBundleIdentityDataMovesToBearstouchIdentityUnchanged() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("trellis-rename-\(UUID())")
        defer { try? files.removeItem(at: root) }
        let previous = root.appendingPathComponent("dev.trellis"), uterm = root.appendingPathComponent("dev.uterm")
        try files.createDirectory(at: previous.appendingPathComponent("Themes"), withIntermediateDirectories: true)
        try files.createDirectory(at: uterm, withIntermediateDirectories: true)
        let workspace = Data("dev.trellis workspace".utf8), theme = Data("custom theme".utf8)
        try workspace.write(to: previous.appendingPathComponent("workspace.json"))
        try theme.write(to: previous.appendingPathComponent("Themes/trellis-mine.theme.json"))
        try Data("older uterm workspace".utf8).write(to: uterm.appendingPathComponent("workspace.json"))
        for name in ["control.json", "broker.json"] { try Data("{}".utf8).write(to: previous.appendingPathComponent(name)) }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: previous.path)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous.appendingPathComponent("workspace.json").path)
        let destination = try ApplicationSupportLocation.prepare(root: root, bundleIdentifier: "com.bearstouch.trellis")
        XCTAssertFalse(files.fileExists(atPath: destination.appendingPathComponent("control.json").path), "Another instance's control discovery is not adopted")
        XCTAssertTrue(files.fileExists(atPath: destination.appendingPathComponent("broker.json").path), "Kept sessions stay reachable")
        XCTAssertTrue(files.fileExists(atPath: previous.appendingPathComponent("control.json").path))
        XCTAssertEqual(try files.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try files.attributesOfItem(atPath: destination.appendingPathComponent("workspace.json").path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(destination.lastPathComponent, "com.bearstouch.trellis")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("workspace.json")), workspace)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Themes/trellis-mine.theme.json")), theme)
        XCTAssertEqual(try Data(contentsOf: previous.appendingPathComponent("workspace.json")), workspace)
    }

    func testDevelopmentIdentityDoesNotMigratePreviousDevelopmentData() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("trellis-rename-\(UUID())")
        defer { try? files.removeItem(at: root) }
        try files.createDirectory(at: root.appendingPathComponent("dev.trellis"), withIntermediateDirectories: true)
        try Data("installed".utf8).write(to: root.appendingPathComponent("dev.trellis/workspace.json"))
        let destination = try ApplicationSupportLocation.prepare(root: root, bundleIdentifier: AppInstanceIdentity.development)
        XCTAssertFalse(files.fileExists(atPath: destination.appendingPathComponent("workspace.json").path))
    }

    func testPreviousPreferencesImportOnceWithoutOverwritingCurrentValues() throws {
        let suite = "trellis-rename-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/bin/fish", forKey: "terminal.shell")
        ApplicationSupportLocation.migratePreferences(into: defaults, legacy: ["terminal.shell": "/bin/zsh", "sidebar.collapsed": true])
        XCTAssertEqual(defaults.string(forKey: "terminal.shell"), "/bin/fish")
        XCTAssertTrue(defaults.bool(forKey: "sidebar.collapsed"))
        defaults.set(false, forKey: "sidebar.collapsed")
        ApplicationSupportLocation.migratePreferences(into: defaults, legacy: ["sidebar.collapsed": true, "terminal.directory": "/tmp"])
        XCTAssertFalse(defaults.bool(forKey: "sidebar.collapsed"))
        XCTAssertNil(defaults.string(forKey: "terminal.directory"))
    }

    func testSavedBuiltInIDsMigrateWhileCustomChoiceIsPreserved() throws {
        var appearance = AppearanceSettings()
        appearance.lightThemeID = "uterm-light"
        appearance.darkThemeID = "uterm-dark"
        let settings = WorkspaceSettings(appearance: appearance)
        let restored = try JSONDecoder().decode(WorkspaceSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.appearance.lightThemeID, "trellis-light")
        XCTAssertEqual(restored.appearance.darkThemeID, "trellis-dark")
        appearance.darkThemeID = "my-dark"
        let custom = try JSONDecoder().decode(
            WorkspaceSettings.self,
            from: JSONEncoder().encode(WorkspaceSettings(appearance: appearance)))
        XCTAssertEqual(custom.appearance.darkThemeID, "my-dark")
    }
}
