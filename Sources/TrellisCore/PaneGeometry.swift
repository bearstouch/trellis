import Foundation

public enum PaneDirection: String, CaseIterable, Sendable { case left, right, up, down }

public struct PaneRectangle: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

public struct PaneGeometry: Sendable {
    public private(set) var panes: [UUID: PaneRectangle] = [:]
    public private(set) var branches: [UUID: PaneRectangle] = [:]
    private var order: [UUID] = []

    public init(layout: PaneLayout, canvas: CanvasDimensions) {
        visit(layout, rect: PaneRectangle(x: 0, y: 0, width: canvas.width, height: canvas.height))
    }

    private mutating func visit(_ layout: PaneLayout, rect: PaneRectangle) {
        switch layout {
        case .pane(let id): panes[id] = rect; order.append(id)
        case .split(let id, let axis, let ratio, let children):
            guard children.count == 2 else { return }
            branches[id] = rect
            if axis == .x {
                let first = max(0, rect.width - CanvasDimensions.dividerThickness) * ratio
                visit(children[0], rect: PaneRectangle(x: rect.x, y: rect.y, width: first, height: rect.height))
                visit(children[1], rect: PaneRectangle(x: rect.x + first + CanvasDimensions.dividerThickness, y: rect.y, width: max(0, rect.width - first - CanvasDimensions.dividerThickness), height: rect.height))
            } else {
                let first = max(0, rect.height - CanvasDimensions.dividerThickness) * ratio
                visit(children[0], rect: PaneRectangle(x: rect.x, y: rect.y, width: rect.width, height: first))
                visit(children[1], rect: PaneRectangle(x: rect.x, y: rect.y + first + CanvasDimensions.dividerThickness, width: rect.width, height: max(0, rect.height - first - CanvasDimensions.dividerThickness)))
            }
        }
    }

    /// Prefer overlapping neighbors, then the closest facing edge and center.
    /// Tree order is the final tie break, so keyboard navigation is repeatable.
    public func neighbor(of id: UUID, direction: PaneDirection) -> UUID? {
        guard let source = panes[id] else { return nil }
        var best: (id: UUID, overlap: Int, gap: Double, cross: Double)?
        for candidateID in order where candidateID != id {
            guard let rect = panes[candidateID] else { continue }
            let gap: Double, overlap: Double, cross: Double
            switch direction {
            case .left:
                gap = source.x - rect.x - rect.width
                overlap = min(source.y + source.height, rect.y + rect.height) - max(source.y, rect.y)
                cross = abs(source.midY - rect.midY)
            case .right:
                gap = rect.x - source.x - source.width
                overlap = min(source.y + source.height, rect.y + rect.height) - max(source.y, rect.y)
                cross = abs(source.midY - rect.midY)
            case .up:
                gap = source.y - rect.y - rect.height
                overlap = min(source.x + source.width, rect.x + rect.width) - max(source.x, rect.x)
                cross = abs(source.midX - rect.midX)
            case .down:
                gap = rect.y - source.y - source.height
                overlap = min(source.x + source.width, rect.x + rect.width) - max(source.x, rect.x)
                cross = abs(source.midX - rect.midX)
            }
            guard gap >= -0.001 else { continue }
            let score = (overlap > 0 ? 0 : 1, gap, cross)
            if let current = best, (current.overlap, current.gap, current.cross) <= score { continue }
            best = (candidateID, score.0, score.1, score.2)
        }
        return best?.id
    }
}

extension PaneLayout {
    public func resizing(splitID: UUID, ratio: Double) -> PaneLayout {
        switch self {
        case .pane: return self
        case .split(let id, let axis, let old, let children):
            return .split(
                id: id, axis: axis, ratio: id == splitID ? ratio : old,
                children: children.map { $0.resizing(splitID: splitID, ratio: ratio) })
        }
    }

    /// Nearest ancestor on the requested axis, suitable for keyboard resizing.
    public func enclosingSplit(paneID: UUID, axis: SplitAxis) -> (id: UUID, ratio: Double)? {
        guard case .split(let id, let ownAxis, let ratio, let children) = self, children.count == 2 else { return nil }
        for child in children where child.paneIDs.contains(paneID) {
            return child.enclosingSplit(paneID: paneID, axis: axis) ?? (ownAxis == axis ? (id, ratio) : nil)
        }
        return nil
    }
}
