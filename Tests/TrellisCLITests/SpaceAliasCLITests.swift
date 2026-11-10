import XCTest
@testable import TrellisCLI

/// `trellis window …` and `--window` are the deprecated names from before windows were renamed spaces.
final class SpaceAliasCLITests: XCTestCase {
    func testWindowNounAndOptionAreAliasesOfSpace() throws {
        XCTAssertEqual(try CLIArguments.parse(["window", "list"]).spec, "space.list")
        XCTAssertEqual(try CLIArguments.parse(["space", "list"]).spec, "space.list")
        let tabs = try CLIArguments.parse(["tab", "list", "--window", "Build"])
        XCTAssertEqual(tabs.spec, "tab.list")
        XCTAssertEqual(tabs.options["space"], ["Build"])
        XCTAssertEqual(try CLIArguments.parse(["window", "rename", "--window", "A", "--name", "B"]).options["space"], ["A"])
        XCTAssertThrowsError(try CLIArguments.parse(["tab", "list", "--window", "A", "--space", "B"]), "Both names count as the same option")
    }
}
