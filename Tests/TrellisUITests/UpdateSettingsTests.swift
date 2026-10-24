import AppKit
import SwiftUI
import XCTest
import TrellisCore
@testable import TrellisUI

@MainActor
private final class FakeUpdater: SoftwareUpdater {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false
    var includesBetas = false
    var lastUpdateCheckDate: Date?
    var onChange: (() -> Void)?
    var checks = 0
    func checkForUpdates() { checks += 1; canCheckForUpdates = false }
}

final class UpdateSettingsTests: XCTestCase {
    @MainActor
    func testSettingsDriveTheUpdater() {
        let updater = FakeUpdater()
        let model = UpdateSettingsModel(updater: updater, version: "1.0.0-beta.2")
        XCTAssertEqual(model.version, "1.0.0-beta.2")
        XCTAssertFalse(model.automaticChecks, "MAC-14: automatic checks start off")
        XCTAssertNil(model.lastCheck)
        model.setAutomaticChecks(true)
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        XCTAssertTrue(model.automaticChecks)
        model.setIncludeBetas(true)
        XCTAssertTrue(updater.includesBetas)
        XCTAssertTrue(model.includeBetas)
        XCTAssertEqual(updater.checks, 0, "Changing settings never checks by itself")
    }

    @MainActor
    func testCheckNowRunsOnceWhileACheckIsInProgress() {
        let updater = FakeUpdater()
        let model = UpdateSettingsModel(updater: updater)
        model.checkNow()
        XCTAssertEqual(updater.checks, 1)
        XCTAssertFalse(model.canCheck, "Check Now is disabled while Sparkle is busy")
        model.checkNow()
        XCTAssertEqual(updater.checks, 1)
        let finished = Date(timeIntervalSince1970: 1_800_000_000)
        updater.canCheckForUpdates = true; updater.lastUpdateCheckDate = finished
        updater.onChange?()
        XCTAssertTrue(model.canCheck)
        XCTAssertEqual(model.lastCheck, finished)
    }

    @MainActor
    func testSettingsViewRendersWithAndWithoutAnUpdater() throws {
        _ = NSApplication.shared
        let workspace = AppWorkspaceModel(store: try WorkspaceStore())
        for updates in [nil, UpdateSettingsModel(updater: FakeUpdater())] {
            let view = NSHostingView(rootView: AppSettingsView(model: workspace, updates: updates))
            view.frame = NSRect(x: 0, y: 0, width: 980, height: 700)
            view.layoutSubtreeIfNeeded()
        }
        let pane = NSHostingView(rootView: UpdateSettingsView(updates: UpdateSettingsModel(updater: FakeUpdater())))
        pane.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        pane.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(pane.fittingSize.height, 0)
    }
}
