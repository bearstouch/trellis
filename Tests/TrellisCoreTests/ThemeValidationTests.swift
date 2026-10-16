import XCTest
@testable import TrellisCore

final class ThemeValidationTests: XCTestCase {
    private let minimal = ##"{"version":1,"id":"sample","name":"Sample","appearance":"light"}"##
    func testS015_UT01_minimalThemeInheritsDefaults() throws {
        let document = try ThemeValidator.validate(ThemeExamples.data(.minimal))
        let resolved = document.resolved(), base = ResolvedTheme.builtIn(.dark)
        XCTAssertEqual(resolved.terminal.background, 0x101820)
        XCTAssertEqual(resolved.terminal.foreground, 0xE8EEF4)
        XCTAssertEqual(resolved.terminal.ansi, base.terminal.ansi)
        XCTAssertEqual(resolved.terminal.cursorText, base.terminal.cursorText)
        XCTAssertEqual(resolved[.accent].rgb, 0x7CC7FF)
        XCTAssertEqual(resolved[.sidebarBackground], base[.sidebarBackground])
        let empty = try ThemeValidator.validate(Data(minimal.utf8)).resolved()
        XCTAssertEqual(empty.terminal, TerminalPalette.builtIn)
        XCTAssertEqual(empty[.sidebarBackground], ResolvedTheme.builtIn(.light)[.sidebarBackground])
        let lightTerminal = minimal.dropLast() + ",\"terminal\":{\"background\":\"#FFFFFF\",\"foreground\":\"#123456\"}}"
        XCTAssertEqual(try ThemeValidator.validate(Data(lightTerminal.utf8)).resolved().terminal.background, 0xFFFFFF)
    }
    func testS015_UT02_rejectMalformedThemeVariants() throws {
        let extra = { (field: String) in self.minimal.dropLast() + "," + field + "}" }
        let variants: [(String, String, ThemeValidationError.Code)] = [
            ("{", "$", .malformedJSON), (minimal + "x", "$", .malformedJSON),
            (String(extra(##""id":"duplicate""##)), "$.id", .duplicateKey),
            (String(extra(##""\u0069d":"duplicate""##)), "$.id", .duplicateKey),
            (String(extra(##""ui":{"accent":"#123456","accent":"#654321"}"##)), "$.ui.accent", .duplicateKey),
            (String(extra(##""font":"Monaco""##)), "$.font", .unknownField),
            (String(extra(##""script":"echo danger""##)), "$.script", .unknownField),
            (String(extra(##""ui":{"include":"https://example.com"}"##)), "$.ui.include", .unknownField),
            (String(extra(##""terminal":{"background":"#12345"}"##)), "$.terminal.background", .invalidColor),
            (String(extra(##""terminal":{"background":"#FFFFFFFF"}"##)), "$.terminal.background", .invalidColor),
            (String(extra(##""terminal":{"cursor":true}"##)), "$.terminal.cursor", .wrongType),
            (String(extra(##""terminal":null"##)), "$.terminal", .wrongType),
            (String(extra(##""ui":[]"##)), "$.ui", .wrongType),
            (minimal.replacingOccurrences(of: "\"version\":1", with: "\"version\":true"), "$.version", .wrongType),
            (minimal.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"), "$.version", .unsupportedVersion),
            (minimal.replacingOccurrences(of: "\"version\":1", with: "\"version\":1.000000000000000000000000001"), "$.version", .unsupportedVersion),
            (minimal.replacingOccurrences(of: "sample", with: "../sample"), "$.id", .invalidID),
            (minimal.replacingOccurrences(of: "sample", with: "Sample"), "$.id", .invalidID),
            (minimal.replacingOccurrences(of: "Sample", with: String(repeating: "a", count: 101)), "$.name", .invalidName),
            (minimal.replacingOccurrences(of: "light", with: "system"), "$.appearance", .invalidAppearance),
            (##"{"id":"test","name":"Test","appearance":"dark"}"##, "$.version", .missingField),
            (String(extra(##""terminal":{"ansi":null}"##)), "$.terminal.ansi", .wrongType)
        ]
        for (json, path, code) in variants {
            XCTAssertThrowsError(try ThemeValidator.validate(Data(json.utf8)), json) { error in
                XCTAssertEqual((error as? ThemeValidationError)?.path, path, json)
                XCTAssertEqual((error as? ThemeValidationError)?.code, code, json)
            }
        }
        for count in [15, 17] {
            let ansi = String(repeating: "\"#123456\",", count: count).dropLast()
            let json = String(extra("\"terminal\":{\"ansi\":[\(ansi)]}"))
            XCTAssertThrowsError(try ThemeValidator.validate(Data(json.utf8))) { error in
                XCTAssertEqual((error as? ThemeValidationError)?.code, .invalidANSI)
                XCTAssertEqual((error as? ThemeValidationError)?.path, "$.terminal.ansi")
            }
        }
        XCTAssertThrowsError(try ThemeValidator.validate(Data(repeating: 32, count: 65537))) { error in
            XCTAssertEqual((error as? ThemeValidationError)?.code, .tooLarge)
        }
        XCTAssertThrowsError(try ThemeValidator.validate(Data([0xFF])))
        var invalidANSI = Array(repeating: "#123456", count: 16)
        invalidANSI[3] = "#GGGGGG"
        let badArray: [String: Any] = ["version": 1, "id": "sample", "name": "Sample", "appearance": "light", "terminal": ["ansi": invalidANSI]]
        XCTAssertThrowsError(try ThemeValidator.validate(JSONSerialization.data(withJSONObject: badArray))) { error in
            XCTAssertEqual((error as? ThemeValidationError)?.path, "$.terminal.ansi[3]")
            XCTAssertEqual((error as? ThemeValidationError)?.code, .invalidColor)
        }
        let exact = minimal + String(repeating: " ", count: 65536 - minimal.utf8.count)
        XCTAssertNoThrow(try ThemeValidator.validate(Data(exact.utf8)))
    }
    func testS015_UT04_contrastWarningsNamePairs() throws {
        let json =
            ##"{"version":1,"id":"dim","name":"Dim","appearance":"dark","terminal":{"background":"#101010","foreground":"#101010","cursor":"#101010","cursorText":"#101010","selectionBackground":"#101010","selectionForeground":"#101010"}}"##
        let resolved = try ThemeValidator.validate(Data(json.utf8)).resolved()
        let warnings = resolved.contrastWarnings
        for first in ["terminal.foreground", "terminal.selectionForeground", "terminal.cursorText", "terminal.cursor"] {
            XCTAssertTrue(warnings.contains { $0.foregroundPath == first && $0.ratio == 1 })
        }
        XCTAssertEqual(resolved.terminal.foreground, 0x101010)
        XCTAssertEqual(ThemeColor(0).contrast(against: ThemeColor(0xFFFFFF)), 21, accuracy: 0.00001)
    }
    func testBuiltInsPassTextAndBoundaryContrast() {
        for appearance in ThemeAppearance.allCases {
            XCTAssertEqual(ResolvedTheme.builtIn(appearance).contrastWarnings, [], appearance.rawValue)
        }
    }
    func testCommittedExamplesMatchBundledCopiesAndSchemaFields() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("specs/03-functional-requirements/themes")
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("theme.schema.json"))) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        for (group, fields) in [("terminal", Set(TerminalColorField.allCases.map(\.rawValue) + ["ansi"])), ("ui", Set(UIColorField.allCases.map(\.rawValue)))] {
            XCTAssertEqual(Set(try XCTUnwrap(properties[group]?["properties"] as? [String: Any]).keys), fields)
        }
        for example in ThemeExample.allCases {
            let data = try ThemeExamples.data(example)
            XCTAssertEqual(data, try Data(contentsOf: directory.appendingPathComponent("example-\(example.rawValue).theme.json")))
            _ = try ThemeValidator.validate(data).resolved()
        }
    }
    func testEquivalentNumericVersionAndHexCase() throws {
        for version in ["1", "1.0", "1e0", "10e-1", "0.1e1"] {
            XCTAssertNoThrow(try ThemeValidator.validate(Data(minimal.replacingOccurrences(of: "\"version\":1", with: "\"version\":\(version)").utf8)))
        }
        XCTAssertEqual(ThemeColor(hex: "#aBcDef")?.hex, "#ABCDEF")
    }
}
