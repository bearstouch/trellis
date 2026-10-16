import Foundation

public struct WorkspacePresentation: Sendable {
    public let snapshot: WorkspaceSnapshot
    public init(snapshot: WorkspaceSnapshot) { self.snapshot = snapshot }
    public var selectedWindow: ManagedWindow? { snapshot.windows.first { $0.id == snapshot.activeWindowID } }
    public var visibleTabs: [WorkspaceTab] { selectedWindow?.tabIDs.compactMap { snapshot.tabs[$0] } ?? [] }
    public var selectedTab: WorkspaceTab? { selectedWindow.flatMap { snapshot.tabs[$0.activeTabID] } }
    public var activePane: WorkspacePane? { selectedTab.flatMap { snapshot.panes[$0.activePaneID] } }
    public var isEmpty: Bool { snapshot.windows.isEmpty }
}

public struct CanvasDimensions: Equatable, Sendable {
    public static let dividerThickness: Double = 1
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public static func minimum(for layout: PaneLayout, cellWidth: Double = 8, cellHeight: Double = 18) -> Self {
        switch layout {
        case .pane: return Self(width: cellWidth * 20, height: cellHeight * 5 + 26)
        case .split(_, let axis, let ratio, let children):
            guard children.count == 2, ratio.isFinite, (0.1...0.9).contains(ratio) else {
                return Self(width: cellWidth * 20, height: cellHeight * 5 + 26)
            }
            let first = minimum(for: children[0], cellWidth: cellWidth, cellHeight: cellHeight)
            let second = minimum(for: children[1], cellWidth: cellWidth, cellHeight: cellHeight)
            return axis == .x
                ? Self(width: max(first.width / ratio, second.width / (1 - ratio)) + dividerThickness, height: max(first.height, second.height))
                : Self(width: max(first.width, second.width), height: max(first.height / ratio, second.height / (1 - ratio)) + dividerThickness)
        }
    }
    public func fitting(width: Double, height: Double) -> Self {
        Self(width: max(self.width, width), height: max(self.height, height))
    }
}

public struct WindowRectangle: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public func constrained(to displays: [Self]) -> Self {
        let available = displays.filter { [$0.x, $0.y, $0.width, $0.height].allSatisfy(\.isFinite) && $0.width > 0 && $0.height > 0 }
        guard let first = available.first else { return Self(x: 100, y: 100, width: 980, height: 620) }
        guard [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else {
            return Self(x: first.x, y: first.y, width: min(980, first.width), height: min(620, first.height))
        }
        func overlap(_ display: Self) -> Double {
            max(0, min(x + width, display.x + display.width) - max(x, display.x))
                * max(0, min(y + height, display.y + display.height) - max(y, display.y))
        }
        let display = available.max { overlap($0) < overlap($1) } ?? first
        let w = min(width, display.width), h = min(height, display.height)
        return Self(
            x: min(max(x, display.x), display.x + display.width - w),
            y: min(max(y, display.y), display.y + display.height - h), width: w, height: h)
    }
}
