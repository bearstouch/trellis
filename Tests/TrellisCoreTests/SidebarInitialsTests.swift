import XCTest
@testable import TrellisCore

final class SidebarInitialsTests: XCTestCase {
    func testInitialsUseTwoWordsOrTwoCharacters() {
        let cases: [(String, String)] = [
            ("Build Server", "BS"), ("Project", "PR"), ("api-gateway", "AG"), ("my_repo.dev", "MR"),
            ("  spaced   out  name ", "SO"), ("x", "X"), ("🚀 Launch", "🚀L"), ("🚀", "🚀"), ("", "?"), ("  - _ ", "?")
        ]
        for (name, expected) in cases { XCTAssertEqual(WorkspaceAccessibility.initials(for: name), expected, name) }
    }
}
