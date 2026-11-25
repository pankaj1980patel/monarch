import CoreGraphics

/// What focus decisions need to know about a window.
public struct FocusCandidate: Sendable, Equatable {
    public let id: UInt32
    public let pid: Int32
    public let frame: CGRect
    public let isMinimized: Bool
    public let appHidden: Bool

    public init(id: UInt32, pid: Int32, frame: CGRect, isMinimized: Bool, appHidden: Bool) {
        self.id = id; self.pid = pid; self.frame = frame
        self.isMinimized = isMinimized; self.appHidden = appHidden
    }
}

/// Per-display "last used window" plus a global most-recently-used list. Main actor only in
/// the app; a plain value type here so it can be checked in isolation.
public struct FocusHistory: Sendable {
    public static let mruLimit = 60
    public private(set) var lastByDisplay: [UInt32: UInt32] = [:]
    public private(set) var mru: [UInt32] = []

    public init() {}

    public mutating func record(window: UInt32, display: UInt32) {
        lastByDisplay[display] = window
        mru.removeAll { $0 == window }
        mru.insert(window, at: 0)
        if mru.count > Self.mruLimit { mru.removeLast() }
    }

    public mutating func forget(window: UInt32) {
        mru.removeAll { $0 == window }
        for (d, w) in lastByDisplay where w == window { lastByDisplay.removeValue(forKey: d) }
    }

    public mutating func keepDisplays(_ ids: Set<UInt32>) {
        lastByDisplay = lastByDisplay.filter { ids.contains($0.key) }
    }
}

public enum FocusLogic {
    /// A window counts as being on a display only if at least this much of it is visible there.
    /// This also excludes windows Hammerspoon parks off-screen for hidden workspaces
    /// (only a 1×30 pt sliver of those stays on screen).
    public static let minVisibleFraction = 0.3

    public static func visibleFraction(_ frame: CGRect, on area: CGRect) -> Double {
        guard frame.width > 0, frame.height > 0 else { return 0 }
        let i = frame.intersection(area)
        guard !i.isNull else { return 0 }
        return Double(i.width * i.height) / Double(frame.width * frame.height)
    }

    /// True when `w` can sensibly receive focus on `display`.
    public static func isUsable(_ w: FocusCandidate, on display: Display, in displays: [Display]) -> Bool {
        !w.isMinimized && !w.appHidden
            && Geometry.display(for: w.frame, in: displays)?.id == display.id
            && visibleFraction(w.frame, on: display.frame) >= minVisibleFraction
    }

    /// The window to focus when the mouse arrives on `display`, or nil to do nothing.
    ///
    /// 1. The focused window is already on that display: nothing to do.
    /// 2. The window last used on that display.
    /// 3. The most recently used window that is on that display.
    /// 4. The top-most window on that display (`zOrder` is front-to-back; only called if needed).
    public static func windowForScreen(_ display: Display, displays: [Display], focused: UInt32?,
                                       windows: [UInt32: FocusCandidate], history: FocusHistory,
                                       zOrder: () -> [UInt32]) -> UInt32? {
        func usable(_ id: UInt32?) -> Bool {
            guard let id, let w = windows[id] else { return false }
            return isUsable(w, on: display, in: displays)
        }
        if usable(focused) { return nil }
        if let last = history.lastByDisplay[display.id], usable(last) { return last }
        if let recent = history.mru.first(where: { usable($0) }) { return recent }
        return zOrder().first(where: { usable($0) })
    }

    public enum Direction: Sendable { case west, east, north, south }

    /// The nearest window in `direction` from `from`. A candidate's centre must lie in a 90° cone
    /// pointing that way; among those, distance along the direction plus twice the sideways
    /// offset decides, so a window straight ahead beats a closer one off to the side.
    public static func window(in direction: Direction, from: CGRect, candidates: [FocusCandidate]) -> UInt32? {
        let c = CGPoint(x: from.midX, y: from.midY)
        var best: (id: UInt32, score: CGFloat)?
        for w in candidates where !w.isMinimized && !w.appHidden {
            let dx = w.frame.midX - c.x, dy = w.frame.midY - c.y
            let (along, side): (CGFloat, CGFloat)
            switch direction {
            case .west: (along, side) = (-dx, abs(dy))
            case .east: (along, side) = (dx, abs(dy))
            case .north: (along, side) = (-dy, abs(dx))
            case .south: (along, side) = (dy, abs(dx))
            }
            guard along > 0, side <= along else { continue }
            let score = along + 2 * side
            if best == nil || score < best!.score { best = (w.id, score) }
        }
        return best?.id
    }
}
