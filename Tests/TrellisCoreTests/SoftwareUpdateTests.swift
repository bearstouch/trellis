import Foundation
import XCTest
import TrellisCore

final class SoftwareUpdateTests: XCTestCase {
    private let key = Data(repeating: 1, count: 32).base64EncodedString()

    func testFeedNeedsHTTPSURLAndPublicKey() {
        let url = "https://raw.githubusercontent.com/bearstouch/trellis/appcast/appcast.xml"
        XCTAssertEqual(UpdateFeed(info: ["SUFeedURL": url, "SUPublicEDKey": key])?.url.absoluteString, url)
        XCTAssertNil(UpdateFeed(info: [:]), "SwiftPM and development builds have no updater")
        XCTAssertNil(UpdateFeed(info: ["SUFeedURL": url]), "A feed without a key could never verify an update")
        XCTAssertNil(UpdateFeed(info: ["SUFeedURL": url, "SUPublicEDKey": "  "]))
        XCTAssertNil(UpdateFeed(info: ["SUFeedURL": "http://example.com/appcast.xml", "SUPublicEDKey": key]), "Plain HTTP is loopback-only")
        XCTAssertNil(UpdateFeed(info: ["SUFeedURL": "file:///tmp/appcast.xml", "SUPublicEDKey": key]))
        XCTAssertNotNil(UpdateFeed(info: ["SUFeedURL": "http://127.0.0.1:8000/appcast.xml", "SUPublicEDKey": key]), "Local end-to-end testing")
    }

    func testBetaChannelFollowsTheBuildUntilChosen() throws {
        let suite = "trellis-updates-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(AppVersion.isPrerelease("1.0.0-beta.2"))
        XCTAssertFalse(AppVersion.isPrerelease("1.0.0"))
        let stable = UpdatePreferences(defaults: defaults, version: "1.0.0")
        XCTAssertFalse(stable.includeBetas)
        XCTAssertEqual(stable.allowedChannels, [], "Stable builds see only channel-less items")
        let beta = UpdatePreferences(defaults: defaults, version: "1.1.0-beta.1")
        XCTAssertTrue(beta.includeBetas, "A pre-release keeps receiving pre-releases by default")
        XCTAssertEqual(beta.allowedChannels, [UpdateFeed.betaChannel])
        beta.includeBetas = false
        XCTAssertFalse(UpdatePreferences(defaults: defaults, version: "1.1.0-beta.1").includeBetas, "An explicit choice wins over the default")
        stable.includeBetas = true
        XCTAssertEqual(UpdatePreferences(defaults: defaults, version: "1.0.0").allowedChannels, ["beta"])
    }
}
