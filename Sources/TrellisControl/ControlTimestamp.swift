import Foundation

/// API timestamps: ISO 8601 internet date-time in UTC, whole seconds (`2026-11-10T18:19:19Z`).
public enum ControlTimestamp {
    /// A value-type format style, not `ISO8601DateFormatter`: building that formatter per call was most of the cost of
    /// `session.readOutput`, and one shared instance would be mutable state across the control and main threads.
    /// The style truncates to the second where the formatter rounded at the millisecond, so half a millisecond is added
    /// first to keep the output the same for every date.
    public static func string(_ date: Date) -> String { date.addingTimeInterval(0.0005).formatted(.iso8601) }
}
