import AppKit
import XCTest
import TrellisCore
@testable import TrellisTerminal

final class BundledFontTests: XCTestCase {
    @MainActor
    func testDefaultTerminalFontIsBundledRobotoMono() throws {
        NativeTerminalFont.registerBundledFonts(); NativeTerminalFont.registerBundledFonts()
        let choice = NativeTerminalFont.choice(for: AppearanceSettings().fontName)
        XCTAssertEqual(choice.name, "RobotoMono-Regular")
        XCTAssertNil(choice.notice)
        let font = NativeTerminalFont.font(choice, size: 13)
        XCTAssertEqual(font.fontName, "RobotoMono-Regular")
        XCTAssertTrue(NativeTerminalFont.isMonospaced(font))
        XCTAssertFalse(NativeTerminalFont.isMonospaced(NSFont.systemFont(ofSize: 13)), "Proportional faces stay excluded")
        XCTAssertEqual(NativeTerminalFont.typefaceName(for: font.fontName), "Roboto Mono")
        XCTAssertTrue(NativeTerminalFont.installedNames.contains("RobotoMono-Regular"))
    }

    @MainActor
    func testBundledFaceCoversBoldAndItalic() throws {
        NativeTerminalFont.registerBundledFonts()
        let regular = try XCTUnwrap(NSFont(name: "RobotoMono-Regular", size: 13))
        let manager = NSFontManager.shared
        XCTAssertEqual(manager.convert(regular, toHaveTrait: .boldFontMask).fontName, "RobotoMono-Bold")
        XCTAssertEqual(manager.convert(regular, toHaveTrait: .italicFontMask).fontName, "RobotoMono-Italic")
        XCTAssertEqual(manager.convert(regular, toHaveTrait: [.boldFontMask, .italicFontMask]).fontName, "RobotoMono-BoldItalic")
    }

    @MainActor
    func testNewTerminalStartsWithBundledFont() {
        _ = NSApplication.shared
        let native = NativeTerminal()
        XCTAssertEqual((native.view as? AccessibleTerminalView)?.font.fontName, "RobotoMono-Regular")
    }
}
