import Foundation

/// Ordering and selection rules of the ⌘Tab switcher, kept pure so they can be checked.
public enum SwitcherLogic {
    public static let maxItems = 20

    /// The switcher list: the focused window first (if allowed), then most recently used,
    /// then on-screen stacking order, then anything else known (other Spaces, full screen).
    /// `include` filters (⌘` keeps only the current workspace of the mouse's screen).
    public static func order(focused: UInt32?, mru: [UInt32], zOrder: [UInt32], others: [UInt32],
                             include: (UInt32) -> Bool) -> [UInt32] {
        order(focused: focused, mru: mru, zOrder: { zOrder }, others: others, include: include)
    }

    /// Same, with the stacking order fetched only if focused + recent windows don't fill the
    /// list (it costs a WindowServer call; most presses never need it).
    public static func order(focused: UInt32?, mru: [UInt32], zOrder: () -> [UInt32], others: [UInt32],
                             include: (UInt32) -> Bool) -> [UInt32] {
        var out: [UInt32] = []
        var seen = Set<UInt32>()
        func add(_ id: UInt32) {
            guard out.count < maxItems, !seen.contains(id), include(id) else { return }
            seen.insert(id)
            out.append(id)
        }
        if let focused { add(focused) }
        mru.forEach(add)
        if out.count < maxItems { zOrder().forEach(add) }
        if out.count < maxItems { others.forEach(add) }
        return out
    }

    /// The first highlighted index, or nil when there is nothing to switch to.
    /// With the focused window first, ⌘Tab starts on the next one (a quick tap toggles between
    /// the last two windows) and ⌘⇧Tab on the last. Without it (⌘` from the other screen),
    /// ⌘` starts on the first entry: that screen's most recent window.
    public static func initialIndex(count: Int, focusedFirst: Bool, step: Int) -> Int? {
        if focusedFirst {
            guard count >= 2 else { return nil }
            return wrap(step >= 0 ? 1 : count - 1, count)
        }
        guard count >= 1 else { return nil }
        return step >= 0 ? 0 : count - 1
    }

    public static func move(_ index: Int, by step: Int, count: Int) -> Int {
        wrap(index + step, count)
    }

    private static func wrap(_ i: Int, _ n: Int) -> Int { ((i % n) + n) % n }
}
