import Foundation
import XCTest

@testable import TrellisCore

/// FR-R08: the saved idle timeout of kept sessions.
final class KeptSessionIdleTimeoutTests: XCTestCase {
    func testChoicesAndDefault() {
        XCTAssertEqual(KeptSessionIdleTimeout.choices, [0, 1, 2, 4, 12, 24, 48, 96])
        XCTAssertEqual(KeptSessionIdleTimeout.defaultHours, 24)
        XCTAssertEqual(WorkspaceSettings().keptSessionIdleTimeoutHours, 24)
        XCTAssertEqual(KeptSessionIdleTimeout.seconds(hours: 0), 0)
        XCTAssertEqual(KeptSessionIdleTimeout.seconds(hours: 96), 345_600)
        XCTAssertEqual(KeptSessionIdleTimeout.seconds(hours: 3), 86_400, "An unknown value is the default, never a made-up limit")
        XCTAssertEqual(KeptSessionIdleTimeout.label(hours: 0), "No timeout")
        XCTAssertEqual(KeptSessionIdleTimeout.label(hours: 1), "1 hour")
        XCTAssertEqual(KeptSessionIdleTimeout.label(hours: 48), "48 hours")
    }

    func testSettingRoundTripsAndUnknownOrMissingValuesReadAsTheDefault() throws {
        XCTAssertEqual(WorkspaceSettings(keptSessionIdleTimeoutHours: 7).keptSessionIdleTimeoutHours, 24)
        for hours in KeptSessionIdleTimeout.choices {
            let encoded = try JSONEncoder().encode(WorkspaceSettings(shell: "/bin/zsh", directory: "/tmp", keptSessionIdleTimeoutHours: hours))
            XCTAssertEqual(try JSONDecoder().decode(WorkspaceSettings.self, from: encoded).keptSessionIdleTimeoutHours, hours)
        }
        let encoded = try JSONEncoder().encode(WorkspaceSettings(shell: "/bin/zsh", directory: "/tmp", keptSessionIdleTimeoutHours: 0))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for invalid in [-1, 3, "never"] as [Any] {
            object["keptSessionIdleTimeoutHours"] = invalid
            let decoded = try JSONDecoder().decode(WorkspaceSettings.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded.keptSessionIdleTimeoutHours, 24, "\(invalid)")
        }
        object.removeValue(forKey: "keptSessionIdleTimeoutHours")
        let missing = try JSONDecoder().decode(WorkspaceSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(missing.keptSessionIdleTimeoutHours, 24, "A file from before the setting")
    }
}
