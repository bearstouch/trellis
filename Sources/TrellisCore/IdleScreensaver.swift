import Foundation

/// The animation drawn over the focused pane once it has been idle (FR-SS01); Off never starts one.
public enum IdleScreensaverStyle: String, Codable, CaseIterable, Sendable {
    case off, digitalRain, life, briansBrain, hexSpirals, plasma
    public static var animations: [Self] { allCases.filter { $0 != .off } }
    public var displayName: String {
        switch self {
        case .off: L("Off")
        case .digitalRain: L("Digital Rain")
        case .life: L("Game of Life")
        case .briansBrain: L("Brian's Brain")
        case .hexSpirals: L("Hex Spirals")
        case .plasma: L("ASCII Plasma")
        }
    }
}

/// FR-SS01: how long the focused pane goes without input or output before the screensaver starts.
public enum IdleScreensaverDelay {
    /// Seconds.
    public static let choices = [30, 60, 120, 300, 600, 900, 1800, 3600]
    public static let defaultSeconds = 300
    /// One of `choices`; anything else is the default.
    public static func normalized(_ seconds: Int) -> Int { choices.contains(seconds) ? seconds : defaultSeconds }
    public static func label(seconds: Int) -> String {
        switch seconds {
        case ..<60: L("%d seconds", seconds)
        case 60: L("1 minute")
        case 3600: L("1 hour")
        default: L("%d minutes", seconds / 60)
        }
    }
}

/// FR-SS02: when the watched pane (the focused one) last had input, output or the user's attention.
public struct IdleScreensaverClock: Equatable, Sendable {
    public private(set) var paneID: UUID?
    public private(set) var lastActivity: Date
    public init(now: Date) { lastActivity = now }
    public mutating func noteActivity(at now: Date) { lastActivity = now }
    /// Focusing another pane, or none, starts a fresh countdown.
    public mutating func watch(_ paneID: UUID?, at now: Date) {
        guard paneID != self.paneID else { return }
        self.paneID = paneID; lastActivity = now
    }
    public func isIdle(at now: Date, delay: TimeInterval) -> Bool { paneID != nil && now.timeIntervalSince(lastActivity) >= delay }
}
