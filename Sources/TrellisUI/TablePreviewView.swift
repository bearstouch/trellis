import AppKit
import SwiftUI
import TrellisCore

/// A CSV or TSV tab's table preview (FR-ED17): a native, view-based table in the theme's colors and terminal font. Like the
/// Markdown preview (FR-ED13) it parses off the main thread only while shown, and hands plain values to an `Equatable`
/// view, so a change elsewhere in the app doesn't reload it (FR-ED19). Sorting reorders the view, never the text.
struct TablePreviewView: View {
    @ObservedObject var model: AppWorkspaceModel
    let tab: EditorTab
    /// Parsing runs only while the preview is on screen.
    let visible: Bool
    @State private var table: DelimitedTable?

    private struct ParseKey: Equatable {
        let text: String
        let tsv: Bool
        let visible: Bool
    }

    private var isTSV: Bool { tab.language.id == EditorLanguage.tsv.id }

    var body: some View {
        TablePreviewContent(fileName: tab.fileName, table: table, style: MarkdownPreviewStyle(model)).equatable()
            .task(id: ParseKey(text: tab.text, tsv: isTSV, visible: visible)) { await parse() }
    }

    /// The first table shows at once; while one is shown, a large text is read again a moment after typing stops.
    private func parse() async {
        guard visible else { return }
        let text = tab.text, tsv = isTSV
        if table != nil, text.utf8.count > 65_536 {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
        }
        let parsed = await Task.detached(priority: .userInitiated) { DelimitedDocument.parse(text, delimiter: DelimitedDocument.delimiter(isTSV: tsv, text: text)) }.value
        guard !Task.isCancelled else { return }
        table = parsed
    }
}

/// The table with its notes. It compares plain values (`.equatable()`): the app model changes on every keystroke, tab
/// switch and progress report anywhere in the app, and none of those should reach the table.
struct TablePreviewContent: View, Equatable {
    let fileName: String
    let table: DelimitedTable?
    let style: MarkdownPreviewStyle

    nonisolated static func == (a: TablePreviewContent, b: TablePreviewContent) -> Bool { a.fileName == b.fileName && a.style == b.style && a.table == b.table }

    var body: some View {
        VStack(spacing: 0) {
            if let table {
                if table.truncated {
                    Text(truncationNote(table))
                        .font(.caption).foregroundStyle(style.muted).padding(.horizontal, 12).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if table.columnCount == 0 {
                    Text(L("This file has no rows.")).foregroundStyle(style.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DelimitedTableView(table: table, style: style, fileName: fileName)
                }
            } else {
                Color.clear
            }
        }
        .background(Color(nsColor: NSColor(rgb: style.palette.background)))
    }

    /// Names only the cap that was reached.
    private func truncationNote(_ table: DelimitedTable) -> String {
        let rows = DelimitedDocument.maximumRows.formatted(), columns = DelimitedDocument.maximumColumns.formatted()
        switch (table.rowsTruncated, table.columnsTruncated) {
        case (true, true): return L("Only the first %1$@ rows and %2$@ columns are shown.", rows, columns)
        case (true, false): return L("Only the first %@ rows are shown.", rows)
        default: return L("Only the first %@ columns are shown.", columns)
        }
    }
}

/// `NSTableView` builds only the rows on screen, so a 2 MB file (tens of thousands of rows) shows at once with an exact
/// scroller: every row has the same height.
struct DelimitedTableView: NSViewRepresentable {
    let table: DelimitedTable
    let style: MarkdownPreviewStyle
    let fileName: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = CopyingTableView()
        tableView.headerView = NSTableHeaderView()
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.usesAutomaticRowHeights = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.style = .plain
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.copyRows = { [weak coordinator = context.coordinator] in coordinator?.selectedRowsText() }
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.tableView = tableView
        context.coordinator.scrollView = scroll
        context.coordinator.update(table: table, style: style, fileName: fileName)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(table: table, style: style, fileName: fileName) }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?
        private(set) var table = DelimitedTable(header: [], rows: [], numericColumns: [])
        private var style: MarkdownPreviewStyle?
        /// The rows in their shown order when sorted; nil in file order.
        private(set) var order: [Int]?
        /// How many times the rows were loaded again, for FR-ED19's tests.
        private(set) var reloads = 0
        private var sortGeneration = 0
        private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        private var foreground = NSColor.labelColor, muted = NSColor.secondaryLabelColor, stripe = NSColor.clear, background = NSColor.textBackgroundColor
        private static let rowNumberID = NSUserInterfaceItemIdentifier("row")
        private static let cellID = NSUserInterfaceItemIdentifier("cell")

        func update(table: DelimitedTable, style: MarkdownPreviewStyle, fileName: String) {
            guard let tableView else { return }
            tableView.setAccessibilityLabel(L("Table preview of %@", fileName))
            let styleChanged = style != self.style, tableChanged = table != self.table
            guard styleChanged || tableChanged else { return }
            let columnsChanged = styleChanged || table.header != self.table.header || table.numericColumns != self.table.numericColumns
            (self.table, self.style) = (table, style)
            if styleChanged { applyStyle(style) }
            if columnsChanged {
                rebuildColumns()
            } else if tableChanged, let number = tableView.tableColumn(withIdentifier: Self.rowNumberID) {
                // More rows may need more digits.
                (number.width, number.minWidth) = (rowNumberWidth(), rowNumberWidth())
            }
            if tableChanged {
                // A sort still running was for the old rows; the one picked is applied to the new rows.
                order = nil
                sortGeneration += 1
                if tableView.sortDescriptors.first != nil { sort() }
            }
            reload()
        }

        private func reload() {
            reloads += 1
            tableView?.reloadData()
        }

        private func applyStyle(_ style: MarkdownPreviewStyle) {
            guard let tableView else { return }
            font = NSFont(name: style.fontName, size: style.fontSize) ?? .monospacedSystemFont(ofSize: style.fontSize, weight: .regular)
            background = NSColor(rgb: style.palette.background)
            foreground = NSColor(rgb: style.palette.foreground)
            muted = foreground.withAlphaComponent(0.6)
            stripe = foreground.withAlphaComponent(0.04)
            // The header, scrollers and selection follow the theme's lightness.
            let dark = Self.luminance(background) < 0.5
            scrollView?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            tableView.backgroundColor = background
            scrollView?.backgroundColor = background
            tableView.gridColor = NSColor(style.border).withAlphaComponent(0.45)
            tableView.rowHeight = ceil(font.ascender - font.descender + font.leading) + 6
        }

        /// Typed step by step: as one expression it took the CI machine's type checker too long.
        private static func luminance(_ color: NSColor) -> CGFloat {
            guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
            let red: CGFloat = 0.299 * rgb.redComponent
            let green: CGFloat = 0.587 * rgb.greenComponent
            let blue: CGFloat = 0.114 * rgb.blueComponent
            return red + green + blue
        }

        private var digitWidth: CGFloat { ("0" as NSString).size(withAttributes: [.font: font]).width }
        private func rowNumberWidth() -> CGFloat { CGFloat(max(2, String(table.rows.count).count)) * digitWidth + 2 * Self.padding + 4 }
        private static let padding: CGFloat = 6

        private func rebuildColumns() {
            guard let tableView else { return }
            let sortKey = tableView.sortDescriptors.first
            for column in tableView.tableColumns { tableView.removeTableColumn(column) }
            let digitWidth = digitWidth
            let headerFont = NSFont.systemFont(ofSize: max(10, (style?.fontSize ?? 12) - 1), weight: .semibold)

            let number = NSTableColumn(identifier: Self.rowNumberID)
            number.title = "#"
            number.headerToolTip = L("Row number")
            number.headerCell.setAccessibilityLabel(L("Row number"))
            number.headerCell.alignment = .center
            number.headerCell.font = headerFont
            number.width = rowNumberWidth()
            number.minWidth = number.width
            number.resizingMask = []
            tableView.addTableColumn(number)

            // Widths from the header and a sample of rows, never by measuring every cell.
            let sample = table.rows.prefix(200)
            for index in 0..<table.columnCount {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
                let title = table.header[index].isEmpty ? L("Column %d", index + 1) : table.header[index]
                column.title = title
                column.headerToolTip = title
                column.headerCell.font = headerFont
                column.headerCell.alignment = .center
                column.sortDescriptorPrototype = NSSortDescriptor(key: "c\(index)", ascending: true)
                let characters = sample.reduce(min(title.count, 40)) { max($0, index < $1.count ? min($1[index].utf8.count, 40) : 0) }
                column.width = max(60, CGFloat(max(3, characters)) * digitWidth + 2 * Self.padding + 8)
                column.minWidth = 40
                column.maxWidth = 2000
                tableView.addTableColumn(column)
            }
            // A sort on a column that is still there is kept; the order is computed again by `update`.
            if let key = sortKey?.key, tableView.tableColumns.contains(where: { $0.identifier.rawValue == key }) {
                tableView.sortDescriptors = [sortKey!]
            } else if sortKey != nil {
                order = nil
                tableView.sortDescriptors = []
            }
        }

        // MARK: Sorting

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard tableView.sortDescriptors.first?.key != oldDescriptors.first?.key || tableView.sortDescriptors.first?.ascending != oldDescriptors.first?.ascending else { return }
            sort()
        }

        /// Sorts off the main thread; a newer sort or table wins over one still running.
        private func sort() {
            sortGeneration += 1
            let generation = sortGeneration
            guard let descriptor = tableView?.sortDescriptors.first, let key = descriptor.key, key.hasPrefix("c"), let column = Int(key.dropFirst()), column < table.columnCount else {
                if order != nil { order = nil; reload() }
                return
            }
            let table = table, numeric = table.numericColumns.contains(column), ascending = descriptor.ascending
            Task { [weak self] in
                let sorted = await Task.detached(priority: .userInitiated) { Self.sortedOrder(table, column: column, numeric: numeric, ascending: ascending) }.value
                guard let self, self.sortGeneration == generation else { return }
                self.order = sorted
                self.reload()
            }
        }

        /// Row indexes in sorted order: numbers by value, text as Finder sorts names; empty cells last either way, and
        /// equal cells keep their file order.
        nonisolated static func sortedOrder(_ table: DelimitedTable, column: Int, numeric: Bool, ascending: Bool) -> [Int] {
            let rows = table.rows.indices
            if numeric {
                let keys = rows.map { DelimitedDocument.number(table.cell($0, column)) }
                return rows.sorted { a, b in
                    switch (keys[a], keys[b]) {
                    case (nil, nil): return a < b
                    case (nil, _): return false
                    case (_, nil): return true
                    case (let x?, let y?): return x == y ? a < b : (ascending ? x < y : x > y)
                    }
                }
            }
            let keys = rows.map { table.cell($0, column) as NSString }
            return rows.sorted { a, b in
                let (x, y) = (keys[a], keys[b])
                if x.length == 0 || y.length == 0 { return x.length == y.length ? a < b : y.length == 0 }
                switch x.localizedStandardCompare(y as String) {
                case .orderedSame: return a < b
                case .orderedAscending: return ascending
                case .orderedDescending: return !ascending
                }
            }
        }

        // MARK: Rows

        func numberOfRows(in tableView: NSTableView) -> Int { table.rows.count }

        /// The row of the file shown at `row`, or nil when a stale index (a selection, a sort for other rows) is out of range.
        private func dataRow(_ row: Int) -> Int? {
            let dataRow = order.map { $0.indices.contains(row) ? $0[row] : -1 } ?? row
            return table.rows.indices.contains(dataRow) ? dataRow : nil
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? PreviewCell) ?? PreviewCell(identifier: Self.cellID)
            cell.field.font = font
            cell.field.toolTip = nil
            guard let dataRow = dataRow(row) else {
                cell.show("", alignment: .left, color: foreground)
                return cell
            }
            if tableColumn.identifier == Self.rowNumberID {
                cell.show(String(dataRow + 1), alignment: .right, color: muted)
                return cell
            }
            let column = Int(tableColumn.identifier.rawValue.dropFirst()) ?? 0
            let value = table.cell(dataRow, column)
            let multiline = value.utf8.contains { $0 == 0x0A || $0 == 0x0D }
            cell.show(multiline ? value.split(whereSeparator: \.isNewline).joined(separator: " ↵ ") : value, alignment: table.numericColumns.contains(column) ? .right : .left, color: foreground)
            cell.field.toolTip = multiline || value.utf8.count > 40 ? value : nil
            return cell
        }

        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) { rowView.backgroundColor = row % 2 == 1 ? stripe : background }

        /// The selected rows in their shown order, tab-separated; a cell with a tab, line break or quote is quoted.
        func selectedRowsText() -> String? {
            guard let tableView, !tableView.selectedRowIndexes.isEmpty else { return nil }
            func cell(_ value: String) -> String {
                value.utf8.contains { $0 == 0x09 || $0 == 0x0A || $0 == 0x0D || $0 == 0x22 } ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
            }
            return tableView.selectedRowIndexes.compactMap { row in
                dataRow(row).map { dataRow in (0..<table.columnCount).map { cell(table.cell(dataRow, $0)) }.joined(separator: "\t") }
            }
            .joined(separator: "\n") + "\n"
        }
    }
}

/// A cell's text, inset from the grid, in the theme's color until its row is selected.
final class PreviewCell: NSTableCellView {
    let field = NSTextField(labelWithString: "")
    private var color = NSColor.labelColor

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        addSubview(field)
        textField = field
    }

    /// Frames, not constraints: Auto Layout in every cell made scrolling a large table about half again as slow.
    override func layout() {
        super.layout()
        // From the font, not `intrinsicContentSize`, which measures the text on every layout.
        var height: CGFloat = 16
        if let font = field.font {
            let line: CGFloat = font.ascender - font.descender + font.leading
            height = ceil(line) + 2
        }
        let top: CGFloat = ((bounds.height - height) / 2).rounded()
        field.frame = NSRect(x: 6, y: top, width: max(0, bounds.width - 12), height: height)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ text: String, alignment: NSTextAlignment, color: NSColor) {
        field.stringValue = text
        field.alignment = alignment
        self.color = color
        field.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : color
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { field.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : color }
    }
}

/// ⌘C copies the selected rows (FR-ED17).
final class CopyingTableView: NSTableView, NSMenuItemValidation {
    var copyRows: (() -> String?)?

    func validateMenuItem(_ item: NSMenuItem) -> Bool { item.action == #selector(copy(_:)) ? !selectedRowIndexes.isEmpty : true }

    @objc func copy(_ sender: Any?) {
        guard let text = copyRows?() else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
