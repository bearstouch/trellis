import AppKit
import SwiftUI
import TrellisCore

/// A Markdown tab's rendered preview (FR-ED12): drawn natively in the theme's colors (FR-ED11), with no web view and no
/// scripts. Links go through the model, which opens only web links, project files and `#headings`; images are never loaded.
struct MarkdownPreviewView: View {
    @ObservedObject var model: AppWorkspaceModel
    let tab: EditorTab
    /// Parsing runs only while the preview is on screen.
    let visible: Bool
    @State private var blocks: [MarkdownBlock] = []
    @State private var anchors: [Int: String] = [:]

    private struct ParseKey: Equatable {
        let text: String
        let visible: Bool
    }

    private var palette: TerminalPalette { model.effectiveTheme.terminal }
    private var foreground: Color { Color(nsColor: NSColor(rgb: palette.foreground)) }
    private var muted: Color { foreground.opacity(0.65) }
    private var accent: Color { Color(nsColor: NSColor(rgb: palette.ansi.indices.contains(4) ? palette.ansi[4] : palette.cursor)) }
    private var baseSize: CGFloat { CGFloat(model.appearance.fontSize) + 1 }
    private var codeFont: NSFont {
        let size = CGFloat(model.appearance.fontSize) - 1
        return NSFont(name: model.appearance.fontName, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        blockView(block, depth: 0).id(anchors[index].map { "heading-" + $0 } ?? "block-\(index)")
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 32).padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
            }
            .onChange(of: tab.previewAnchor) { _, anchor in
                guard let anchor else { return }
                withAnimation(model.reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("heading-" + anchor.slug, anchor: .top) }
            }
        }
        .foregroundStyle(foreground)
        .background(Color(nsColor: NSColor(rgb: palette.background)))
        // Every link click goes through the model's rules; SwiftUI never opens a URL by itself.
        .environment(
            \.openURL,
            OpenURLAction { url in
                let destination = url.relativeString
                Task { await model.openMarkdownLink(destination, in: tab.id) }
                return .handled
            }
        )
        .task(id: ParseKey(text: tab.text, visible: visible)) { await parse() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Preview of %@", tab.fileName))
    }

    /// Large texts are read a moment after typing stops, off the main thread.
    private func parse() async {
        guard visible else { return }
        let text = tab.text
        if text.utf8.count > 65_536 {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
        }
        let parsed = await Task.detached(priority: .userInitiated) { MarkdownDocument.parse(text) }.value
        guard !Task.isCancelled else { return }
        var seen: [String: Int] = [:], ids: [Int: String] = [:]
        for (index, block) in parsed.enumerated() {
            guard case .heading(_, let heading) = block else { continue }
            let slug = MarkdownDocument.slug(String(inline(heading).characters))
            // As on GitHub, a repeated heading gets `-1`, `-2`…
            let count = seen[slug, default: 0]
            seen[slug] = count + 1
            ids[index] = count == 0 ? slug : "\(slug)-\(count)"
        }
        blocks = parsed
        anchors = ids
    }

    // MARK: Blocks

    private func blockView(_ block: MarkdownBlock, depth: Int) -> AnyView {
        switch block {
        case .heading(let level, let text):
            let scale: [CGFloat] = [1.9, 1.5, 1.25, 1.1, 1.0, 0.95]
            return AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    Text(inline(text)).font(.system(size: baseSize * scale[max(0, min(5, level - 1))], weight: level <= 2 ? .bold : .semibold))
                        .padding(.top, level <= 2 ? 8 : 4)
                    if level <= 2 { Rectangle().fill(model.themeColor(.border).opacity(0.5)).frame(height: 1) }
                }
                .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader))
        case .paragraph(let text):
            return AnyView(Text(inline(text)).font(.system(size: baseSize)).lineSpacing(3).fixedSize(horizontal: false, vertical: true))
        case .list(let ordered, let start, let items):
            return AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            marker(item, ordered: ordered, number: start + index, depth: depth)
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, child in blockView(child, depth: depth + 1) }
                            }
                        }
                    }
                })
        case .quote(let inner):
            return AnyView(
                HStack(alignment: .top, spacing: 12) {
                    Rectangle().fill(model.themeColor(.border)).frame(width: 3)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(inner.enumerated()), id: \.offset) { _, child in blockView(child, depth: depth + 1) }
                    }
                    .foregroundStyle(muted)
                }
                .fixedSize(horizontal: false, vertical: true))
        case .code(let language, let text):
            let name = EditorLanguage.forFence(language)
            return AnyView(
                ScrollView(.horizontal) {
                    Text(highlighted(text, grammar: name.grammar)).font(Font(codeFont)).fixedSize().padding(12)
                }
                .scrollIndicators(.automatic)
                .background(RoundedRectangle(cornerRadius: 6).fill(foreground.opacity(0.06)))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(language.map { L("Code, %@", $0) } ?? L("Code")))
        case .table(let header, let alignments, let rows):
            return AnyView(
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow {
                            ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                                tableCell(cell, alignment: alignments[column]).fontWeight(.semibold)
                                    .gridColumnAlignment(horizontal(alignments[column]))
                            }
                        }
                        .background(foreground.opacity(0.06))
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { column, cell in tableCell(cell, alignment: alignments[column]) }
                            }
                        }
                    }
                    .overlay(Rectangle().stroke(model.themeColor(.border).opacity(0.6)))
                })
        case .rule:
            return AnyView(Rectangle().fill(model.themeColor(.border).opacity(0.6)).frame(height: 1).padding(.vertical, 6).accessibilityHidden(true))
        case .html(let text):
            return AnyView(Text(text).font(Font(codeFont)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true))
        }
    }

    @ViewBuilder private func marker(_ item: MarkdownListItem, ordered: Bool, number: Int, depth: Int) -> some View {
        if let done = item.task {
            Image(systemName: done ? "checkmark.square.fill" : "square").foregroundStyle(done ? accent : muted)
                .accessibilityLabel(done ? L("done") : L("not done"))
        } else if ordered {
            Text("\(number).").monospacedDigit().foregroundStyle(muted).font(.system(size: baseSize))
        } else {
            Text(depth % 2 == 0 ? "•" : "◦").foregroundStyle(muted).font(.system(size: baseSize)).accessibilityHidden(true)
        }
    }

    private func tableCell(_ text: String, alignment: MarkdownAlignment) -> some View {
        Text(inline(text)).font(.system(size: baseSize - 1)).multilineTextAlignment(textAlignment(alignment))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: frameAlignment(alignment))
            .overlay(alignment: .bottom) { Rectangle().fill(model.themeColor(.border).opacity(0.35)).frame(height: 1) }
    }

    private func horizontal(_ alignment: MarkdownAlignment) -> HorizontalAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
    private func frameAlignment(_ alignment: MarkdownAlignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
    private func textAlignment(_ alignment: MarkdownAlignment) -> TextAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    // MARK: Inline

    /// Emphasis, strong, strikethrough, code and links through Foundation's inline Markdown; an image becomes its alt text
    /// with a symbol, never a fetch.
    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let links = result.runs.compactMap { run in run.link.map { ($0, run.range) } }
        for (url, range) in links {
            guard MarkdownLink.isClickable(url) else { result[range].link = nil; continue }
            result[range].foregroundColor = accent
            result[range].underlineStyle = .single
        }
        let images = result.runs.filter { $0.imageURL != nil }.map(\.range).reversed()
        for range in images {
            let alt = String(result[range].characters)
            var replacement = AttributedString("▧ " + (alt.isEmpty ? L("Image") : alt))
            replacement.foregroundColor = muted
            replacement.inlinePresentationIntent = .emphasized
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    /// A fenced block colored like the editor: the same tokenizer and the theme's ANSI colors.
    private func highlighted(_ text: String, grammar: ScratchpadLanguage.Grammar) -> AttributedString {
        var result = AttributedString(text)
        guard text.utf8.count <= 65_536 else { return result }
        for token in ScratchpadHighlighter.tokens(in: text, grammar: grammar) {
            guard let range = Range(token.range, in: result) else { continue }
            result[range].foregroundColor = Color(nsColor: ScratchpadEditor.Coordinator.color(token.kind, palette: palette))
        }
        return result
    }
}
