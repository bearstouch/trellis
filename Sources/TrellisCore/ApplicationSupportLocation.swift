import Foundation

/// Keeps existing installations usable after the product rename. Legacy names
/// appear only here and in saved-settings/environment compatibility handling.
public enum ApplicationSupportLocation {
    /// `isRunning` says whether an app with a legacy identifier is running now.
    public static func prepare(root: URL, bundleIdentifier: String?, isRunning: (String) -> Bool = { _ in false }) throws -> URL {
        let identifier = bundleIdentifier ?? AppInstanceIdentity.production
        let destination = root.appendingPathComponent(identifier, isDirectory: true)
        let files = FileManager.default
        guard identifier == AppInstanceIdentity.production, !files.fileExists(atPath: destination.path) else { return destination }
        // Newest identity first: `dev.trellis` data already went through the uTerm theme migration.
        let legacyIdentifiers =
            [AppInstanceIdentity.legacyProduction]
            + (bundleIdentifier == nil ? ["dev.uterm", "dev.uterm.feasibility"] : ["dev.uterm.feasibility", "dev.uterm"])
        for legacy in legacyIdentifiers {
            let source = root.appendingPathComponent(legacy, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard files.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let staging = root.appendingPathComponent(".trellis-migration-\(UUID().uuidString)", isDirectory: true)
            defer { try? files.removeItem(at: staging) }
            try files.copyItem(at: source, to: staging)
            // `control.json` names the copied-from instance's socket; if that app still runs, keeping it would
            // make this one refuse to serve automation (`anotherInstanceRunning`). Each instance publishes its own.
            try? files.removeItem(at: staging.appendingPathComponent("control.json"))
            // `broker.json` likewise names its session broker, which keeps serving that app while it runs: sharing it
            // would leave this one unable to keep sessions running. After it quits, the copy reattaches its kept sessions.
            if isRunning(legacy) { try? files.removeItem(at: staging.appendingPathComponent("broker.json")) }
            if legacy != AppInstanceIdentity.legacyProduction { try migrateConflictingThemes(in: staging) }
            try files.moveItem(at: staging, to: destination)
            break
        }
        return destination
    }

    /// Copies the previous identity's preferences (keyboard, shell, window frame…) once, when the
    /// current domain has none. The legacy domain is left untouched.
    public static func migratePreferences(into defaults: UserDefaults, legacy: [String: Any]?) {
        guard let legacy, !legacy.isEmpty, defaults.object(forKey: preferencesMigratedKey) == nil else { return }
        defaults.set(true, forKey: preferencesMigratedKey)
        for (key, value) in legacy where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
    }
    static let preferencesMigratedKey = "migration.legacyPreferencesImported"

    private static func migrateConflictingThemes(in directory: URL) throws {
        let files = FileManager.default
        let themes = directory.appendingPathComponent("Themes")
        guard files.fileExists(atPath: themes.path) else { return }
        var renamed: [String: String] = [:]
        for file in try files.contentsOfDirectory(at: themes, includingPropertiesForKeys: nil) {
            guard file.lastPathComponent.hasSuffix(".theme.json"),
                let document = try? ThemeValidator.validate(DiskThemeLibraryFiles().read(file)),
                file.lastPathComponent == document.id + ".theme.json", document.hasReservedID
            else { continue }
            // A theme authored before the rename may use the new reserved prefix.
            // Change only its ID; the original library remains untouched.
            var id: String
            repeat { id = "imported-" + UUID().uuidString.lowercased() } while files.fileExists(atPath: themes.appendingPathComponent(id + ".theme.json").path)
            guard var object = try JSONSerialization.jsonObject(with: document.encoded()) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            object["id"] = id
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            _ = try ThemeValidator.validate(data)
            try data.write(to: themes.appendingPathComponent(id + ".theme.json"), options: .atomic)
            try files.removeItem(at: file)
            renamed[document.id] = id
        }
        guard !renamed.isEmpty else { return }
        for filename in ["workspace.json", "workspace.backup.json"] {
            let file = directory.appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: file), data.count <= 4_194_304,
                var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                var settings = object["settings"] as? [String: Any],
                var appearance = settings["appearance"] as? [String: Any]
            else { continue }
            for key in ["lightThemeID", "darkThemeID"] {
                if let oldID = appearance[key] as? String, let newID = renamed[oldID] { appearance[key] = newID }
            }
            settings["appearance"] = appearance
            object["settings"] = settings
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
        }
    }
}
