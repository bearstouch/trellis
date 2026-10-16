import XCTest
@testable import TrellisCore

final class ThemeReviewTests: XCTestCase {
    private func data(version: String = "1", name: String = "Review") -> Data {
        Data("{\"version\":\(version),\"id\":\"review\",\"name\":\"\(name)\",\"appearance\":\"dark\"}".utf8)
    }

    func testDecodedDuplicateKeysCannotBypassValidation() {
        let sources = [
            #"{"version":1,"id":"review","name":"Review","appearance":"dark","\u0069d":"other"}"#,
            ##"{"version":1,"id":"review","name":"Review","appearance":"dark","terminal":{"background":"#000000","back\u0067round":"#ffffff"}}"##
        ]
        for source in sources {
            XCTAssertThrowsError(try ThemeValidator.validate(Data(source.utf8))) { error in
                XCTAssertEqual((error as? ThemeValidationError)?.code, .duplicateKey)
            }
        }
    }

    func testVersionIsComparedWithoutFloatingPointRounding() throws {
        for version in ["1", "1.0", "10e-1", "0.01e2", "1000.000E-3", "1e+0"] {
            XCTAssertEqual(try ThemeValidator.validate(data(version: version)).id, "review", version)
        }
        for version in ["1.00000000000000000001", "0.99999999999999999999", "-1", "1e99999999999999999999999", "10e-2"] {
            XCTAssertThrowsError(try ThemeValidator.validate(data(version: version)), version) { error in
                XCTAssertEqual((error as? ThemeValidationError)?.code, .unsupportedVersion)
            }
        }
    }

    func testExactlyMaximumBytesAcceptedButOneMoreRejected() throws {
        let base = data()
        var exact = base
        exact.append(Data(repeating: 32, count: ThemeValidator.maximumBytes - base.count))
        XCTAssertEqual(try ThemeValidator.validate(exact).id, "review")
        exact.append(32)
        XCTAssertThrowsError(try ThemeValidator.validate(exact)) { error in
            XCTAssertEqual((error as? ThemeValidationError)?.code, .tooLarge)
        }
    }

    func testUnicodeNameLengthUsesCodePointsRatherThanGraphemeClusters() throws {
        XCTAssertNoThrow(try ThemeValidator.validate(data(name: String(repeating: "😀", count: 100))))
        XCTAssertThrowsError(try ThemeValidator.validate(data(name: String(repeating: "e\u{301}", count: 51)))) { error in
            XCTAssertEqual((error as? ThemeValidationError)?.code, .invalidName)
        }
    }

    func testMalformedEscapesNumbersAndTruncatedContainersRejected() {
        for version in ["01", "+1", ".1", "1.", "1e", "NaN", "Infinity", "true false"] {
            XCTAssertThrowsError(try ThemeValidator.validate(data(version: version)), version) { error in
                XCTAssertEqual((error as? ThemeValidationError)?.code, .malformedJSON)
            }
        }
        for name in [#"\x41"#, #"\uD800"#, #"\uDC00"#] {
            XCTAssertThrowsError(try ThemeValidator.validate(data(name: name)), name) { error in
                XCTAssertEqual((error as? ThemeValidationError)?.code, .malformedJSON)
            }
        }
        for suffix in [",", " trailing", "{}"] {
            XCTAssertThrowsError(try ThemeValidator.validate(data() + Data(suffix.utf8)))
        }
    }

    func testBuiltInPalettesPassEveryAdvisoryContrastPair() {
        for appearance in ThemeAppearance.allCases {
            XCTAssertEqual(ResolvedTheme.builtIn(appearance).contrastWarnings, [], appearance.rawValue)
        }
    }

    func testFocusAndDividersWarnWhenTheyDisappearAgainstTerminalCanvas() throws {
        let json: [String: Any] = [
            "version": 1, "id": "invisible-boundaries", "name": "Invisible boundaries", "appearance": "dark",
            "terminal": ["background": "#66758B"], "ui": ["focusRing": "#66758B", "border": "#66758B"]
        ]
        let resolved = try ThemeValidator.validate(JSONSerialization.data(withJSONObject: json)).resolved()
        for field in ["ui.focusRing", "ui.border"] {
            let warning = try XCTUnwrap(
                resolved.contrastWarnings.first {
                    $0.foregroundPath == field && $0.backgroundPath == "terminal.background"
                })
            XCTAssertEqual(warning.ratio, 1, accuracy: 0.001)
            XCTAssertEqual(warning.minimum, 3)
        }
    }
}
