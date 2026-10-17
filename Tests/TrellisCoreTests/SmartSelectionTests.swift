import XCTest
@testable import TrellisCore

final class SmartSelectionTests: XCTestCase {
    /// The selected text when clicking the first occurrence of `target` (offset `at` within it).
    private func select(_ text: String, clicking target: String, at index: Int = 0) -> (SmartSelectionKind, String)? {
        let characters = Array(text)
        let start = text.distance(from: text.startIndex, to: text.range(of: target)!.lowerBound)
        guard let match = SmartSelection.match(in: text, at: start + index) else { return nil }
        return (match.kind, String(characters[match.range]))
    }

    func testURLWithBalancedParensAndTrailingPunctuation() {
        let text = "see (https://en.wikipedia.org/wiki/A_(b)). Next"
        XCTAssertEqual(select(text, clicking: "wikipedia")?.1, "https://en.wikipedia.org/wiki/A_(b)")
        XCTAssertEqual(select(text, clicking: "https")?.0, .url)
        XCTAssertEqual(select("open https://example.com/x?a=1&b=2, then", clicking: "b=2")?.1, "https://example.com/x?a=1&b=2")
        XCTAssertEqual(select("mail mailto:a@example.com.", clicking: "mailto")?.1, "mailto:a@example.com")
    }

    func testEmailSelectsWholeAddress() {
        XCTAssertEqual(select("from <first.last+tag@mail.example.co.uk>:", clicking: "last")?.1, "first.last+tag@mail.example.co.uk")
        XCTAssertEqual(select("from <first.last+tag@mail.example.co.uk>:", clicking: "last")?.0, .email)
    }

    func testFilePathsWithLineAndColumn() {
        XCTAssertEqual(select("error at /a/b.swift:12:5: oops", clicking: "b.swift")?.1, "/a/b.swift:12:5")
        XCTAssertEqual(select("cd ~/x/y now", clicking: "x")?.1, "~/x/y")
        XCTAssertEqual(select("run ./r please", clicking: "r ")?.1, "./r")
        XCTAssertEqual(select("in ../q/z.txt:3", clicking: "z.txt")?.1, "../q/z.txt:3")
        XCTAssertEqual(select("src/foo.c:10: warning", clicking: "foo")?.1, "src/foo.c:10")
        XCTAssertEqual(select("src/foo.c:10: warning", clicking: "foo")?.0, .filePath)
        XCTAssertEqual(select("'/tmp/a b'", clicking: "tmp")?.1, "/tmp/a", "Spaces end an unquoted path")
    }

    func testIPv4WithPortAndIPv6NotTimes() {
        XCTAssertEqual(select("host 192.168.1.20:8080.", clicking: "168")?.1, "192.168.1.20:8080")
        XCTAssertEqual(select("host 192.168.1.20:8080.", clicking: "168")?.0, .ipv4)
        XCTAssertNotEqual(select("bad 999.1.1.1 x", clicking: "999")?.0, .ipv4)
        XCTAssertEqual(select("addr fe80::1ff:fe23:4567:890a end", clicking: "fe23")?.1, "fe80::1ff:fe23:4567:890a")
        XCTAssertEqual(select("addr 2001:db8:0:0:0:0:2:1 end", clicking: "db8")?.0, .ipv6)
        XCTAssertNil(select("at 12:34:56 today", clicking: "34"))
    }

    func testUUIDAndGitHash() {
        let uuid = "123E4567-E89B-12D3-A456-426614174000"
        XCTAssertEqual(select("id=\(uuid);", clicking: "E89B")?.1, uuid)
        XCTAssertEqual(select("id=\(uuid);", clicking: "E89B")?.0, .uuid)
        XCTAssertEqual(select("commit a1b2c3d4e5 (HEAD)", clicking: "c3")?.1, "a1b2c3d4e5")
        XCTAssertEqual(select("commit a1b2c3d4e5 (HEAD)", clicking: "c3")?.0, .gitHash)
        XCTAssertNil(select("the deadbeef cafe", clicking: "beef"), "Hex-looking words without a digit stay words")
    }

    func testQuotedStringOnlyFromQuoteCharacter() {
        let text = #"say "hello there" now"#
        XCTAssertEqual(select(text, clicking: "\"hello")?.1, "\"hello there\"")
        XCTAssertEqual(select(text, clicking: "e\" ", at: 1)?.0, .quotedString)
        XCTAssertNil(select(text, clicking: "hello", at: 1), "Inside the quotes, ordinary word selection applies")
    }

    func testPrecedencePrefersURLOverPathAndLongestMatch() {
        XCTAssertEqual(select("go https://x.org/a/b.txt", clicking: "a/b")?.0, .url)
        XCTAssertEqual(select("go https://x.org/a/b.txt", clicking: "a/b")?.1, "https://x.org/a/b.txt")
        XCTAssertEqual(select("go user@example.com", clicking: "user")?.0, .email)
    }

    func testNoMatchReturnsNilAndTrimmedRangeMustContainClick() {
        XCTAssertNil(select("plain words only", clicking: "words"))
        XCTAssertNil(SmartSelection.match(in: "", at: 0))
        XCTAssertNil(SmartSelection.match(in: "abc", at: 5))
        XCTAssertNil(select("(https://x.org)", clicking: ")"), "Clicking trimmed punctuation does not select the URL")
    }

    func testGraphemeOffsetsWithEmojiAndCombining() {
        let text = "👩‍💻 café → /tmp/e\u{301}t\u{E9}/file.txt ok"
        let match = select(text, clicking: "/tmp")
        XCTAssertEqual(match?.1, "/tmp/e\u{301}t\u{E9}/file.txt")
        let characters = Array(text)
        let offset = characters.firstIndex(of: "→")!
        XCTAssertNil(SmartSelection.match(in: text, at: offset))
    }

    func testTrimmedDropsPunctuationAndUnbalancedBrackets() {
        XCTAssertEqual(SmartSelection.trimmed("(src/a.c:3:)."), "src/a.c:3")
        XCTAssertEqual(SmartSelection.trimmed("\"/tmp/x\","), "/tmp/x")
        XCTAssertEqual(SmartSelection.trimmed("f(a)"), "f(a)")
    }

    func testPathologicalInputIsFast() {
        for text in [
            String(repeating: "(", count: 10_000), String(repeating: ".", count: 10_000), "[" + String(repeating: "a", count: 10_000),
            String(repeating: "a/", count: 5_000), String(repeating: "a@", count: 5_000), String(repeating: "1:", count: 5_000)
        ] {
            let start = Date()
            _ = SmartSelection.match(in: text, at: text.count / 2)
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "Slow on \(text.prefix(4))…")
        }
    }

    func testLongLinesLookOnlyNearTheClick() {
        let filler = String(repeating: "x ", count: 5_000)
        let text = filler + "/var/log/system.log " + filler
        let offset = Array(filler).count + 5
        let match = SmartSelection.match(in: text, at: offset)
        XCTAssertEqual(match.map { String(Array(text)[$0.range]) }, "/var/log/system.log")
    }
}
