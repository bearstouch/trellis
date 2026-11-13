import AppKit
import SwiftTerm
import XCTest
@testable import TrellisCore
@testable import TrellisTerminal

/// ⌘-click and the link menu hand project files to an editor tab (FR-ED07), keeping the FR-L02–FR-L04 rules.
@MainActor
final class TerminalEditorLinkTests: XCTestCase {
    private final class Recorder {
        var opened: [String] = [], revealed: [String] = []
        var edited: [(String, Int?, Int?)] = []
        var accepts = true
    }

    private func makeTerminal() -> (NativeTerminal, AccessibleTerminalView, Recorder) {
        _ = NSApplication.shared
        let native = NativeTerminal()
        let surface = native.view as! AccessibleTerminalView
        let recorder = Recorder()
        native.openURL = {
            recorder.opened.append($0.path); return true
        }
        native.revealURL = { recorder.revealed.append($0.path) }
        let files = [
            "/work/src/a.swift": FileFacts(resolvedPath: "/work/src/a.swift", kind: .regular),
            "/work/run.sh": FileFacts(resolvedPath: "/work/run.sh", kind: .regular, isExecutable: true),
            "/elsewhere/b.txt": FileFacts(resolvedPath: "/elsewhere/b.txt", kind: .regular)
        ]
        native.fileProbe = FileProbe { files[$0] }
        native.fileLinkContext = { FileLinkContext(currentDirectory: "/work", homeDirectory: "/Users/me", localHostNames: ["mymac"]) }
        native.editorMayOpen = { $0.hasPrefix("/work/") }
        native.openInEditor = { path, line, column in
            recorder.edited.append((path, line, column))
            return recorder.accepts
        }
        return (native, surface, recorder)
    }

    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    func testCmdClickOpensProjectFilesInTheEditorAtTheirLine() async throws {
        let (native, surface, recorder) = makeTerminal()
        defer { native.adapter.detach() }
        surface.lastUserGesture = Date()
        native.requestOpenLink(source: surface, link: "src/a.swift:12:5", params: [:])
        await settle()
        XCTAssertEqual(recorder.edited.map(\.0), ["/work/src/a.swift"])
        XCTAssertEqual(recorder.edited.first?.1, 12)
        XCTAssertEqual(recorder.edited.first?.2, 5)
        XCTAssertEqual(recorder.opened, [], "The default app isn't used as well")

        surface.lastUserGesture = Date()
        native.requestOpenLink(source: surface, link: "./run.sh", params: [:])
        await settle()
        XCTAssertEqual(recorder.edited.last?.0, "/work/run.sh", "A script inside the project is edited, never run")
        XCTAssertEqual(recorder.revealed, [])

        surface.lastUserGesture = Date()
        native.requestOpenLink(source: surface, link: "/elsewhere/b.txt", params: [:])
        await settle()
        XCTAssertEqual(recorder.edited.count, 2, "A path outside the project isn't edited")
        XCTAssertEqual(recorder.opened, ["/elsewhere/b.txt"], "…it opens as before (FR-L02)")

        native.requestOpenLink(source: surface, link: "src/a.swift", params: [:])
        await settle()
        XCTAssertEqual(recorder.edited.count, 2, "Output alone still opens nothing")
    }

    func testAFileTheEditorRefusesFallsBackToTheUsualOpen() async throws {
        let (native, surface, recorder) = makeTerminal()
        defer { native.adapter.detach() }
        recorder.accepts = false
        surface.lastUserGesture = Date()
        native.requestOpenLink(source: surface, link: "src/a.swift", params: [:])
        await settle()
        XCTAssertEqual(recorder.opened, ["/work/src/a.swift"])
        surface.lastUserGesture = Date()
        native.requestOpenLink(source: surface, link: "run.sh", params: [:])
        await settle()
        XCTAssertEqual(recorder.revealed, ["/work/run.sh"], "A refused launchable is still only revealed (FR-L03)")
    }

    func testTheMenuOffersTheEditorFirstAndItsOpenUsesTheDefaultApp() async throws {
        let (native, surface, recorder) = makeTerminal()
        defer { native.adapter.detach() }
        let inside = try XCTUnwrap(native.describeLink(TerminalLinkClick(link: "src/a.swift:3", explicit: false, position: nil)))
        XCTAssertTrue(inside.canEdit)
        XCTAssertFalse(try XCTUnwrap(native.describeLink(TerminalLinkClick(link: "/elsewhere/b.txt", explicit: false, position: nil))).canEdit)
        native.openInEditor = nil
        XCTAssertFalse(try XCTUnwrap(native.describeLink(TerminalLinkClick(link: "src/a.swift", explicit: false, position: nil))).canEdit, "No editor, no item")

        surface.lastUserGesture = Date()
        native.openLink(inside.click, inEditor: false)
        await settle()
        XCTAssertEqual(recorder.opened, ["/work/src/a.swift"], "The menu's Open still means the default app")
    }
}
