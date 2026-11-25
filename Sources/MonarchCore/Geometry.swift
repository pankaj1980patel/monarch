import CoreGraphics

/// A display as the window engine sees it. All rects use Accessibility coordinates:
/// origin at the top-left of the primary display, y grows downwards.
public struct Display: Sendable, Equatable {
    public let id: UInt32
    public let name: String
    public let isBuiltin: Bool
    /// Whole display.
    public let frame: CGRect
    /// Display minus menu bar and Dock.
    public let visibleFrame: CGRect
    /// Stable display UUID (the same string Hammerspoon's screen:getUUID() returns).
    public let uuid: String

    public init(id: UInt32, name: String, isBuiltin: Bool, frame: CGRect, visibleFrame: CGRect, uuid: String = "") {
        self.id = id
        self.name = name
        self.isBuiltin = isBuiltin
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.uuid = uuid
    }
}

/// A rectangle expressed as fractions of a display's visible frame.
public struct UnitRect: Sendable, Equatable {
    public let x: Double, y: Double, w: Double, h: Double
    public init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
}

public enum Geometry {
    /// Converts a Cocoa rect (bottom-left origin) to Accessibility coordinates (top-left origin).
    /// `primaryHeight` is the height of the primary display (the one at Cocoa origin 0,0).
    public static func cocoaToAX(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Absolute rect for a unit rect inside `area`, rounded to whole points.
    public static func rect(for unit: UnitRect, in area: CGRect) -> CGRect {
        let x = (area.minX + area.width * unit.x).rounded()
        let y = (area.minY + area.height * unit.y).rounded()
        let maxX = (area.minX + area.width * (unit.x + unit.w)).rounded()
        let maxY = (area.minY + area.height * (unit.y + unit.h)).rounded()
        return CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
    }

    /// The display holding most of `window`; the nearest one if it touches none.
    public static func display(for window: CGRect, in displays: [Display]) -> Display? {
        var best: Display?
        var bestArea: CGFloat = 0
        for d in displays {
            let i = d.frame.intersection(window)
            let area = i.isNull ? 0 : i.width * i.height
            if area > bestArea { bestArea = area; best = d }
        }
        if let best { return best }
        let c = CGPoint(x: window.midX, y: window.midY)
        return displays.min { distance2(c, $0.frame) < distance2(c, $1.frame) }
    }

    public enum Direction: Sendable { case west, east, next }

    /// The display in `direction` from `current`. With no display that way, falls back to the
    /// next one, so "move to the other screen" also works when screens are stacked vertically.
    public static func neighbor(of current: Display, _ direction: Direction, in displays: [Display]) -> Display? {
        let others = displays.filter { $0.id != current.id }
        guard !others.isEmpty else { return nil }
        let cx = current.frame.midX
        let candidates: [Display]
        switch direction {
        case .west: candidates = others.filter { $0.frame.midX < cx }
        case .east: candidates = others.filter { $0.frame.midX > cx }
        case .next: candidates = []
        }
        if let nearest = candidates.min(by: { abs($0.frame.midX - cx) < abs($1.frame.midX - cx) }) {
            return nearest
        }
        // Stable "next" order: by position, left-to-right then top-to-bottom.
        let ordered = displays.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        guard let i = ordered.firstIndex(where: { $0.id == current.id }) else { return others.first }
        return ordered[(i + 1) % ordered.count]
    }

    /// Maps `r` proportionally from `src` to `dst` (keeps relative size and position), then keeps it inside `dst`.
    public static func map(_ r: CGRect, from src: CGRect, to dst: CGRect) -> CGRect {
        guard src.width > 0, src.height > 0 else { return clamp(r, into: dst) }
        let sx = dst.width / src.width, sy = dst.height / src.height
        let out = CGRect(x: dst.minX + (r.minX - src.minX) * sx,
                         y: dst.minY + (r.minY - src.minY) * sy,
                         width: r.width * sx, height: r.height * sy)
        return clamp(out, into: dst).integral
    }

    /// Shrinks and shifts `r` so it lies within `area`.
    public static func clamp(_ r: CGRect, into area: CGRect) -> CGRect {
        let w = min(r.width, area.width), h = min(r.height, area.height)
        let x = min(max(r.minX, area.minX), area.maxX - w)
        let y = min(max(r.minY, area.minY), area.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// True when two frames match within `tolerance` points on every edge.
    public static func nearlyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    public static func sameSize(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private static func distance2(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }
}
