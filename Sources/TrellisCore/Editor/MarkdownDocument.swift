import Foundation

public enum MarkdownAlignment: Equatable, Sendable { case leading, center, trailing }

public struct MarkdownListItem: Equatable, Sendable {
    /// Nil for a plain item; true or false for a task item (`- [x]`, `- [ ]`).
    public var task: Bool?
    public var blocks: [MarkdownBlock]
    public init(task: Bool? = nil, blocks: [MarkdownBlock]) { self.task = task; self.blocks = blocks }
}

/// One block of a Markdown preview (FR-ED12). Text is raw inline Markdown; the view renders emphasis, code and links.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, start: Int, items: [MarkdownListItem])
    case quote([MarkdownBlock])
    case code(language: String?, text: String)
    case table(header: [String], alignments: [MarkdownAlignment], rows: [[String]])
    case rule
    /// Raw HTML, shown as text and never interpreted.
    case html(String)
}

/// A small, line-based Markdown reader for the editor's preview (FR-ED12): the common CommonMark and GitHub blocks, not
/// every corner of the spec. Each line is looked at a bounded number of times per nesting level, and nesting stops at
/// `maximumDepth`, so any file is read quickly.
public enum MarkdownDocument {
    public static let maximumDepth = 16

    public static func parse(_ text: String) -> [MarkdownBlock] {
        // `\r\n` is one Character in Swift, so it is a separator of its own.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map { line -> String in
            var line = String(line)
            if line.hasSuffix("\r") { line.removeLast() }
            // Leading tabs count as four spaces, as for indentation.
            let leading = line.prefix { $0 == "\t" }.count
            return leading == 0 ? line : String(repeating: " ", count: leading * 4) + line.dropFirst(leading)
        }
        return blocks(lines[...], depth: 0)
    }

    /// The `#anchor` GitHub gives a heading: lowercased, spaces to `-`, punctuation dropped.
    public static func slug(_ plainHeading: String) -> String {
        var slug = ""
        for character in plainHeading.lowercased() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                slug.append(character)
            } else if character == " " {
                slug.append("-")
            }
        }
        return slug
    }

    // MARK: Lines

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
    private static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " } }
    private static func dropIndent(_ line: String, _ count: Int) -> String { String(line.dropFirst(min(count, indent(line)))) }

    private static func fence(_ line: String) -> (marker: Character, length: Int, info: String)? {
        guard indent(line) <= 3 else { return nil }
        let body = line.drop { $0 == " " }
        guard let marker = body.first, marker == "`" || marker == "~" else { return nil }
        let length = body.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = body.dropFirst(length).trimmingCharacters(in: .whitespaces)
        if marker == "`", info.contains("`") { return nil }
        return (marker, length, info)
    }

    private static func heading(_ line: String) -> (Int, String)? {
        guard indent(line) <= 3 else { return nil }
        let body = line.drop { $0 == " " }
        let level = body.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = body.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of `#` after a space is not part of the text.
        let closing = text.reversed().prefix { $0 == "#" }.count
        if closing > 0, closing == text.count || text.dropLast(closing).last == " " { text = String(text.dropLast(closing)).trimmingCharacters(in: .whitespaces) }
        return (level, text)
    }

    private static func isRule(_ line: String) -> Bool {
        guard indent(line) <= 3 else { return false }
        let marks = line.filter { $0 != " " }
        guard let first = marks.first, "-*_".contains(first), marks.count >= 3 else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func quoteContent(_ line: String) -> String? {
        guard indent(line) <= 3 else { return nil }
        let body = line.drop { $0 == " " }
        guard body.first == ">" else { return nil }
        let rest = body.dropFirst()
        return String(rest.first == " " ? rest.dropFirst() : rest)
    }

    /// A list marker: its kind (a bullet character, or `.`/`)` for ordered), the number, and where the item's text starts.
    private static func listMarker(_ line: String) -> (kind: Character, ordered: Bool, number: Int, contentIndent: Int)? {
        let spaces = indent(line)
        guard spaces <= 3 else { return nil }
        let body = Array(line.dropFirst(spaces))
        var width: Int, kind: Character, number = 1, ordered = false
        if let first = body.first, "-*+".contains(first) {
            width = 1; kind = first
        } else {
            let digits = body.prefix { $0.isASCII && $0.isNumber }.count
            guard (1...9).contains(digits), digits < body.count, body[digits] == "." || body[digits] == ")" else { return nil }
            width = digits + 1; kind = body[digits]; ordered = true
            number = Int(String(body[..<digits])) ?? 1
        }
        // The marker is followed by a space, or ends the line.
        guard width == body.count || body[width] == " " else { return nil }
        let after = body.dropFirst(width).prefix { $0 == " " }.count
        let gap = width == body.count || after > 4 ? 1 : after
        return (kind, ordered, number, spaces + width + gap)
    }

    private static func isHTMLStart(_ line: String) -> Bool {
        guard indent(line) <= 3 else { return false }
        let body = line.drop { $0 == " " }
        guard body.first == "<", let next = body.dropFirst().first else { return false }
        return next.isLetter || next == "/" || next == "!" || next == "?"
    }

    private static func cells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body.removeLast() }
        var cells: [String] = [], current = "", escaped = false, inCode = false
        for character in body {
            if escaped { current.append(character == "|" ? "|" : "\\" + String(character)); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "`" { inCode.toggle() }
            if character == "|", !inCode { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(character)
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func alignments(_ line: String) -> [MarkdownAlignment]? {
        guard line.contains("-") else { return nil }
        let parts = cells(line)
        var result: [MarkdownAlignment] = []
        for part in parts {
            let dashes = part.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (part.hasPrefix(":"), part.hasSuffix(":")) {
            case (true, true): result.append(.center)
            case (false, true): result.append(.trailing)
            default: result.append(.leading)
            }
        }
        return result
    }

    /// Whether `line` starts a block that ends a paragraph.
    private static func interrupts(_ line: String) -> Bool {
        if heading(line) != nil || fence(line) != nil || quoteContent(line) != nil || isRule(line) || isHTMLStart(line) { return true }
        // A list interrupts a paragraph only with a bullet or the number 1, and only with text after it.
        if let marker = listMarker(line), !marker.ordered || marker.number == 1 { return !isBlank(String(line.dropFirst(marker.contentIndent))) }
        return false
    }

    // MARK: Blocks

    private static func blocks(_ lines: ArraySlice<String>, depth: Int) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var i = lines.startIndex
        let end = lines.endIndex
        while i < end {
            let line = lines[i]
            if isBlank(line) { i += 1; continue }

            if let open = fence(line) {
                let strip = indent(line)
                var body: [String] = []
                i += 1
                while i < end {
                    if let close = fence(lines[i]), close.marker == open.marker, close.length >= open.length, close.info.isEmpty { i += 1; break }
                    body.append(dropIndent(lines[i], strip))
                    i += 1
                }
                let language = open.info.split(separator: " ").first.map(String.init)
                result.append(.code(language: language?.isEmpty == false ? language : nil, text: body.joined(separator: "\n")))
                continue
            }
            if indent(line) >= 4 {
                var body: [String] = []
                while i < end, isBlank(lines[i]) || indent(lines[i]) >= 4 { body.append(dropIndent(lines[i], 4)); i += 1 }
                while let last = body.last, isBlank(last) { body.removeLast() }
                result.append(.code(language: nil, text: body.joined(separator: "\n")))
                continue
            }
            if let (level, text) = heading(line) { result.append(.heading(level: level, text: text)); i += 1; continue }
            if isRule(line) { result.append(.rule); i += 1; continue }

            if quoteContent(line) != nil {
                var inner: [String] = []
                while i < end {
                    if let content = quoteContent(lines[i]) {
                        inner.append(content)
                    } else if !isBlank(lines[i]), let last = inner.last, !isBlank(last), !interrupts(lines[i]) {
                        inner.append(lines[i])  // A lazy continuation of the quoted paragraph.
                    } else {
                        break
                    }
                    i += 1
                }
                result.append(depth + 1 < maximumDepth ? .quote(blocks(inner[...], depth: depth + 1)) : .paragraph(inner.joined(separator: " ")))
                continue
            }

            if let first = listMarker(line) {
                var items: [MarkdownListItem] = []
                while i < end, let marker = listMarker(lines[i]), marker.kind == first.kind {
                    var itemLines = [String(lines[i].dropFirst(min(marker.contentIndent, lines[i].count)))]
                    i += 1
                    while i < end {
                        let next = lines[i]
                        if isBlank(next) {
                            // A blank line stays in the item only when the item goes on after it.
                            var j = i
                            while j < end, isBlank(lines[j]) { j += 1 }
                            guard j < end, indent(lines[j]) >= marker.contentIndent else { break }
                            // The whole run at once: one blank at a time would look ahead over the rest again and again.
                            itemLines.append(contentsOf: repeatElement("", count: j - i))
                            i = j
                        } else if indent(next) >= marker.contentIndent {
                            itemLines.append(dropIndent(next, marker.contentIndent))
                            i += 1
                        } else if listMarker(next) == nil, !interrupts(next), let last = itemLines.last, !isBlank(last) {
                            itemLines.append(next.trimmingCharacters(in: .whitespaces))  // Lazy continuation.
                            i += 1
                        } else {
                            break
                        }
                    }
                    var task: Bool?
                    if let head = itemLines.first {
                        for (box, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where head.hasPrefix(box) || head == String(box.dropLast()) {
                            task = done
                            itemLines[0] = String(head.dropFirst(min(box.count, head.count)))
                            break
                        }
                    }
                    let content = depth + 1 < maximumDepth ? blocks(itemLines[...], depth: depth + 1) : [.paragraph(itemLines.joined(separator: " "))]
                    items.append(MarkdownListItem(task: task, blocks: content))
                    // Blank lines between items keep one list.
                    var j = i
                    while j < end, isBlank(lines[j]) { j += 1 }
                    if j > i, j < end, let next = listMarker(lines[j]), next.kind == first.kind { i = j }
                }
                result.append(.list(ordered: first.ordered, start: first.number, items: items))
                continue
            }

            if line.contains("|"), i + 1 < end, let aligns = alignments(lines[i + 1]), cells(line).count == aligns.count {
                let header = cells(line)
                var rows: [[String]] = []
                i += 2
                while i < end, !isBlank(lines[i]), lines[i].contains("|"), !interrupts(lines[i]) {
                    var row = cells(lines[i])
                    row = Array(row.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - row.count))
                    rows.append(row)
                    i += 1
                }
                result.append(.table(header: header, alignments: aligns, rows: rows))
                continue
            }

            if isHTMLStart(line) {
                var body: [String] = []
                while i < end, !isBlank(lines[i]) { body.append(lines[i]); i += 1 }
                result.append(.html(body.joined(separator: "\n")))
                continue
            }

            // A paragraph, unless a setext underline makes it a heading.
            var paragraph: [String] = [line]
            i += 1
            var setext: Int?
            while i < end, !isBlank(lines[i]) {
                let next = lines[i]
                let marks = next.trimmingCharacters(in: .whitespaces)
                if indent(next) <= 3, !marks.isEmpty, marks.allSatisfy({ $0 == "=" }) || marks.allSatisfy({ $0 == "-" }) {
                    setext = marks.first == "=" ? 1 : 2
                    i += 1
                    break
                }
                if interrupts(next) { break }
                paragraph.append(next)
                i += 1
            }
            let text = inline(paragraph)
            result.append(setext.map { .heading(level: $0, text: text) } ?? .paragraph(text))
        }
        return result
    }

    /// Paragraph lines as one inline text: a soft break becomes a space, a hard break (two trailing spaces or a
    /// backslash) a newline.
    private static func inline(_ lines: [String]) -> String {
        var text = ""
        for (index, raw) in lines.enumerated() {
            var line = raw.drop { $0 == " " }
            let last = index == lines.count - 1
            var hard = false
            if !last, line.hasSuffix("  ") { hard = true }
            if !last, line.hasSuffix("\\") { hard = true; line = line.dropLast() }
            while line.last == " " { line = line.dropLast() }
            text += line
            if !last { text += hard ? "\n" : " " }
        }
        return text
    }
}

/// What clicking a link in the Markdown preview does (FR-ED12). The file is untrusted: only web and mail links leave
/// Trellis, only files inside the project open, and nothing else happens.
public enum MarkdownLink {
    public enum Action: Equatable, Sendable {
        case web(URL)
        case file(String)
        case anchor(String)
        case none
    }

    /// Whether the preview keeps a link clickable: a relative one, or a web or mail one. Any other scheme loses its link
    /// before it is drawn, so no path that bypasses the preview's own link handling can hand it to the system.
    public static func isClickable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        return ["http", "https", "mailto"].contains(scheme)
    }

    public static func action(_ destination: String, documentPath: String, projectRoot: String?, isRegularFile: (String) -> Bool) -> Action {
        let target = destination.trimmingCharacters(in: .whitespaces)
        if target.hasPrefix("#") { return .anchor(String(target.dropFirst()).removingPercentEncoding ?? String(target.dropFirst())) }
        if let colon = target.firstIndex(of: ":"), target[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }), colon != target.startIndex {
            // A scheme: only the web and mail ones.
            guard let url = URL(string: target), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return .none }
            if scheme != "mailto", url.host?.isEmpty ?? true { return .none }
            return .web(url)
        }
        // A path: without its `#fragment` or `?query`, decoded, resolved from the document's folder.
        var path = String(target.prefix { $0 != "#" && $0 != "?" })
        guard !path.isEmpty, let decoded = path.removingPercentEncoding, !decoded.contains("\0") else { return .none }
        path = decoded
        let folder = (documentPath as NSString).deletingLastPathComponent
        let root = projectRoot ?? folder
        // As on GitHub, a leading `/` names the project's root, not the disk's.
        let absolute = path.hasPrefix("/") ? root + path : folder + "/" + path
        guard EditorLinkScope.contains(absolute, roots: [root]) else { return .none }
        let standardized = URL(fileURLWithPath: absolute).standardizedFileURL.path
        return isRegularFile(standardized) ? .file(standardized) : .none
    }
}
