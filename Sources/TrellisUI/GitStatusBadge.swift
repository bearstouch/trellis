import AppKit
import SwiftUI

/// The Git logo (FR-PL09), by Jason Long, CC BY 3.0 (https://git-scm.com/downloads/logos): the path of
/// https://commons.wikimedia.org/wiki/File:Git_icon.svg in its 97 x 97 canvas, kept as code so no resource bundle is needed.
struct GitMark: Shape {
    static let color = Color(red: 0xF0 / 255, green: 0x51 / 255, blue: 0x33 / 255)
    static let canvas: CGFloat = 97

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / Self.canvas
        return Self.outline.applying(CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }

    private static let outline = Path { path in
        path.move(to: CGPoint(x: 92.71, y: 44.408))
        path.addLine(to: CGPoint(x: 52.591, y: 4.291))
        path.addCurve(to: CGPoint(x: 44.222, y: 4.291), control1: CGPoint(x: 50.281, y: 1.98), control2: CGPoint(x: 46.534, y: 1.98))
        path.addLine(to: CGPoint(x: 35.892, y: 12.623))
        path.addLine(to: CGPoint(x: 46.459, y: 23.19))
        path.addCurve(to: CGPoint(x: 53.688, y: 24.875), control1: CGPoint(x: 48.915, y: 22.36), control2: CGPoint(x: 51.731, y: 22.917))
        path.addCurve(to: CGPoint(x: 55.358, y: 32.15), control1: CGPoint(x: 55.657, y: 26.845), control2: CGPoint(x: 56.209, y: 29.685))
        path.addLine(to: CGPoint(x: 65.544, y: 42.335))
        path.addCurve(to: CGPoint(x: 72.819, y: 44.006), control1: CGPoint(x: 68.009, y: 41.485), control2: CGPoint(x: 70.851, y: 42.035))
        path.addCurve(to: CGPoint(x: 72.819, y: 53.964), control1: CGPoint(x: 75.569, y: 46.756), control2: CGPoint(x: 75.569, y: 51.212))
        path.addCurve(to: CGPoint(x: 62.858, y: 53.964), control1: CGPoint(x: 70.067, y: 56.715), control2: CGPoint(x: 65.611, y: 56.715))
        path.addCurve(to: CGPoint(x: 61.327, y: 46.306), control1: CGPoint(x: 60.79, y: 51.894), control2: CGPoint(x: 60.278, y: 48.854))
        path.addLine(to: CGPoint(x: 51.827, y: 36.807))
        path.addLine(to: CGPoint(x: 51.827, y: 61.804))
        path.addCurve(to: CGPoint(x: 53.688, y: 63.136), control1: CGPoint(x: 52.497, y: 62.136), control2: CGPoint(x: 53.13, y: 62.578))
        path.addCurve(to: CGPoint(x: 53.688, y: 73.095), control1: CGPoint(x: 56.438, y: 65.886), control2: CGPoint(x: 56.438, y: 70.342))
        path.addCurve(to: CGPoint(x: 43.731, y: 73.095), control1: CGPoint(x: 50.938, y: 75.844), control2: CGPoint(x: 46.479, y: 75.844))
        path.addCurve(to: CGPoint(x: 43.731, y: 63.136), control1: CGPoint(x: 40.981, y: 70.341), control2: CGPoint(x: 40.981, y: 65.885))
        path.addCurve(to: CGPoint(x: 46.038, y: 61.599), control1: CGPoint(x: 44.411, y: 62.457), control2: CGPoint(x: 45.198, y: 61.943))
        path.addLine(to: CGPoint(x: 46.038, y: 36.369))
        path.addCurve(to: CGPoint(x: 43.731, y: 34.832), control1: CGPoint(x: 45.198, y: 36.025), control2: CGPoint(x: 44.413, y: 35.516))
        path.addCurve(to: CGPoint(x: 42.215, y: 27.134), control1: CGPoint(x: 41.648, y: 32.75), control2: CGPoint(x: 41.147, y: 29.692))
        path.addLine(to: CGPoint(x: 31.798, y: 16.715))
        path.addLine(to: CGPoint(x: 4.288, y: 44.222))
        path.addCurve(to: CGPoint(x: 4.288, y: 52.593), control1: CGPoint(x: 1.977, y: 46.535), control2: CGPoint(x: 1.977, y: 50.282))
        path.addLine(to: CGPoint(x: 44.409, y: 92.711))
        path.addCurve(to: CGPoint(x: 52.778, y: 92.711), control1: CGPoint(x: 46.719, y: 95.022), control2: CGPoint(x: 50.465, y: 95.022))
        path.addLine(to: CGPoint(x: 92.71, y: 52.779))
        path.addCurve(to: CGPoint(x: 92.71, y: 44.408), control1: CGPoint(x: 95.021, y: 50.468), control2: CGPoint(x: 95.021, y: 46.719))
        path.closeSubpath()
    }
}

/// A pane's git state as a small icon: the header keeps its room, and hovering shows the branch and counts in a card.
struct GitStatusBadge: View {
    let text: String
    let spoken: String
    let foreground: Color
    let background: Color
    @State private var presented = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        GitMark().fill(GitMark.color).frame(width: 12, height: 12)
            .frame(width: 18, height: 18).contentShape(Rectangle())
            .onHover { schedule(open: $0) }
            // Not `.popover`: a transient one would swallow the click that goes to the terminal or a header button.
            .background(PassThroughPopoverAnchor(presented: $presented, edge: .minY, content: AnyView(card)))
            .onDisappear {
                pending?.cancel(); pending = nil; presented = false
            }
            .accessibilityElement(children: .ignore).accessibilityLabel(spoken)
    }

    private var card: some View { Self.cardText(text).foregroundStyle(foreground).background(background) }

    /// Long branch names wrap instead of cutting off what the icon replaced. A definite width, not `maxWidth`: the
    /// popover sizes itself from an unconstrained measure, which with `maxWidth` gives one line's height and clips the rest.
    static func cardText(_ text: String) -> some View {
        let width = min(360, ceil((text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]).width) + 1)
        return Text(text).font(.system(size: 11)).monospacedDigit()
            .frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func schedule(open: Bool) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(open ? 150 : 100))
            guard !Task.isCancelled else { return }
            presented = open
        }
    }
}
