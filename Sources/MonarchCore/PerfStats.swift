import Synchronization

/// Fixed-size ring buffers of durations per metric. Recording does no allocation once a
/// metric exists; summaries are computed only when the menu asks for them.
public final class PerfStats: Sendable {
    public static let capacity = 256

    public struct Summary: Sendable, Equatable {
        public let count: Int
        public let last: Double
        public let median: Double
        public let p95: Double
        public let max: Double
    }

    private struct Ring {
        var values = [Double](repeating: 0, count: PerfStats.capacity)
        var next = 0
        var count = 0
        var last: Double = 0

        mutating func record(_ ms: Double) {
            values[next] = ms
            next = (next + 1) % PerfStats.capacity
            count = min(count + 1, PerfStats.capacity)
            last = ms
        }
    }
    private let rings = Mutex([String: Ring]())

    public init() {}

    /// Records one duration in milliseconds.
    public func record(_ metric: String, ms: Double) {
        rings.withLock { r in
            // In place through the dictionary's default subscript: copying the ring out and
            // back would copy its 256-value array on every call.
            r[metric, default: Ring()].record(ms)
        }
    }

    public func summary(_ metric: String) -> Summary? {
        guard let ring = rings.withLock({ $0[metric] }), ring.count > 0 else { return nil }
        let sorted = ring.values.prefix(ring.count).sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))] }
        return Summary(count: ring.count, last: ring.last, median: pct(0.5), p95: pct(0.95), max: sorted.last!)
    }

    public var metrics: [String] { rings.withLock { $0.keys.sorted() } }
}
