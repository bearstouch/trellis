import Foundation
import XCTest
@testable import TrellisControl

final class ControlTimestampTests: XCTestCase {
    /// The wire format is unchanged from `ISO8601DateFormatter`'s default: UTC, whole seconds, `Z`.
    func testMatchesTheISO8601InternetDateTimeFormat() {
        let reference = ISO8601DateFormatter()
        for interval in [0, 0.999, 0.9994, 0.9996, 0.9999999, 1_000_000_000.5, 1_794_334_759, 1_794_334_759.9996, 4_102_444_800, -86_400.25, -0.0002] {
            let date = Date(timeIntervalSince1970: interval)
            XCTAssertEqual(ControlTimestamp.string(date), reference.string(from: date))
        }
        XCTAssertEqual(ControlTimestamp.string(Date(timeIntervalSince1970: 1_794_334_759)), "2026-11-10T18:19:19Z")
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20_000 {
            let date = Date(timeIntervalSince1970: Double.random(in: 0...4_102_444_800, using: &generator))
            XCTAssertEqual(ControlTimestamp.string(date), reference.string(from: date), "\(date.timeIntervalSince1970)")
        }
    }
}
