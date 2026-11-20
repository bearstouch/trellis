import AppKit
import SwiftUI
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// The table preview at the editor's size limit (FR-ED17, FR-ED19): only the rows on screen are built, the scroller is
/// exact at once, sorting reorders the view and never the text, and a change elsewhere in the app doesn't reload it. The
/// times printed are what the commit records; run with `-c release` for the optimized numbers.
final class TablePreviewLongDocumentTests: XCTestCase {
    private var scratch: URL!
    private var project: String!
    private var shell: String!
    /// Rows that keep `sample` just under the editor's 2 MB limit.
    private static let limitRows = 31_500

    private struct Host: View {
        @ObservedObject var model: AppWorkspaceModel
        let id: UUID
        var body: some View { if let tab = model.editorTab(id) { EditorTabView(model: model, tab: tab, shown: true) } }
    }

    /// About 65 bytes a row: an id, quoted text with commas and quotes, a multiline cell every 50 rows, numeric columns.
    static func sample(rows: Int) -> String {
        var text = "id,name,city,amount,score,note,status,tag\n"
        text.reserveCapacity(rows * 66)
        for row in 0..<rows {
            let note = row % 50 == 0 ? "\"first line\nsecond, line\"" : "\"says \"\"ok\"\", fine\""
            text += "\(row),Person \(row % 977),City \(row % 131),\(row * 7 % 10_000).25,\(row % 100),\(note),\(row % 3 == 0 ? "open" : "closed"),t\(row % 17)\n"
        }
        return text
    }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-tp-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let manager = FileManager.default
        project = scratch.appendingPathComponent("project").path
        for folder in ["bin", "state", "project/.git"] { try manager.createDirectory(at: scratch.appendingPathComponent(folder), withIntermediateDirectories: true) }
        try Self.sample(rows: Self.limitRows).write(toFile: project + "/long.csv", atomically: true, encoding: .utf8)
        try Self.sample(rows: 30).write(toFile: project + "/short.csv", atomically: true, encoding: .utf8)
        try Self.sample(rows: 30).replacingOccurrences(of: ",", with: "\t").write(toFile: project + "/short.tsv", atomically: true, encoding: .utf8)
        shell = scratch.appendingPathComponent("bin/sh").path
        try "#!/bin/sh\nprintf 'SHELL-UP\\n'\nexec /bin/cat\n".write(toFile: shell, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    @MainActor private func tables(in view: NSView) -> [NSTableView] { ((view as? CopyingTableView).map { [$0] } ?? []) + view.subviews.flatMap { tables(in: $0) } }

    @MainActor
    private func waitFor(_ timeout: TimeInterval = 10, in host: NSView, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
            host.layoutSubtreeIfNeeded()
        }
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    @MainActor
    private func makeModel() async throws -> AppWorkspaceModel {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-tp-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        _ = await model.loadWorkspace()
        model.confirmCloseSessions = { _ in true }
        model.workspaceIsFrontmost = { true }
        model.openFileInApp = { _, _ in }
        model.revealFiles = { _ in }
        let saved = await model.saveLaunchSettings(shell: shell, directory: project)
        XCTAssertTrue(saved)
        _ = await model.createSpace(name: "W")
        return model
    }

    func testSortedOrderPutsEmptyCellsLastAndKeepsTies() {
        func table(_ rows: [[String]]) -> DelimitedTable { DelimitedTable(header: ["h"], rows: rows, numericColumns: []) }
        let numbers = table([["10"], [""], ["9"], ["10"], ["-1"], []])
        XCTAssertEqual(DelimitedTableView.Coordinator.sortedOrder(numbers, column: 0, numeric: true, ascending: true), [4, 2, 0, 3, 1, 5], "A row without the cell sorts as empty")
        XCTAssertEqual(DelimitedTableView.Coordinator.sortedOrder(numbers, column: 0, numeric: true, ascending: false), [0, 3, 2, 4, 1, 5], "Ties keep file order")
        let names = table([["file10"], ["File2"], [""], ["file1"]])
        XCTAssertEqual(DelimitedTableView.Coordinator.sortedOrder(names, column: 0, numeric: false, ascending: true), [3, 1, 0, 2], "As Finder sorts names, empty last")
        XCTAssertEqual(DelimitedTableView.Coordinator.sortedOrder(names, column: 0, numeric: false, ascending: false), [0, 1, 3, 2])
    }

    /// A sort still running when the rows change never applies to the new rows; ⌘C copies the shown rows, quoted as needed.
    @MainActor
    func testANewerTableWinsOverASortStillRunningAndCopyQuotes() async throws {
        let model = try await makeModel()
        defer {
            model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        let style = MarkdownPreviewStyle(model)
        let coordinator = DelimitedTableView.Coordinator()
        let tableView = CopyingTableView()
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.tableView = tableView
        let big = DelimitedDocument.parse(Self.sample(rows: Self.limitRows), delimiter: UInt8(ascii: ","))
        coordinator.update(table: big, style: style, fileName: "x.csv")
        tableView.sortDescriptors = [NSSortDescriptor(key: "c0", ascending: false)]
        let small = DelimitedDocument.parse("n,v\nb,\"x\ty\"\na,\"say \"\"hi\"\"\"\nc,3\n", delimiter: UInt8(ascii: ","))
        coordinator.update(table: small, style: style, fileName: "x.csv")
        let deadline = Date().addingTimeInterval(10)
        while coordinator.order?.count != 3, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(coordinator.order, [2, 0, 1], "The picked sort applies to the new rows, and the old one never lands")
        XCTAssertEqual(tableView.numberOfRows, 3)
        XCTAssertEqual(tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("row"))?.width ?? 0, tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("row"))?.minWidth ?? -1)

        XCTAssertNil(coordinator.selectedRowsText(), "Nothing selected, nothing copied")
        tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        XCTAssertEqual(coordinator.selectedRowsText(), "c\t3\nb\t\"x\ty\"\n", "Shown order; a tab inside a cell is quoted")
        tableView.selectRowIndexes(IndexSet([2]), byExtendingSelection: false)
        XCTAssertEqual(coordinator.selectedRowsText(), "a\t\"say \"\"hi\"\"\"\n")
    }

    @MainActor
    func testThePreviewIsDrawnAgainOnlyWhenItsTableOrThemeChange() async throws {
        let model = try await makeModel()
        defer {
            model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        let table = DelimitedDocument.parse("a,b\n1,2\n", delimiter: UInt8(ascii: ","))
        func content(_ table: DelimitedTable?) -> TablePreviewContent { TablePreviewContent(fileName: "x.csv", table: table, style: MarkdownPreviewStyle(model)) }
        XCTAssertTrue(content(table) == content(table), "Nothing it draws changed")
        XCTAssertTrue(content(table) == content(DelimitedDocument.parse("a,b\n1,2\n", delimiter: UInt8(ascii: ","))), "The same text read again draws the same")
        XCTAssertFalse(content(table) == content(DelimitedDocument.parse("a,b\n1,3\n", delimiter: UInt8(ascii: ","))), "New text is drawn")
        let before = content(table)
        var appearance = model.appearance
        appearance.fontSize += 2
        XCTAssertTrue(model.applyAppearance(appearance))
        XCTAssertFalse(before == content(table), "A new font size is drawn")
    }

    @MainActor
    func testATableAtTheSizeLimitShowsSortsAndIgnoresUnrelatedChanges() async throws {
        let model = try await makeModel()
        defer {
            model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }

        for (name, rows) in [("short.tsv", 30), ("short.csv", 30), ("long.csv", Self.limitRows)] {
            let opened = await model.openInEditor(path: project + "/" + name, projectRoot: project)
            XCTAssertTrue(opened)
            let tab = try XCTUnwrap(model.editorTabs.values.joined().first { $0.fileName == name })
            XCTAssertTrue(tab.isTable)
            let host = NSHostingView(rootView: Host(model: model, id: tab.id).frame(width: 900, height: 700))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(tables(in: host).isEmpty, "\(name): nothing is parsed or built while the source is shown, so typing costs what it does in any file")

            // Time until the table shows.
            var started = ContinuousClock.now
            model.toggleEditorPreview(tab.id)
            try await waitFor(in: host) { self.tables(in: host).first.map { $0.numberOfRows == rows && $0.rows(in: $0.visibleRect).length > 0 } ?? false }
            let appear = milliseconds(since: started)
            let tableView = try XCTUnwrap(tables(in: host).first, "\(name): the table shows")
            let coordinator = try XCTUnwrap(tableView.delegate as? DelimitedTableView.Coordinator)
            XCTAssertEqual(tableView.numberOfRows, rows)
            XCTAssertEqual(tableView.tableColumns.count, 9, "\(name): a row number column and the file's eight")
            XCTAssertEqual(tableView.tableColumns[4].headerCell.alignment, .right, "\(name): a numeric column aligns right")
            XCTAssertEqual(tableView.frame.height, CGFloat(rows) * tableView.rowHeight, accuracy: 1, "\(name): the scroller is exact at once")
            var built = 0
            tableView.enumerateAvailableRowViews { _, _ in built += 1 }
            XCTAssertLessThan(built, 120, "\(name): only the rows on screen are built")
            XCTAssertLessThan(appear, 5000)

            // An unrelated change in the app redraws the tab's chrome, not the rows.
            let reloads = coordinator.reloads
            started = ContinuousClock.now
            model.errorMessage = "elsewhere"
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let unrelated = milliseconds(since: started)
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(coordinator.reloads, reloads, "\(name): a change elsewhere doesn't load the rows again")
            model.errorMessage = nil

            // A 2,000 pt scroll step.
            let scroll = try XCTUnwrap(tableView.enclosingScrollView)
            started = ContinuousClock.now
            tableView.scroll(NSPoint(x: 0, y: min(2000, max(0, tableView.frame.height - scroll.contentView.bounds.height))))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let scrollStep = milliseconds(since: started)

            // Sorting by amount, largest first: the view reorders, the text doesn't.
            let text = try XCTUnwrap(model.editorTab(tab.id)).text
            started = ContinuousClock.now
            tableView.sortDescriptors = [NSSortDescriptor(key: "c3", ascending: false)]
            try await waitFor(in: host) { coordinator.order != nil }
            let sortNumber = milliseconds(since: started)
            let order = try XCTUnwrap(coordinator.order)
            let amounts = order.prefix(50).map { Double(coordinator.table.rows[$0][3]) ?? -1 }
            XCTAssertEqual(amounts, amounts.sorted(by: >), "\(name): largest amounts first")
            XCTAssertEqual(model.editorTab(tab.id)?.text, text, "\(name): sorting never changes the text")
            started = ContinuousClock.now
            tableView.sortDescriptors = [NSSortDescriptor(key: "c1", ascending: true)]
            try await waitFor(in: host) { coordinator.order.map { $0 != order } ?? false }
            let sortText = milliseconds(since: started)
            // The sorts themselves, without the polling above (whose sleeps overshoot by tens of milliseconds).
            started = ContinuousClock.now
            _ = DelimitedTableView.Coordinator.sortedOrder(coordinator.table, column: 3, numeric: true, ascending: false)
            let sortNumberWork = milliseconds(since: started)
            started = ContinuousClock.now
            _ = DelimitedTableView.Coordinator.sortedOrder(coordinator.table, column: 1, numeric: false, ascending: true)
            let sortTextWork = milliseconds(since: started)

            // An edit while the source is shown, then the preview again.
            model.toggleEditorPreview(tab.id)
            host.layoutSubtreeIfNeeded()
            model.updateEditorText(tab.id, text + "99999,Zed,City,1.5,1,n,open,t\n")
            // The source view takes the new text first; only the preview is timed.
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            started = ContinuousClock.now
            model.toggleEditorPreview(tab.id)
            try await waitFor(in: host) { self.tables(in: host).first?.numberOfRows == rows + 1 }
            let reshow = milliseconds(since: started)
            XCTAssertEqual(tables(in: host).first?.numberOfRows, rows + 1, "\(name): the preview shows unsaved text")

            print(
                String(
                    format:
                        "FR-ED19 %@ (%d rows, %d bytes): appear %.0f ms, unrelated change %.1f ms, scroll step %.1f ms, sort number %.0f ms (work %.1f ms), sort text %.0f ms (work %.1f ms), re-show after edit %.0f ms",
                    name, rows, text.utf8.count, appear, unrelated, scrollStep, sortNumber, sortNumberWork, sortText, sortTextWork, reshow))
            window.contentView = nil
        }
    }
}
