/// Limits apply to historical rendered rows; the active screen and engine cell
/// metadata are accounted separately. A row costs its UTF-8 text plus a separator.
public struct ScrollbackBudget: Equatable, Sendable {
    public static let standard = ScrollbackBudget()
    public let lineLimit: Int
    public let byteLimit: Int
    public init(lineLimit: Int = 10_000, byteLimit: Int = 16 * 1024 * 1024) {
        self.lineLimit = max(0, lineLimit)
        self.byteLimit = max(0, min(byteLimit, Int.max - 1))
    }

    /// Keep a contiguous newest suffix. An oversized row evicts itself and all
    /// older rows; never stitch together disjoint pieces of terminal history.
    public func retainedSuffixCount(byteCounts: [Int]) -> Int {
        var bytes = 0, count = 0
        for cost in byteCounts.reversed() {
            guard count < lineLimit, cost >= 0, cost <= byteLimit - bytes else { break }
            bytes += cost
            count += 1
        }
        return count
    }
}
