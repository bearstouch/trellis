import Foundation

/// FR-R08: how long a session the broker keeps may run with nobody watching and nothing printed before it is ended.
public enum KeptSessionIdleTimeout {
    /// Hours; 0 never ends a session.
    public static let choices = [0, 1, 2, 4, 12, 24, 48, 96]
    public static let defaultHours = 24

    /// One of `choices`; anything else is the default.
    public static func normalized(_ hours: Int) -> Int { choices.contains(hours) ? hours : defaultHours }
    public static func seconds(hours: Int) -> Int { normalized(hours) * 3600 }

    public static func label(hours: Int) -> String {
        switch hours {
        case 0: L("No timeout")
        case 1: L("1 hour")
        default: L("%d hours", hours)
        }
    }
}
