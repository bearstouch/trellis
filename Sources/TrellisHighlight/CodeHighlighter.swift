import AppKit
import Neon
import RangeState
import SwiftTreeSitter
import SwiftTreeSitterLayer
import TreeSitterClient
import TrellisCore

/// Tree-sitter highlighting for an `NSTextView` (FR-TD11). It styles with layout-manager temporary attributes, so the
/// text and undo never change, and after an edit or a scroll it styles only the visible range: Neon's own
/// `TextViewHighlighter` re-styles the whole document, which took seconds on a 2 MiB file.
///
/// It becomes the text storage's delegate. Only TrellisHighlight imports Neon and SwiftTreeSitter.
@MainActor
public final class CodeHighlighter: NSObject, NSTextStorageDelegate {
    public let textView: NSTextView
    private let client: TreeSitterClient
    private let styler: TextSystemStyler<TextViewSystemInterface>
    private let buffer = RangeInvalidationBuffer()
    private var palette: TerminalPalette

    /// Highlights `textView` as `fileName`'s language; nil for plain text or when the grammar's queries are missing.
    public static func make(for textView: NSTextView, fileName: String, palette: TerminalPalette) -> CodeHighlighter? {
        guard let grammar = Grammar.forFile(fileName), let configuration = grammar.configuration else { return nil }
        // Injected languages are loaded here, on the main actor: tree-sitter asks for them while parsing in the background.
        let injections = InjectionTable(grammar.injections.compactMap { injected in injected.configuration.map { (injected.rawValue, $0) } })
        return try? CodeHighlighter(textView: textView, configuration: configuration, injections: injections, palette: palette)
    }

    init(textView: NSTextView, configuration: LanguageConfiguration, injections: InjectionTable, palette: TerminalPalette) throws {
        guard let storage = textView.textStorage else { throw TextViewHighlighterError.noTextStorage }
        self.textView = textView
        self.palette = palette
        let lines = LineTable(storage.string as NSString)
        // The closures below read the palette and line table through boxes, so they always see the current ones.
        let box = PaletteBox(palette)
        let interface = TextViewSystemInterface(textView: textView) { token in
            CaptureColors.attributes(for: token.name, palette: box.palette)
        }
        let buffer = self.buffer
        let tableBox = LockedLineTable(lines)
        client = try TreeSitterClient(
            rootLanguageConfig: configuration,
            configuration: .init(
                // These two run on Neon's background queue, so they must not inherit the main actor.
                languageProvider: { @Sendable name in injections.configuration(for: name) },
                contentProvider: { LanguageLayer.Content(string: interface.textStorage.string, limit: $0) },
                contentSnapshopProvider: { LanguageLayer.ContentSnapshot(string: interface.textStorage.string, limit: $0) },
                lengthProvider: { interface.content.currentLength },
                invalidationHandler: { buffer.invalidate(.set($0)) },
                locationTransformer: { @Sendable offset in
                    let location = tableBox.location(of: offset)
                    // Tree-sitter reads UTF-16LE, so columns are in bytes.
                    return Point(row: location.row, column: location.column * 2)
                }))
        let tokens = client.tokenProvider(with: { interface.content.string.predicateTextProvider($0, $1) })
        styler = TextSystemStyler(textSystem: interface, tokenProvider: tokens)
        self.paletteBox = box
        self.linesBox = tableBox
        super.init()
        buffer.invalidationHandler = { [weak self] target in
            guard let self else { return }
            self.styler.invalidate(target)
            self.validateVisible()
        }
        storage.delegate = self
        if let scroll = textView.enclosingScrollView {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(visibleChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(visibleChanged), name: NSView.frameDidChangeNotification, object: scroll)
        }
        buffer.invalidate(.all)
    }

    private let paletteBox: PaletteBox
    private let linesBox: LockedLineTable

    /// Restyles with another theme's colors.
    public func setPalette(_ palette: TerminalPalette) {
        guard palette != self.palette else { return }
        self.palette = palette
        paletteBox.palette = palette
        buffer.invalidate(.all)
    }

    /// Detaches from the text view, leaving its text and plain colors.
    public func detach() {
        NotificationCenter.default.removeObserver(self)
        if textView.textStorage?.delegate === self { textView.textStorage?.delegate = nil }
        if let layout = textView.layoutManager, let length = textView.textStorage?.length {
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
        }
    }

    /// The text was replaced wholesale (a reload); rebuild the line table before tree-sitter reads it.
    public func textWasReplaced() {
        linesBox.rebuild(textView.string as NSString)
        buffer.invalidate(.all)
    }

    @objc private func visibleChanged() { validateVisible() }

    private func validateVisible() { styler.validate(.range(textView.visibleTextRange)) }

    public nonisolated func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            buffer.beginBuffering()
            client.willChangeContent(in: editedRange)
        }
    }

    public nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        // Attribute-only edits come from styling; reacting to them would loop.
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            linesBox.apply(editedRange: editedRange, delta: delta, in: (textView.textStorage?.string ?? "") as NSString)
            let adjusted = NSRange(location: editedRange.location, length: editedRange.length - delta)
            client.didChangeContent(in: adjusted, delta: delta)
            styler.didChangeContent(in: adjusted, delta: delta)
            // Styling during the edit is unsafe in TextKit 1; let the run loop turn first, as Neon does.
            DispatchQueue.main.async { [buffer] in MainActor.assumeIsolated { buffer.endBuffering() } }
        }
    }
}

@MainActor private final class PaletteBox {
    var palette: TerminalPalette
    init(_ palette: TerminalPalette) { self.palette = palette }
}

/// The line table, shared with tree-sitter's background parse.
final class LockedLineTable: @unchecked Sendable {
    private let lock = NSLock()
    private var table: LineTable
    init(_ table: LineTable) { self.table = table }
    func location(of offset: Int) -> (row: Int, column: Int) { lock.withLock { table.location(of: offset) } }
    func apply(editedRange: NSRange, delta: Int, in text: NSString) { lock.withLock { table.apply(editedRange: editedRange, delta: delta, in: text) } }
    func rebuild(_ text: NSString) { lock.withLock { table.rebuild(text) } }
}

/// Injected languages' configurations, read by tree-sitter's background parse; never changed after init.
final class InjectionTable: @unchecked Sendable {
    private let configurations: [String: LanguageConfiguration]
    init(_ pairs: [(String, LanguageConfiguration)]) { configurations = Dictionary(pairs, uniquingKeysWith: { first, _ in first }) }
    func configuration(for name: String) -> LanguageConfiguration? { Grammar.injected(name).flatMap { configurations[$0.rawValue] } }
}

/// Which ANSI color each tree-sitter capture takes, so every theme colors code the way its terminal colors text. Uses
/// the scratchpad's choices where they overlap (keyword 5, function 4, string 2, comment 8, variable 3, number 9).
public enum CaptureColors {
    public static func ansiIndex(for capture: String) -> Int? {
        let parts = capture.split(separator: ".").map(String.init)
        guard let head = parts.first else { return nil }
        switch head {
        case "keyword", "include", "conditional", "repeat", "exception", "storageclass", "modifier": return 5
        case "function", "method", "constructor": return parts.contains("builtin") ? 12 : 4
        case "string", "character": return parts.contains("special") || parts.contains("escape") ? 6 : 2
        case "comment": return 8
        case "number", "float", "boolean", "constant": return 9
        case "type": return 6
        case "attribute", "annotation", "label", "tag": return 4
        case "property", "field": return 3
        case "variable": return parts.contains("builtin") ? 13 : nil
        case "operator": return nil
        case "punctuation": return parts.contains("special") ? 6 : nil
        case "text", "markup":
            if parts.contains("title") || parts.contains("heading") { return 4 }
            if parts.contains("literal") || parts.contains("raw") { return 2 }
            if parts.contains("uri") || parts.contains("link") { return 6 }
            return parts.contains("strong") || parts.contains("emphasis") ? 5 : nil
        case "escape": return 6
        default: return nil
        }
    }

    static func attributes(for capture: String, palette: TerminalPalette) -> [NSAttributedString.Key: Any] {
        guard let index = ansiIndex(for: capture), palette.ansi.indices.contains(index) else { return [:] }
        let rgb = palette.ansi[index]
        let color = NSColor(
            srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        return [.foregroundColor: color]
    }
}
