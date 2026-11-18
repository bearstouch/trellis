import AppKit
import SwiftUI
import XCTest

@testable import TrellisCore
@testable import TrellisUI

/// The grouped settings layout: every pane lays out on its own (it scrolls itself, with no outer ScrollView),
/// and the appearance tiles keep their order.
final class SettingsFormTests: XCTestCase {
    func testAppearanceTilesAreSystemLightDark() {
        XCTAssertEqual(AppearanceModePicker.modes, [.system, .light, .dark])
        XCTAssertEqual(Set(AppearanceModePicker.modes), Set(ChromeMode.allCases), "every mode has a tile")
    }

    @MainActor
    func testEveryPaneLaysOutInBothAppearances() throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        let panes: [AnyView] = [
            AnyView(AppearanceSettingsView(model: model)), AnyView(LaunchSettingsView(model: model)),
            AnyView(SessionBrokerStatusView(model: model)), AnyView(KeyboardSettingsView(model: model)),
            AnyView(ThemePreviewView(workspace: model)), AnyView(AgentSettingsView(model: model)),
            AnyView(RemoteControlSettingsView(model: model, showAutomation: {}))
        ]
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            for pane in panes {
                let host = NSHostingView(rootView: pane.frame(width: 640, height: 600))
                host.appearance = NSAppearance(named: name)
                host.frame = NSRect(x: 0, y: 0, width: 640, height: 600)
                host.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(host.fittingSize.height, 0)
            }
        }
    }

    func testModeTilesNameTheirThemes() {
        let light = ResolvedTheme.builtIn(.light), dark = ResolvedTheme.builtIn(.dark)
        XCTAssertEqual(light.appearance, .light)
        XCTAssertEqual(dark.appearance, .dark)
        XCTAssertNotEqual(light.terminal.background, dark.terminal.background, "System's split tile shows two different windows")
    }
}
