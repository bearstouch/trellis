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
        let destination = try ApplicationSupportLocation.prepare(root: root, bundleIdentifier: "dev.trellis")
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
        let destination = try ApplicationSupportLocation.prepare(root: root, bundleIdentifier: "dev.trellis")
        XCTAssertEqual(destination.lastPathComponent, "dev.trellis")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("workspace.json")), workspace)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Themes/custom.theme.json")), theme)
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("workspace.json")), workspace)
        let updated = Data("new Trellis workspace".utf8)
        try updated.write(to: destination.appendingPathComponent("workspace.json"))
        _ = try ApplicationSupportLocation.prepare(root: root, bundleIdentifier: "dev.trellis")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("workspace.json")), updated)
    }

    func testOtherBundleIdentityKeepsIndependentState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-rename-\(UUID())")
        let destination = try ApplicationSupportLocation.prepare(root: root, bundleIdentifier: "dev.trellis.review")
        XCTAssertEqual(destination, root.appendingPathComponent("dev.trellis.review", isDirectory: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
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
