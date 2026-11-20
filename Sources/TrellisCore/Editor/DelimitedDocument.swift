import Foundation

/// A CSV or TSV file read as a table for the editor's table preview (FR-ED17). The first row is the header, padded to the
/// widest row; data rows stay as long as the file has them (a missing cell reads as empty, see `cell`), so a wide header
/// over many short rows costs what the file holds, not rows × columns.
public struct DelimitedTable: Equatable, Sendable {
    public var header: [String]
    public var rows: [[String]]
    /// Columns whose every non-empty data cell is a number: they sort by value and align to the right.
    public var numericColumns: Set<Int>
    /// Rows past `maximumRows` were left out.
    public var rowsTruncated: Bool
    /// Cells past `maximumColumns` were left out.
    public var columnsTruncated: Bool
    public var truncated: Bool { rowsTruncated || columnsTruncated }
    public var columnCount: Int { header.count }

    public init(header: [String], rows: [[String]], numericColumns: Set<Int>, rowsTruncated: Bool = false, columnsTruncated: Bool = false) {
        (self.header, self.rows, self.numericColumns, self.rowsTruncated, self.columnsTruncated) = (header, rows, numericColumns, rowsTruncated, columnsTruncated)
    }

    /// A row's cell, empty past the row's end.
    public func cell(_ row: Int, _ column: Int) -> String { column < rows[row].count ? rows[row][column] : "" }
}

/// An RFC 4180 reader: quoted fields, `""` escapes, line breaks and delimiters inside quotes, LF, CRLF and CR line ends.
/// One pass over the UTF-8 bytes (the delimiters and quotes are ASCII), so hostile input stays linear; an unterminated
/// quote makes the rest of the file its field.
public enum DelimitedDocument {
    /// More rows than this aren't shown; the editor's 2 MB limit allows about a million one-character rows.
    public static let maximumRows = 100_000
    public static let maximumColumns = 1_000

    /// A tab for TSV; for CSV a comma, or a semicolon when the first line has more of them (spreadsheets in many locales).
    public static func delimiter(isTSV: Bool, text: String) -> UInt8 {
        if isTSV { return UInt8(ascii: "\t") }
        var commas = 0, semicolons = 0
        for byte in text.utf8.prefix(4096) {
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") { break }
            if byte == UInt8(ascii: ",") { commas += 1 } else if byte == UInt8(ascii: ";") { semicolons += 1 }
        }
        return semicolons > commas ? UInt8(ascii: ";") : UInt8(ascii: ",")
    }

    public static func parse(_ text: String, delimiter: UInt8, maximumRows: Int = maximumRows, maximumColumns: Int = maximumColumns) -> DelimitedTable {
        var text = text
        return text.withUTF8 { parse(bytes: $0, delimiter: delimiter, maximumRows: maximumRows, maximumColumns: maximumColumns) }
    }

    private static func parse(bytes all: UnsafeBufferPointer<UInt8>, delimiter: UInt8, maximumRows: Int, maximumColumns: Int) -> DelimitedTable {
        let quote = UInt8(ascii: "\""), lf = UInt8(ascii: "\n"), cr = UInt8(ascii: "\r")
        var start = 0
        if all.count >= 3, all[0] == 0xEF, all[1] == 0xBB, all[2] == 0xBF { start = 3 }
        var records: [[String]] = []
        var record: [String] = []
        var rowsTruncated = false, columnsTruncated = false, lastQuoted = false
        var widest = 0
        var escaped: [UInt8] = []
        var index = start
        let end = all.count
        // `maximumRows` data rows plus the header.
        let recordLimit = maximumRows + 1

        func addField(_ field: String) {
            if record.count < maximumColumns { record.append(field) } else { columnsTruncated = true }
        }
        func endRecord() {
            // A blank line isn't a row; a quoted empty value (`""`) is.
            guard record.count != 1 || !record[0].isEmpty || lastQuoted else { record.removeAll(keepingCapacity: true); return }
            widest = max(widest, record.count)
            records.append(record)
            record = []
            record.reserveCapacity(widest)
        }

        while index < end {
            if records.count >= recordLimit {
                // Only line ends left isn't more rows.
                while index < end, all[index] == lf || all[index] == cr { index += 1 }
                rowsTruncated = index < end
                break
            }
            lastQuoted = all[index] == quote
            if lastQuoted {
                // A quoted field: copy until a lone quote, turning `""` into `"`.
                escaped.removeAll(keepingCapacity: true)
                index += 1
                var runStart = index
                while index < end {
                    if all[index] == quote {
                        escaped.append(contentsOf: UnsafeBufferPointer(rebasing: all[runStart..<index]))
                        if index + 1 < end, all[index + 1] == quote {
                            escaped.append(quote); index += 2; runStart = index
                            continue
                        }
                        index += 1; runStart = -1
                        break
                    }
                    index += 1
                }
                // Unterminated: the rest of the file.
                if runStart >= 0 { escaped.append(contentsOf: UnsafeBufferPointer(rebasing: all[runStart..<index])) }
                // Anything between the closing quote and the delimiter is kept, as spreadsheets do.
                let tailStart = index
                while index < end, all[index] != delimiter, all[index] != lf, all[index] != cr { index += 1 }
                if index > tailStart { escaped.append(contentsOf: UnsafeBufferPointer(rebasing: all[tailStart..<index])) }
                addField(String(decoding: escaped, as: UTF8.self))
            } else {
                let fieldStart = index
                while index < end, all[index] != delimiter, all[index] != lf, all[index] != cr { index += 1 }
                addField(String(decoding: UnsafeBufferPointer(rebasing: all[fieldStart..<index]), as: UTF8.self))
            }
            guard index < end else { endRecord(); break }
            let byte = all[index]
            index += 1
            if byte == delimiter {
                // A delimiter at the very end leaves one empty field.
                if index == end { addField(""); endRecord() }
                continue
            }
            if byte == cr, index < end, all[index] == lf { index += 1 }
            endRecord()
        }

        guard var header = records.first else { return DelimitedTable(header: [], rows: [], numericColumns: [], rowsTruncated: rowsTruncated, columnsTruncated: columnsTruncated) }
        let width = widest
        if header.count < width { header.append(contentsOf: repeatElement("", count: width - header.count)) }
        let rows = Array(records.dropFirst())
        return DelimitedTable(header: header, rows: rows, numericColumns: numericColumns(rows, width: width), rowsTruncated: rowsTruncated, columnsTruncated: columnsTruncated)
    }

    /// Columns with at least one number and nothing else but empty cells. One pass over the cells the file has.
    static func numericColumns(_ rows: [[String]], width: Int) -> Set<Int> {
        var seen = [Bool](repeating: false, count: width), other = [Bool](repeating: false, count: width)
        for row in rows {
            for (column, cell) in row.enumerated() where !other[column] && !cell.isEmpty {
                if number(cell) != nil { seen[column] = true } else { other[column] = true }
            }
        }
        return Set((0..<width).filter { seen[$0] && !other[$0] })
    }

    /// A plain, finite decimal number, with optional sign, fraction, exponent and surrounding blanks; not `inf`, `nan` or hex.
    public static func number(_ cell: String) -> Double? {
        var text = Substring(cell)
        while text.first == " " || text.first == "\t" { text = text.dropFirst() }
        while text.last == " " || text.last == "\t" { text = text.dropLast() }
        guard let first = text.utf8.first, first == UInt8(ascii: "-") || first == UInt8(ascii: "+") || first == UInt8(ascii: ".") || (0x30...0x39).contains(first),
            !text.utf8.contains(where: { $0 == UInt8(ascii: "x") || $0 == UInt8(ascii: "X") || $0 == UInt8(ascii: "n") || $0 == UInt8(ascii: "N") || $0 == UInt8(ascii: "i") || $0 == UInt8(ascii: "I") })
        else { return nil }
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }
}
