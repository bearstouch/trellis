import XCTest
@testable import TrellisCore

final class CommandPaletteTests: XCTestCase {
    private func action(_ action: ShortcutAction) -> CommandPaletteItem {
        CommandPaletteItem(
            target: .action(action), kind: .action, title: action.title, subtitle: action.menu.rawValue.capitalized, keywords: action.paletteKeywords,
            shortcut: action.defaultChord)
    }

    private func titles(_ sections: [CommandPaletteSection]) -> [String] { sections.flatMap { $0.matches.map(\.item.title) } }

    func testFuzzyMatchNeedsEveryLetterInOrderAndIgnoresCaseAndSpaces() throws {
        XCTAssertEqual(FuzzyMatch.match("spl", in: "Split Left/Right")?.positions, [0, 1, 2])
        XCTAssertEqual(FuzzyMatch.match("SPL", in: "split")?.positions, [0, 1, 2])
        XCTAssertNil(FuzzyMatch.match("lps", in: "Split"))
        XCTAssertNil(FuzzyMatch.match("splitx", in: "Split"))
        XCTAssertEqual(FuzzyMatch.match("theme no", in: "Theme: Nord Dark")?.positions, [0, 1, 2, 3, 4, 7, 8])
        XCTAssertEqual(FuzzyMatch.match("", in: "anything")?.positions, [])
        // Word starts beat letters buried inside a word.
        XCTAssertEqual(FuzzyMatch.match("api", in: "rapid gateway-api")?.positions, [14, 15, 16])
        XCTAssertEqual(FuzzyMatch.match("sl", in: "Split Left")?.positions, [0, 6])
        let prefix = try XCTUnwrap(FuzzyMatch.match("new", in: "New Tab")?.score)
        let wordStarts = try XCTUnwrap(FuzzyMatch.match("new", in: "Next Window")?.score)
        let inner = try XCTUnwrap(FuzzyMatch.match("new", in: "Renew Tab")?.score)
        XCTAssertGreaterThan(prefix, wordStarts)
        XCTAssertGreaterThan(wordStarts, inner)
    }

    func testFuzzyMatchBoundsLongQueriesAndTexts() {
        let letters = String(repeating: "a", count: FuzzyMatch.maximumQueryLetters)
        XCTAssertNotNil(FuzzyMatch.match(letters, in: letters))
        XCTAssertNil(FuzzyMatch.match(letters + "a", in: letters + "a"), "Longer queries match nothing")
        let long = String(repeating: "x", count: FuzzyMatch.maximumTextCharacters)
        XCTAssertNil(FuzzyMatch.match("y", in: long + "y"), "Only the start of a long text is searched")
        XCTAssertEqual(FuzzyMatch.match("xy", in: String(long.dropLast()) + "y")?.positions.last, FuzzyMatch.maximumTextCharacters - 1)
    }

    func testTitleMatchesRankAboveAliasesAndAliasesStillFind() {
        let items = [ShortcutAction.maximizePane, .splitTopBottom, .splitLeftRight, .newTab, .resizeLeft].map(action)
        let sections = CommandPaletteSearch.sections(items: items, query: "spl", scope: nil, recents: [])
        XCTAssertEqual(titles(sections).prefix(2), ["Split Left/Right", "Split Top/Bottom"])
        XCTAssertEqual(sections.first?.matches.first?.titlePositions, [0, 1, 2])
        let split = CommandPaletteSearch.sections(items: items, query: "split", scope: nil, recents: [])
        XCTAssertEqual(Set(titles(split).suffix(2)), ["Maximize / Restore Pane", "Move Divider Left"])
        XCTAssertEqual(split.flatMap(\.matches).first { $0.item.target == .action(.maximizePane) }?.matchedAlias, "split zoom")
        XCTAssertTrue(CommandPaletteSearch.sections(items: items, query: "xyzzy", scope: nil, recents: []).isEmpty)
    }

    func testEqualScoresFollowKindOrderAndSectionsFollowTheirBestRow() {
        let window = UUID(), tab = UUID()
        let items = [
            CommandPaletteItem(target: .theme("t"), kind: .theme, title: "api"),
            CommandPaletteItem(target: .window(window), kind: .window, title: "api"),
            CommandPaletteItem(target: .tab(windowID: window, tabID: tab), kind: .tab, title: "api"),
            CommandPaletteItem(target: .host(UUID()), kind: .host, title: "api-prod")
        ]
        let sections = CommandPaletteSearch.sections(items: items, query: "api", scope: nil, recents: [])
        XCTAssertEqual(sections.map(\.title), ["Tabs", "Windows", "Hosts", "Themes"])
    }

    func testRecentUseBoostsAMatchAndLeadsTheEmptyQuery() {
        let items =
            [ShortcutAction.splitLeftRight, .splitTopBottom, .newTab].map(action) + [
                CommandPaletteItem(target: .scope(.tabs), kind: .action, title: CommandPaletteScope.tabs.title)
            ]
        let boosted = CommandPaletteSearch.sections(items: items, query: "spl", scope: nil, recents: [ShortcutAction.splitTopBottom.rawValue].map { "action:" + $0 })
        XCTAssertEqual(titles(boosted).first, "Split Top/Bottom")
        let home = CommandPaletteSearch.sections(items: items, query: "  ", scope: nil, recents: ["action:splitTopBottom", "tab:gone", "action:newTab"])
        XCTAssertEqual(home.map(\.title), ["Recent", "Suggested"])
        // A recent item that no longer exists is skipped; suggestions don't repeat a recent one.
        XCTAssertEqual(home[0].matches.map(\.item.title), ["Split Top/Bottom", "New Tab"])
        XCTAssertEqual(home[1].matches.map(\.item.title), ["Go to Tab…"])
    }

    func testAScopeListsOneKindGroupedByWindow() {
        let first = UUID(), second = UUID()
        let items = [
            CommandPaletteItem(target: .scope(.tabs), kind: .action, title: "Go to Tab…"),
            CommandPaletteItem(target: .tab(windowID: first, tabID: UUID()), kind: .tab, title: "api", groupID: first.uuidString, groupTitle: "api-server"),
            CommandPaletteItem(target: .tab(windowID: first, tabID: UUID()), kind: .tab, title: "logs", groupID: first.uuidString, groupTitle: "api-server"),
            CommandPaletteItem(target: .tab(windowID: second, tabID: UUID()), kind: .tab, title: "dev", groupID: second.uuidString, groupTitle: "api-server"),
            CommandPaletteItem(target: .window(first), kind: .window, title: "api-server")
        ]
        let all = CommandPaletteSearch.sections(items: items, query: "", scope: .tabs, recents: [])
        // Two windows with one name stay apart.
        XCTAssertEqual(all.map(\.matches.count), [2, 1])
        XCTAssertEqual(all.map(\.title), ["api-server", "api-server"])
        XCTAssertEqual(titles(CommandPaletteSearch.sections(items: items, query: "lg", scope: .tabs, recents: [])), ["logs"])
    }

    func testRecentsAreDistinctNewestFirstAndBounded() {
        var recents = CommandPaletteRecents()
        for index in 0..<30 { recents.record("item:\(index)") }
        recents.record("item:25")
        XCTAssertEqual(recents.ids.count, CommandPaletteRecents.limit)
        XCTAssertEqual(recents.ids.prefix(2), ["item:25", "item:29"])
        XCTAssertEqual(Set(recents.ids).count, recents.ids.count)
    }

    func testCommandPaletteDefaultsToShiftCommandPAndYieldsToASavedChord() throws {
        XCTAssertEqual(ShortcutMap.defaults[.commandPalette], KeyChord("p", [.command, .shift]))
        XCTAssertEqual(ShortcutAction.commandPalette.menu, .view)
        XCTAssertEqual(ShortcutAction.commandPalette.title, "Command Palette…")
        XCTAssertTrue(ShortcutMap.defaults.issues().isEmpty)
        let data = Data(#"{"optionAsMeta":false,"overrides":{"showHosts":{"chord":{"key":"p","modifiers":3}}}}"#.utf8)
        let loaded = try JSONDecoder().decode(KeyboardSettings.self, from: data)
        XCTAssertEqual(loaded.shortcuts[.showHosts], KeyChord("p", [.command, .shift]))
        XCTAssertNil(loaded.shortcuts[.commandPalette])
        XCTAssertTrue(loaded.shortcuts.issues().isEmpty)
    }
}
