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
    func testEveryBundledFamilyIsSelectableMonospaceWithAllStyles() throws {
        NativeTerminalFont.registerBundledFonts()
        let installed = NativeTerminalFont.installedNames
        let manager = NSFontManager.shared
        let expected = ["Roboto Mono", "JetBrains Mono", "Cascadia Mono NF", "IBM Plex Mono", "Iosevka Fixed", "Atkinson Hyperlegible Mono"]
        for family in expected {
            let members = try XCTUnwrap(manager.availableMembers(ofFontFamily: family), family).compactMap { $0.first as? String }
            let regular = try XCTUnwrap(installed.first { NativeTerminalFont.typefaceName(for: $0) == family }, "\(family) is listed once in Settings")
            XCTAssertEqual(installed.filter { NativeTerminalFont.typefaceName(for: $0) == family }, [regular])
            let font = try XCTUnwrap(NSFont(name: regular, size: 13))
            XCTAssertFalse(manager.traits(of: font).contains(.boldFontMask), family)
            XCTAssertFalse(manager.traits(of: font).contains(.italicFontMask), family)
            XCTAssertNil(NativeTerminalFont.choice(for: regular).notice, family)
            for trait: NSFontTraitMask in [.boldFontMask, .italicFontMask, [.boldFontMask, .italicFontMask]] {
                let styled = manager.convert(font, toHaveTrait: trait)
                XCTAssertTrue(members.contains(styled.fontName), "\(family) has a real \(trait.rawValue) face")
                XCTAssertTrue(manager.traits(of: styled).contains(trait), "\(family) \(trait.rawValue)")
                XCTAssertTrue(NativeTerminalFont.isMonospaced(styled), styled.fontName)
            }
        }
    }

    @MainActor
    func testCascadiaNerdFontCarriesPowerlineGlyphs() throws {
        NativeTerminalFont.registerBundledFonts()
        let font = try XCTUnwrap(NSFont(name: "CascadiaMonoNF-Regular", size: 13))
        var characters: [UniChar] = [0xE0B0, 0xE0A0, 0xF015]
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count))
    }

    @MainActor
    func testNewTerminalStartsWithBundledFont() {
        _ = NSApplication.shared
        let native = NativeTerminal()
        XCTAssertEqual((native.view as? AccessibleTerminalView)?.font.fontName, "RobotoMono-Regular")
    }
}
