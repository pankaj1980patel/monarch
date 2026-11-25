import CoreGraphics

/// ⌃⌥⌘ N: tile the top N windows of a screen.
///
/// Windows are split into ceil(√n) columns, filled left to right. Earlier columns get fewer
/// windows, so the front-most window always gets the biggest slot:
///
///   1 → full   2 → ½ | ½   3 → big left + 2 stacked right   4 → 2×2
///   5 → 1 | 2 | 2          7 → 2 | 2 | 3                    9 → 3×3
public enum ArrangeLayout {
    /// How many windows go in each column.
    public static func columnCounts(_ n: Int) -> [Int] {
        guard n > 0 else { return [] }
        let cols = Int(Double(n).squareRoot().rounded(.up))
        let base = n / cols, extra = n % cols
        // The last `extra` columns get one more window.
        return (0..<cols).map { $0 >= cols - extra ? base + 1 : base }
    }

    /// One frame per window, in the same order as the windows (front-most first),
    /// tiling `area` exactly with no gaps or overlaps.
    public static func frames(count n: Int, in area: CGRect) -> [CGRect] {
        let counts = columnCounts(n)
        guard !counts.isEmpty else { return [] }
        var out: [CGRect] = []
        out.reserveCapacity(n)
        for (c, rows) in counts.enumerated() {
            let x0 = (area.minX + area.width * CGFloat(c) / CGFloat(counts.count)).rounded()
            let x1 = (area.minX + area.width * CGFloat(c + 1) / CGFloat(counts.count)).rounded()
            for r in 0..<rows {
                let y0 = (area.minY + area.height * CGFloat(r) / CGFloat(rows)).rounded()
                let y1 = (area.minY + area.height * CGFloat(r + 1) / CGFloat(rows)).rounded()
                out.append(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            }
        }
        return out
    }
}
