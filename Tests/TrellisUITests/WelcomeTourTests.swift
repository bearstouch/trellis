import AppKit
import SwiftUI
import XCTest
import TrellisCore
@testable import TrellisUI

@MainActor
final class WelcomeTourTests: XCTestCase {
    private func makeModel(preferences: UserDefaults? = nil) async throws -> AppWorkspaceModel {
        _ = NSApplication.shared
        let defaults = try preferences ?? XCTUnwrap(UserDefaults(suiteName: "trellis.tests.\(UUID())"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: defaults)
        await model.createWindow(name: "api-server", startSession: false)
        return model
    }

    // MARK: FR-ON01

    func testFreshInstallOpensOnceAndRelaunchDoesNot() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "trellis.tests.\(UUID())"))
        let first = try await makeModel(preferences: defaults)
        XCTAssertTrue(first.offerWelcomeTour(workspaceExisted: false))
        XCTAssertEqual(first.welcomeTourStep, .welcome)
        // Quitting midway: never closed, and the next launch still doesn't show it.
        let second = try await makeModel(preferences: defaults)
        XCTAssertFalse(second.offerWelcomeTour(workspaceExisted: false))
        XCTAssertFalse(second.welcomeTourVisible)
    }

    func testUpgradeNeverOpensAndStaysAnsweredIfTheWorkspaceIsLaterLost() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "trellis.tests.\(UUID())"))
        let upgraded = try await makeModel(preferences: defaults)
        XCTAssertFalse(upgraded.offerWelcomeTour(workspaceExisted: true))
        XCTAssertFalse(upgraded.welcomeTourVisible)
        XCTAssertTrue(defaults.bool(forKey: AppWorkspaceModel.welcomeTourSeenKey))
        let later = try await makeModel(preferences: defaults)
        XCTAssertFalse(later.offerWelcomeTour(workspaceExisted: false))
    }

    // MARK: FR-ON03

    func testReplayStartsAtTheFirstStepAndLeavesTheLaunchAnswerAlone() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "trellis.tests.\(UUID())"))
        let model = try await makeModel(preferences: defaults)
        model.openWelcomeTour()
        model.goToWelcomeTourStep(.remote)
        model.closeWelcomeTour()
        XCTAssertFalse(defaults.bool(forKey: AppWorkspaceModel.welcomeTourSeenKey))
        model.openWelcomeTour()
        XCTAssertEqual(model.welcomeTourStep, .welcome)
    }

    func testPaletteListsAndRunsTheTourAndClosesFirst() async throws {
        let model = try await makeModel()
        model.openCommandPalette()
        let item = try XCTUnwrap(model.commandPaletteItems.first { $0.target == .welcomeTour })
        XCTAssertEqual(item.title, "Welcome Tour")
        model.runCommandPaletteItem(item.id)
        XCTAssertFalse(model.commandPaletteVisible)
        for _ in 0..<200 where !model.welcomeTourVisible { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.welcomeTourStep, .welcome)
    }

    func testOpeningClosesAnOpenPaletteAndThePaletteCantOpenOverTheTour() async throws {
        let model = try await makeModel()
        model.openCommandPalette()
        model.openWelcomeTour()
        XCTAssertFalse(model.commandPaletteVisible)
        XCTAssertTrue(model.welcomeTourVisible)
        model.openCommandPalette()
        XCTAssertFalse(model.commandPaletteVisible)
    }

    func testRecoveryBlocksTheTourAndRecordsNoAnswer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "trellis.tests.\(UUID())"))
        let persistence = WorkspacePersistence(directory: directory)
        try Data("{\"schemaVersion\":999}".utf8).write(to: persistence.currentURL)
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: defaults, persistence: persistence)
        _ = await model.loadWorkspace()
        XCTAssertNotNil(model.recoveryMessage)
        XCTAssertFalse(model.canOpenWelcomeTour)
        XCTAssertFalse(model.offerWelcomeTour(workspaceExisted: false))
        model.openWelcomeTour()
        XCTAssertFalse(model.welcomeTourVisible)
        XCTAssertFalse(defaults.bool(forKey: AppWorkspaceModel.welcomeTourSeenKey))
    }

    func testSetupChoicesAreSavedThroughTheWorkspaceFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "trellis.tests.\(UUID())"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: defaults, persistence: WorkspacePersistence(directory: directory))
        _ = await model.loadWorkspace()
        await model.createWindow(name: "Terminal", startSession: false)
        model.openWelcomeTour()
        model.goToWelcomeTourStep(.setup)
        model.setChromeModeFromWelcomeTour(.light)
        model.setKeepSessionsRunning(false)
        model.closeWelcomeTour()
        let saved = await model.flushWorkspaceSave()
        XCTAssertTrue(saved)
        let restored = AppWorkspaceModel(store: try WorkspaceStore(), preferences: defaults, persistence: WorkspacePersistence(directory: directory))
        _ = await restored.loadWorkspace()
        XCTAssertEqual(restored.appearance.chromeMode, .light)
        XCTAssertFalse(restored.keepSessionsRunning)
    }

    // MARK: FR-ON04

    func testTerminalInputIsSuspendedWhileOpenAndRestoredAfter() async throws {
        let model = try await makeModel()
        let terminal = try XCTUnwrap(model.activeTerminal)
        model.openWelcomeTour()
        XCTAssertTrue(terminal.inputSuspended)
        model.closeWelcomeTour()
        XCTAssertFalse(terminal.inputSuspended)
    }

    func testPaneCreatedWhileOpenTakesNoInputUntilItCloses() async throws {
        let model = try await makeModel()
        model.openWelcomeTour()
        await model.createWindow(name: "from-automation", startSession: false)
        let terminal = try XCTUnwrap(model.activeTerminal)
        XCTAssertTrue(terminal.inputSuspended)
        model.closeWelcomeTour()
        XCTAssertFalse(terminal.inputSuspended)
    }

    func testClosingTheTourKeepsInputSuspendedForATabRename() async throws {
        let model = try await makeModel()
        let terminal = try XCTUnwrap(model.activeTerminal)
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        await model.beginTabRename(tab.id)
        model.openWelcomeTour()
        model.closeWelcomeTour()
        XCTAssertTrue(terminal.inputSuspended)
        await model.finishTabRename(tab.id, draft: "", action: .cancel)
        XCTAssertFalse(terminal.inputSuspended)
    }

    func testEndingARenameKeepsInputSuspendedBehindTheTour() async throws {
        let model = try await makeModel()
        let terminal = try XCTUnwrap(model.activeTerminal)
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        await model.beginTabRename(tab.id)
        model.openWelcomeTour()
        await model.finishTabRename(tab.id, draft: "", action: .cancel)
        XCTAssertTrue(terminal.inputSuspended)
    }

    func testPasteNeverReachesAPaneBehindTheTour() async throws {
        let model = try await makeModel()
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        _ = try await model.service.store.execute(.configureStoppedSession(paneID: pane, launch: .process(executable: "/bin/zsh", arguments: ["-f", "-c", "printf 'READY\\n'; exec /bin/cat"], directory: "/tmp")))
        await model.refresh()
        await model.start(paneID: pane)
        let terminal = try XCTUnwrap(model.terminals[pane])
        defer { terminal.requestTermination(force: true); terminal.adapter.detach() }
        func retained() throws -> String { try terminal.adapter.read(.retainedText) }
        for _ in 0..<500 where try !retained().contains("READY") { try await Task.sleep(for: .milliseconds(10)) }
        await model.waitForUpdates()
        model.openWelcomeTour()
        model.requestPaste(.text("NEVER_SINGLE"), paneID: pane)
        model.requestPaste(.text("NEVER_MULTI\nLINE\n"), paneID: pane)
        XCTAssertNil(model.pendingPaste, "A review would offer to send it behind the dialog")
        model.closeWelcomeTour()
        model.requestPaste(.text("AFTER_TOUR"), paneID: pane)
        for _ in 0..<500 where try !retained().contains("AFTER_TOUR") { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(try retained().contains("AFTER_TOUR"))
        XCTAssertFalse(try retained().contains("NEVER"))
    }

    func testFocusBehindTheDialogIsTakenFromPanesAndTextButNotItsControls() async throws {
        let model = try await makeModel()
        let terminal = try XCTUnwrap(model.activeTerminal)
        XCTAssertTrue(model.welcomeTourMustTakeFocus(from: terminal.view))
        XCTAssertTrue(model.welcomeTourMustTakeFocus(from: NSTextView()))
        XCTAssertFalse(model.welcomeTourMustTakeFocus(from: NSButton()))
        XCTAssertFalse(model.welcomeTourMustTakeFocus(from: NSSegmentedControl()))
        XCTAssertFalse(model.welcomeTourMustTakeFocus(from: nil))
    }

    // MARK: FR-ON05

    func testKeysPassThroughOnceClosedSoTheFadeOutCantEatThem() async throws {
        let model = try await makeModel()
        model.openWelcomeTour()
        XCTAssertTrue(model.handleWelcomeTourKeyDown(keyCode: 124, modifiers: [.function, .numericPad], firstResponder: nil))
        XCTAssertEqual(model.welcomeTourStep, .workspace)
        XCTAssertFalse(model.handleWelcomeTourKeyDown(keyCode: 124, modifiers: [], firstResponder: NSSegmentedControl()), "The control keeps its arrows")
        XCTAssertFalse(model.handleWelcomeTourKeyDown(keyCode: 0, modifiers: [], firstResponder: nil))
        XCTAssertTrue(model.handleWelcomeTourKeyDown(keyCode: 53, modifiers: [], firstResponder: nil))
        XCTAssertFalse(model.welcomeTourVisible)
        XCTAssertFalse(model.handleWelcomeTourKeyDown(keyCode: 36, modifiers: [], firstResponder: nil))
        XCTAssertFalse(model.handleWelcomeTourKeyDown(keyCode: 53, modifiers: [], firstResponder: nil))
    }

    func testPrimaryWalksEveryStepAndClosesOnTheLast() async throws {
        let model = try await makeModel()
        model.openWelcomeTour()
        for step in WelcomeTourStep.allCases.dropFirst() {
            model.advanceWelcomeTour()
            XCTAssertEqual(model.welcomeTourStep, step)
        }
        XCTAssertEqual(model.welcomeTourStep?.counter, "8 of 8")
        model.advanceWelcomeTour()
        XCTAssertFalse(model.welcomeTourVisible)
    }

    func testKeysStopAtBothEndsAndEscapeCloses() async throws {
        let model = try await makeModel()
        model.openWelcomeTour()
        model.handleWelcomeTourKey(.previous)
        XCTAssertEqual(model.welcomeTourStep, .welcome)
        model.handleWelcomeTourKey(.next)
        XCTAssertEqual(model.welcomeTourStep, .workspace)
        model.handleWelcomeTourKey(.previous)
        XCTAssertEqual(model.welcomeTourStep, .welcome)
        model.goToWelcomeTourStep(.setup)
        model.handleWelcomeTourKey(.next)
        XCTAssertEqual(model.welcomeTourStep, .setup, "An arrow key must not close the tour")
        model.handleWelcomeTourKey(.close)
        XCTAssertFalse(model.welcomeTourVisible)
    }

    func testReturnAdvancesAndFinishes() async throws {
        let model = try await makeModel()
        model.openWelcomeTour()
        model.handleWelcomeTourKey(.confirm)
        XCTAssertEqual(model.welcomeTourStep, .workspace)
        model.goToWelcomeTourStep(.setup)
        model.handleWelcomeTourKey(.confirm)
        XCTAssertFalse(model.welcomeTourVisible)
    }

    func testKeyMappingLeavesModifiedKeysAndFocusedControlsAlone() {
        XCTAssertEqual(WelcomeTourKey.from(keyCode: 53, modifiers: [], controlFocused: false), .close)
        XCTAssertEqual(WelcomeTourKey.from(keyCode: 36, modifiers: [], controlFocused: true), .confirm)
        XCTAssertEqual(WelcomeTourKey.from(keyCode: 76, modifiers: [.numericPad], controlFocused: false), .confirm)
        // AppKit flags plain arrow keys as function and numeric-pad keys.
        XCTAssertEqual(WelcomeTourKey.from(keyCode: 123, modifiers: [.function, .numericPad], controlFocused: false), .previous)
        XCTAssertEqual(WelcomeTourKey.from(keyCode: 124, modifiers: [.function, .numericPad], controlFocused: false), .next)
        XCTAssertNil(WelcomeTourKey.from(keyCode: 124, modifiers: [.function], controlFocused: true))
        XCTAssertNil(WelcomeTourKey.from(keyCode: 36, modifiers: [.command], controlFocused: false))
        XCTAssertNil(WelcomeTourKey.from(keyCode: 0, modifiers: [], controlFocused: false))
    }

    // MARK: MAC-15

    func testLaunchCallbackReportsWhetherSetupWasReachedAndRunsOnce() async throws {
        let model = try await makeModel()
        var reports: [Bool] = []
        model.onWelcomeTourClosed = { reports.append($0) }
        model.openWelcomeTour()
        model.goToWelcomeTourStep(.projects)
        model.closeWelcomeTour()
        XCTAssertEqual(reports, [false])
        model.openWelcomeTour()
        model.goToWelcomeTourStep(.setup)
        model.closeWelcomeTour()
        XCTAssertEqual(reports, [false], "A replay never asks")
    }

    func testReachingSetupByAnyPathCountsAndGoingBackKeepsIt() async throws {
        let model = try await makeModel()
        var reports: [Bool] = []
        model.onWelcomeTourClosed = { reports.append($0) }
        model.openWelcomeTour()
        model.goToWelcomeTourStep(.setup)
        model.retreatWelcomeTour()
        model.closeWelcomeTour()
        XCTAssertEqual(reports, [true])
    }

    func testReachingSetupAnswersAtOnceSoQuittingThereDoesNotAskAgain() async throws {
        let model = try await makeModel()
        var reached = 0
        model.onWelcomeTourReachedSetup = { reached += 1 }
        model.openWelcomeTour()
        model.goToWelcomeTourStep(.keyboard)
        XCTAssertEqual(reached, 0)
        model.advanceWelcomeTour()
        XCTAssertEqual(reached, 1, "Reported while the tour is still open")
        model.retreatWelcomeTour()
        model.advanceWelcomeTour()
        XCTAssertEqual(reached, 1)
        model.closeWelcomeTour()
        model.openWelcomeTour()
        model.goToWelcomeTourStep(.setup)
        XCTAssertEqual(reached, 1, "A replay never answers")
    }

    // MARK: FR-ON06, FR-ON07

    func testAppearanceAppliesAtOnceAndClosingKeepsIt() async throws {
        let model = try await makeModel()
        XCTAssertEqual(model.appearance.chromeMode, .dark)
        model.openWelcomeTour()
        model.goToWelcomeTourStep(.setup)
        model.setChromeModeFromWelcomeTour(.light)
        XCTAssertEqual(model.appearance.chromeMode, .light)
        XCTAssertEqual(model.effectiveChromeMode, .light)
        model.closeWelcomeTour()
        XCTAssertEqual(model.appearance.chromeMode, .light)
    }

    func testCLIRowFollowsTheProbeAndInstallRefreshesIt() async throws {
        let model = try await makeModel()
        model.openWelcomeTour()
        XCTAssertEqual(model.welcomeTourCLIStatus, .unavailable, "No probe, no row")
        model.closeWelcomeTour()
        var status = WelcomeTourCLIStatus.available
        var installs = 0
        model.welcomeTourCLIProbe = { status }
        model.welcomeTourInstallCLI = {
            installs += 1; status = .installed
        }
        model.openWelcomeTour()
        XCTAssertEqual(model.welcomeTourCLIStatus, .available)
        model.installCLIFromWelcomeTour()
        XCTAssertTrue(model.welcomeTourCLIInstalling)
        model.installCLIFromWelcomeTour()
        for _ in 0..<200 where model.welcomeTourCLIInstalling { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(installs, 1, "A second press while installing does nothing")
        XCTAssertEqual(model.welcomeTourCLIStatus, .installed)
    }

    // MARK: FR-ON08

    func testChordsFollowBindingsAndUnboundHasNone() async throws {
        let model = try await makeModel()
        XCTAssertEqual(model.welcomeTourChord(.splitLeftRight), "⌘D")
        XCTAssertEqual(model.welcomeTourChord(.commandPalette), "⇧⌘P")
        XCTAssertNil(model.welcomeTourChord(.showHosts))
    }

    func testDialogFitsEveryWindowSizeAndDropsTheIllustrationWhenSmall() {
        let full = CGSize(width: 1280, height: 800)
        XCTAssertEqual(WelcomeTourView.dialogSize(in: full), WelcomeTourView.fullSize)
        XCTAssertTrue(WelcomeTourView.showsStage(in: full))
        let minimum = CGSize(width: 400, height: 260)
        XCTAssertFalse(WelcomeTourView.showsStage(in: minimum))
        XCTAssertFalse(WelcomeTourView.showsDots(in: minimum))
        let dialog = WelcomeTourView.dialogSize(in: minimum)
        XCTAssertLessThanOrEqual(dialog.width, minimum.width)
        XCTAssertLessThanOrEqual(dialog.height, minimum.height)
    }

    func testFooterKeepsItsDotsOnlyWhereTheyFit() {
        XCTAssertTrue(WelcomeTourView.showsDots(in: CGSize(width: 1040, height: 660)), "The default window")
        XCTAssertTrue(WelcomeTourView.showsDots(in: CGSize(width: 600, height: 400)), "No illustration, so the panel has the whole dialog")
        XCTAssertFalse(WelcomeTourView.showsDots(in: CGSize(width: 800, height: 600)), "The illustration leaves too little beside it")
        for width in stride(from: 400, through: 1400, by: 20) {
            let size = CGSize(width: CGFloat(width), height: 600)
            if WelcomeTourView.showsDots(in: size) { XCTAssertGreaterThanOrEqual(WelcomeTourView.panelWidth(in: size), WelcomeTourView.dotsMinimumPanelWidth) }
        }
    }

    func testEveryStepRendersAtFullAndMinimumSizes() async throws {
        let model = try await makeModel()
        model.openWelcomeTour()
        for mode in [ChromeMode.dark, .light] {
            model.setChromeModeFromWelcomeTour(mode)
            for size in [CGSize(width: 1280, height: 800), CGSize(width: 800, height: 600), CGSize(width: 400, height: 260)] {
                for step in WelcomeTourStep.allCases {
                    model.goToWelcomeTourStep(step)
                    let view = NSHostingView(rootView: WelcomeTourView(model: model).preferredColorScheme(mode == .dark ? .dark : .light))
                    view.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
                    view.frame = CGRect(origin: .zero, size: size)
                    view.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                    if let directory = ProcessInfo.processInfo.environment["TRELLIS_TOUR_RENDER_DIR"] {
                        let name = "\(mode.rawValue)-\(Int(size.width))-\(step.rawValue + 1).png"
                        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                    }
                }
            }
        }
    }

    // MARK: FR-ON09

    func testEveryStepHasADistinctTitleAndCounter() {
        XCTAssertEqual(WelcomeTourStep.allCases.count, 8)
        XCTAssertEqual(Set(WelcomeTourStep.allCases.map(\.title)).count, 8)
        XCTAssertEqual(WelcomeTourStep.welcome.counter, "1 of 8")
    }
}
