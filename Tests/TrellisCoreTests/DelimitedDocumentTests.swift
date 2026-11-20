import XCTest
@testable import TrellisCore

/// The CSV/TSV reader behind the table preview (FR-ED17, FR-ED19): RFC 4180 fields, ragged rows, caps and linear time.
final class DelimitedDocumentTests: XCTestCase {
    private let comma = UInt8(ascii: ","), tab = UInt8(ascii: "\t"), semicolon = UInt8(ascii: ";")

    func testQuotedFieldsEscapesAndLineEnds() {
        let table = DelimitedDocument.parse("name,note\r\n\"Doe, Jane\",\"said \"\"hi\"\"\"\nBob,\"two\nlines\"\rEve,plain\n", delimiter: comma)
        XCTAssertEqual(table.header, ["name", "note"])
        XCTAssertEqual(table.rows, [["Doe, Jane", "said \"hi\""], ["Bob", "two\nlines"], ["Eve", "plain"]], "CRLF, LF and CR all end a row")
        XCTAssertFalse(table.truncated)
    }

    func testBOMBlankLinesRaggedRowsAndEmptyFields() {
        let table = DelimitedDocument.parse("\u{FEFF}a,,c\n\n1,2\n1,2,3,4\n,\nx,y,", delimiter: comma)
        XCTAssertEqual(table.header, ["a", "", "c", ""], "The BOM is dropped and the header is padded to the widest row")
        XCTAssertEqual(table.rows, [["1", "2"], ["1", "2", "3", "4"], ["", ""], ["x", "y", ""]], "A blank line isn't a row; a trailing delimiter leaves an empty cell")
        XCTAssertEqual(table.columnCount, 4)
        XCTAssertEqual(table.cell(0, 3), "", "A short row reads empty past its end, without being padded")
        XCTAssertEqual(DelimitedDocument.parse("v\n\"\"\n\nx\n", delimiter: comma).rows, [[""], ["x"]], "A quoted empty value is a row; a blank line isn't")
    }

    func testTabsAndTheSemicolonGuess() {
        XCTAssertEqual(DelimitedDocument.parse("a\tb, c\n1\t2\n", delimiter: tab).rows, [["1", "2"]])
        XCTAssertEqual(DelimitedDocument.delimiter(isTSV: true, text: "a,b"), tab)
        XCTAssertEqual(DelimitedDocument.delimiter(isTSV: false, text: "a;b;c\n1,5;2,5;3\n"), semicolon, "European spreadsheets write ;")
        XCTAssertEqual(DelimitedDocument.delimiter(isTSV: false, text: "a,b;c\n"), comma)
        XCTAssertEqual(DelimitedDocument.delimiter(isTSV: false, text: ""), comma)
    }

    func testAnUnterminatedQuoteTakesTheRestAndTextAfterAQuoteIsKept() {
        XCTAssertEqual(DelimitedDocument.parse("h\n\"open,\nstill", delimiter: comma).rows, [["open,\nstill"]])
        XCTAssertEqual(DelimitedDocument.parse("h,i\n\"a\"b,c\n", delimiter: comma).rows, [["ab", "c"]])
        XCTAssertEqual(DelimitedDocument.parse("", delimiter: comma), DelimitedTable(header: [], rows: [], numericColumns: []))
    }

    func testNumericColumns() {
        let table = DelimitedDocument.parse("id,price,name,mixed,blank\n1, 2.50 ,a,1,\n-3,1e3,b,x,\n,+.5,c,2,\n", delimiter: comma)
        XCTAssertEqual(table.numericColumns, [0, 1], "Empty cells don't stop a column being numeric; an all-empty one isn't")
        for text in ["nan", "inf", "-Infinity", "0x10", "1,5", "", "  ", "1e999"] { XCTAssertNil(DelimitedDocument.number(text), text) }
        XCTAssertEqual(DelimitedDocument.number("\t7\t"), 7)
        XCTAssertEqual(DelimitedDocument.number(" -1.5e2 "), -150)
    }

    func testCapsMarkTheTableTruncated() {
        let rows = DelimitedDocument.parse("h\n" + String(repeating: "x\n", count: 50), delimiter: comma, maximumRows: 10)
        XCTAssertEqual(rows.rows.count, 10)
        XCTAssertTrue(rows.rowsTruncated)
        XCTAssertFalse(rows.columnsTruncated)
        let wide = DelimitedDocument.parse(String(repeating: "a,", count: 20) + "a\n", delimiter: comma, maximumColumns: 5)
        XCTAssertEqual(wide.columnCount, 5)
        XCTAssertTrue(wide.columnsTruncated)
        XCTAssertFalse(wide.rowsTruncated)
        XCTAssertFalse(DelimitedDocument.parse("h\n" + String(repeating: "x\n", count: 10), delimiter: comma, maximumRows: 10).truncated, "Exactly at the cap")
        XCTAssertFalse(DelimitedDocument.parse("h\n" + String(repeating: "x\n", count: 10) + "\r\n\n", delimiter: comma, maximumRows: 10).truncated, "Only line ends after it")
    }

    func testHostileInputStaysLinear() {
        let megabyte = 1 << 20
        let started = Date()
        for text in [
            String(repeating: "\"", count: megabyte), String(repeating: ",", count: megabyte), String(repeating: "\n", count: megabyte),
            String(repeating: "\"\"", count: megabyte / 2), String(repeating: "x", count: 2 * megabyte), String(repeating: "\"a\"\"\",", count: megabyte / 6)
        ] {
            _ = DelimitedDocument.parse(text, delimiter: comma)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// A wide header over many short rows costs what the file holds, not rows × columns.
    func testAWideHeaderOverShortRowsStaysSmall() {
        let text = String(repeating: "h,", count: 999) + "h\n" + String(repeating: "a\n", count: 100_000)
        let started = Date()
        let table = DelimitedDocument.parse(text, delimiter: comma)
        XCTAssertEqual(table.columnCount, 1000)
        XCTAssertEqual(table.rows.count, 100_000)
        XCTAssertEqual(table.rows.reduce(0) { $0 + $1.count }, 100_000, "Rows aren't padded")
        XCTAssertEqual(table.numericColumns, [], "A column of letters isn't numeric")
        // Rows × columns is 100 million cells, minutes of work; a CI runner's debug build takes 5 s for what is 1 s here.
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
    }

    /// FR-ED19: a file at the editor's 2 MB limit reads in well under a second, even in a debug build.
    func testATwoMegabyteFileParsesQuickly() {
        let text = Self.sampleCSV(rows: Self.limitRows)
        XCTAssertGreaterThan(text.utf8.count, 1_950_000)
        XCTAssertLessThan(text.utf8.count, EditorDocument.maximumBytes, "Just under the editor's limit")
        let started = Date()
        let table = DelimitedDocument.parse(text, delimiter: comma)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(table.rows.count, Self.limitRows)
        XCTAssertEqual(table.columnCount, 8)
        XCTAssertEqual(table.numericColumns, [0, 3, 4])
        XCTAssertLessThan(elapsed, 3)
    }

    func testEditorLanguages() {
        XCTAssertEqual(EditorLanguage.detect(fileName: "data.CSV", firstLine: "").id, EditorLanguage.csv.id)
        XCTAssertEqual(EditorLanguage.detect(fileName: "data.tsv", firstLine: "").id, EditorLanguage.tsv.id)
        XCTAssertEqual(EditorLanguage.detect(fileName: "data.tab", firstLine: "").id, EditorLanguage.tsv.id)
        XCTAssertTrue(EditorLanguage.isCode(fileName: "data.csv"), "A double click opens it in the editor (FR-ED18)")
        XCTAssertTrue(EditorLanguage.isTable(fileName: "data.tsv"))
        XCTAssertFalse(EditorLanguage.isTable(fileName: "README.md"))
        XCTAssertTrue(EditorLanguage.hasPreview(EditorLanguage.markdown))
        XCTAssertTrue(EditorLanguage.hasPreview(EditorLanguage.csv))
        XCTAssertFalse(EditorLanguage.hasPreview(EditorLanguage.swift))
    }

    /// Rows that make `sampleCSV` just under the editor's 2 MB limit.
    static let limitRows = 31_500

    /// About 65 bytes a row: an id, quoted text with commas and quotes, a multiline cell every 50 rows, two numeric columns.
    static func sampleCSV(rows: Int) -> String {
        var text = "id,name,city,amount,score,note,status,tag\n"
        text.reserveCapacity(rows * 52)
        for row in 0..<rows {
            let note = row % 50 == 0 ? "\"first line\nsecond, line\"" : "\"says \"\"ok\"\", fine\""
            text += "\(row),Person \(row % 977),City \(row % 131),\(row * 7 % 10_000).25,\(row % 100),\(note),\(row % 3 == 0 ? "open" : "closed"),t\(row % 17)\n"
        }
        return text
    }
}
