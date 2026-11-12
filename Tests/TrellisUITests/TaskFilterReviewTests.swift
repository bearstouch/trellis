import TrellisCore
import XCTest

@testable import TrellisUI

/// The Tasks view's filter (FR-TK02).
final class TaskFilterReviewTests: XCTestCase {
    func testFilterMatchesEveryWordInNameCommandGroupOrDetailIgnoringCase() {
        let task = LaunchTask(name: "Unit tests", command: "swift test --parallel", group: .test)
        XCTAssertTrue(TaskCatalog.matches(task, query: ""))
        XCTAssertTrue(TaskCatalog.matches(task, query: "   "))
        XCTAssertTrue(TaskCatalog.matches(task, query: "UNIT"))
        XCTAssertTrue(TaskCatalog.matches(task, query: "parallel unit"), "Words match anywhere, in any order")
        XCTAssertTrue(TaskCatalog.matches(LaunchTask(name: "Server", command: "npm start", group: .run), query: "run"), "The group counts")
        XCTAssertFalse(TaskCatalog.matches(task, query: "unit build"), "Every word must match")
        XCTAssertFalse(TaskCatalog.matches(task, query: "Package.swift"))
        XCTAssertTrue(TaskCatalog.matches(task, detail: "From Package.swift", query: "package.swift"))
        XCTAssertTrue(TaskCatalog.matches(LaunchTask(name: "Déployer", command: "make deploy"), query: "deployer"), "Accents are ignored")
    }
}
