import XCTest
@testable import TrellisCore

final class ScrollbackBudgetTests: XCTestCase {
    func testS013_UT01_evictByLineAndByteLimits() {
        XCTAssertEqual(ScrollbackBudget.standard.lineLimit, 10_000)
        XCTAssertEqual(ScrollbackBudget.standard.byteLimit, 16 * 1024 * 1024)
        let limits = ScrollbackBudget(lineLimit: 3, byteLimit: 10)
        XCTAssertEqual(limits.retainedSuffixCount(byteCounts: [2, 2, 2, 2, 2]), 3)
        XCTAssertEqual(limits.retainedSuffixCount(byteCounts: [6, 6]), 1)
        XCTAssertEqual(limits.retainedSuffixCount(byteCounts: [2, 200, 2]), 1)
        XCTAssertEqual(limits.retainedSuffixCount(byteCounts: [2, 200]), 0)
        XCTAssertEqual(ScrollbackBudget(lineLimit: 0).retainedSuffixCount(byteCounts: [1]), 0)
        XCTAssertEqual(ScrollbackBudget(byteLimit: 0).retainedSuffixCount(byteCounts: [1]), 0)
    }
}
