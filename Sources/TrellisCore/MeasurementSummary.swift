import Foundation

/// Percentile summaries for qualification runs. Nearest-rank method, so the
/// result is always an observed sample and is reproducible for the same data.
public struct MeasurementSummary: Equatable, Sendable {
    /// Fewer samples than this cannot support a p95 claim.
    public static let minimumSamples = 20

    public enum Result: Equatable, Sendable {
        case measured(p50: Double, p95: Double, max: Double, count: Int)
        case insufficientSamples(count: Int, required: Int)
    }

    public static func summarize(_ samples: [Double], minimum: Int = minimumSamples) -> Result {
        let valid = samples.filter(\.isFinite).sorted()
        guard valid.count >= minimum else { return .insufficientSamples(count: valid.count, required: minimum) }
        func rank(_ percentile: Double) -> Double { valid[max(0, Int((percentile * Double(valid.count)).rounded(.up)) - 1)] }
        return .measured(p50: rank(0.50), p95: rank(0.95), max: valid[valid.count - 1], count: valid.count)
    }

    /// Pass/fail only when measured; insufficient data is never a pass.
    public static func meets(_ result: Result, p95AtMost limit: Double) -> Bool? {
        guard case .measured(_, let p95, _, _) = result else { return nil }
        return p95 <= limit
    }
}
