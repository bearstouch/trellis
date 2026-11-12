import Foundation
import TrellisCore

/// Declarative layouts, themes and appearance (docs/api/methods.md#layouts-themes-and-appearance, docs/api/layouts.md).
/// A layout document's own contents decide some capabilities (a remote machine, a project, an agent pane); the adapter
/// checks those, since the catalog's conditions only read parameters.
extension MethodCatalogV2 {
    private static let document = ParamV2(
        "document", .object, required: true, "A layout document, version 3 (versions 1 and 2 are read as 3; a list named windows is refused).")
    private static let namespace = ParamV2(
        "namespace", .string(maxBytes: 64), required: true, "Keys bind to resources within this namespace (the layout key pattern, 1–64 characters).")
    private static let themeID = ParamV2("id", .string(maxBytes: 200), required: true, "The theme's ID.")
    private static let themeDocument = [
        ParamV2("document", .object, "A theme document as a JSON object."),
        ParamV2("documentText", .string(maxBytes: 1_000_000), "A theme document as JSON text, so duplicate keys are checked exactly.")
    ]

    static let layouts: [MethodSpecV2] = [
        MethodSpecV2(
            "layout.validate", "Check a layout document without changing anything: errors, warnings and the version it was read as.", params: [document],
            capabilities: [.workspaceRead], errors: [.unsupportedVersion]),
        MethodSpecV2(
            "layout.plan", "Preview the keyed changes a layout document would make in a namespace, with conflicts and the baseRevision to apply it with.",
            params: [namespace, document], capabilities: [.workspaceRead], errors: [.unsupportedVersion]),
        MethodSpecV2(
            "layout.apply",
            "Apply a planned layout document: matched keys update, new ones are created stopped, nothing is deleted; expectedRevision is the plan's baseRevision.",
            params: [namespace, document, ParamV2("startNew", .boolean, "Start the panes this apply creates (needs session.start).")],
            capabilities: [.workspaceWrite], conditional: [ConditionalCapabilityV2(.sessionStart, if: .present("startNew"))], allSpaces: true,
            effect: .mutating(revision: .container("workspace")), errors: [.invalidState, .unsupportedVersion]),
        MethodSpecV2(
            "layout.export", "Export spaces in scope as a version 3 layout document with fresh keys; launch details need session.execute and host.read.",
            params: [ParamV2("spaceIds", .uuidList(maxCount: 100), "The spaces to export; default every space in scope.")], capabilities: [.workspaceRead],
            resources: [ResourceRuleV2(.space, "spaceIds", list: true)])
    ]

    static let themes: [MethodSpecV2] = [
        MethodSpecV2("theme.list", "Installed themes, built-in first, with the slots they are selected for.", capabilities: [.themeRead], paginated: true),
        MethodSpecV2("theme.get", "One theme's resolved palette and contrast warnings.", params: [themeID], capabilities: [.themeRead], errors: [.notFound]),
        MethodSpecV2(
            "theme.validate", "Check a theme document with the app's validator, changing nothing.", params: themeDocument, capabilities: [.themeRead],
            rules: [.exactlyOne(["document", "documentText"])], errors: [.unsupportedVersion]),
        MethodSpecV2(
            "theme.import", "Install a theme document in the library; replace overwrites a custom theme with the same ID.",
            params: themeDocument + [ParamV2("replace", .boolean, "Replace an installed custom theme with the same ID.")], capabilities: [.themeWrite],
            rules: [.exactlyOne(["document", "documentText"])], allSpaces: true,
            effect: .mutating(revision: .exempt(reason: "The theme library has no revision; replace decides whether a theme is overwritten.")),
            errors: [.invalidState, .unsupportedVersion]),
        MethodSpecV2(
            "theme.export", "A theme's document, as written or with inherited values resolved.",
            params: [themeID, ParamV2("resolved", .boolean, "Include inherited values.")], capabilities: [.themeRead], errors: [.notFound]),
        MethodSpecV2(
            "theme.delete", "Delete a custom theme; built-in themes can't be deleted.", params: [themeID], capabilities: [.themeWrite], allSpaces: true,
            effect: .mutating(revision: .exempt(reason: "The theme library has no revision; a theme is named by its ID."), destructive: true),
            errors: [.notFound, .invalidState]),
        MethodSpecV2(
            "appearance.get", "The appearance mode, the light and dark themes, background settings and which renderer panes use.", capabilities: [.themeRead]),
        MethodSpecV2(
            "appearance.set", "Set the appearance mode and the light and dark themes for every space; expectedRevision is the appearance revision.",
            params: [
                ParamV2("mode", .string(values: ChromeMode.allCases.map(\.rawValue)), "system, dark or light."),
                ParamV2("lightThemeId", .string(maxBytes: 200), "A light theme's ID."), ParamV2("darkThemeId", .string(maxBytes: 200), "A dark theme's ID.")
            ], capabilities: [.themeWrite], rules: [.atLeastOne(["mode", "lightThemeId", "darkThemeId"])], allSpaces: true,
            effect: .mutating(revision: .container("appearance")), errors: [.notFound, .invalidState])
    ]
}
