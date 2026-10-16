import Foundation

extension PaneLayout {
    /// Prefer the surviving sibling when closing the focused leaf, so focus
    /// stays near the removed pane rather than jumping across the whole tab.
    func siblingPaneID(whenRemoving paneID: UUID) -> UUID? {
        guard case .split(_, _, _, let children) = self, children.count == 2 else { return nil }
        if children[0] == .pane(paneID) { return children[1].paneIDs.first }
        if children[1] == .pane(paneID) { return children[0].paneIDs.first }
        return children[0].siblingPaneID(whenRemoving: paneID) ?? children[1].siblingPaneID(whenRemoving: paneID)
    }

    public func splitting(paneID: UUID, branchID: UUID, newPaneID: UUID, axis: SplitAxis) -> PaneLayout {
        switch self {
        case .pane(let id):
            return id == paneID ? .split(id: branchID, axis: axis, ratio: 0.5, children: [self, .pane(newPaneID)]) : self
        case .split(let id, let existingAxis, let ratio, let children):
            return .split(id: id, axis: existingAxis, ratio: ratio, children: children.map {
                $0.splitting(paneID: paneID, branchID: branchID, newPaneID: newPaneID, axis: axis)
            })
        }
    }

    public func removing(paneID: UUID) -> PaneLayout? {
        switch self {
        case .pane(let id): return id == paneID ? nil : self
        case .split(let id, let axis, let ratio, let children):
            let remaining = children.compactMap { $0.removing(paneID: paneID) }
            if remaining.count == 1 { return remaining[0] }
            if remaining.isEmpty { return nil }
            return .split(id: id, axis: axis, ratio: ratio, children: remaining)
        }
    }
}
