import AppKit
import XCTest
import UTermCore
@testable import UTermUI

final class ThemePreviewTests: XCTestCase {
    @MainActor
    func testValidAndInvalidPreviewCannotChangeWorkspaceOrStartSession() async throws {
        _ = NSApplication.shared
        let workspace = AppWorkspaceModel(store: try WorkspaceStore())
        await workspace.createWindow(startSession: false)
        let settings = workspace.appearance, snapshot = workspace.snapshot
        let terminal = try XCTUnwrap(workspace.activeTerminal)
        let preview = ThemePreviewModel()
        for example in ThemeExample.allCases {
            preview.example(example)
            XCTAssertNil(preview.validationMessage)
            XCTAssertEqual(workspace.appearance, settings)
            XCTAssertEqual(workspace.snapshot, snapshot)
            XCTAssertTrue(workspace.activeTerminal === terminal)
            XCTAssertNil(preview.terminal.processID)
            XCTAssertFalse(preview.terminal.isRunning)
        }
        let previous = preview.theme
        XCTAssertFalse(preview.preview(Data(#"{"version":1,"font":"Monaco"}"#.utf8)))
        XCTAssertEqual(preview.theme, previous)
        XCTAssertTrue(preview.validationMessage?.contains("$.font") == true)
        XCTAssertTrue(try preview.terminal.adapter.read(.retainedText).contains("00  01  02  03  04  05  06  07"))
        XCTAssertTrue(try preview.terminal.adapter.read(.retainedText).contains("08  09  10  11  12  13  14  15"))
    }
}
