/// Keeps a three- or four-finger swipe from also scrolling the window under the mouse.
///
/// macOS scrolls whenever exactly two fingers move. During a swipe that happens when the
/// fingers lift one by one (the last two are still moving), or when a resting thumb and one
/// finger stay down; and the scroll then coasts on (momentum events) for up to a second.
/// So once a swipe is recognized (locked), scroll events are dropped:
/// - while any finger is still on the trackpad,
/// - for `tail` seconds after the last one lifts,
/// - and coasting (momentum) events until a new scroll starts.
///
/// Fail-safe: touch frames arrive continuously while fingers are down. If none came for
/// `stale` seconds (a lost lift frame, trackpad unplugged, gestures stopped), nothing is
/// dropped any more, so scrolling can never stay blocked.
///
/// Scrolling before the swipe is recognized (two fingers landing a moment before the third)
/// isn't touched: it can't be told apart from a real scroll yet.
public struct ScrollGuard: Sendable, Equatable {
    public static let tail = 0.25
    public static let stale = 0.3

    private var guarding = false
    private var lastFrame = -Double.infinity
    private var releasedAt = -Double.infinity
    private var blockMomentum = false

    public init() {}

    /// One touch frame: whether a swipe is locked, and how many contacts are down.
    public mutating func frame(locked: Bool, contacts: Int, now: Double) {
        lastFrame = now
        if locked { guarding = true }
        if guarding && contacts == 0 {
            guarding = false
            releasedAt = now
            blockMomentum = true
        }
    }

    /// Gestures stopped (or reset): drop nothing.
    public mutating func clear() { self = ScrollGuard() }

    /// Whether to drop a scroll event. `phase` and `momentum` are the event's scroll phase and
    /// momentum phase (0 = none; phase 1 = began).
    public mutating func shouldDrop(phase: Int, momentum: Int, now: Double) -> Bool {
        if guarding {
            if now - lastFrame <= Self.stale { return true }
            guarding = false                                     // lost the lift: stop guarding
            releasedAt = lastFrame
            blockMomentum = true
        }
        if now - releasedAt <= Self.tail { return true }
        if blockMomentum {
            if momentum != 0 { return true }                     // the swipe's scroll coasting on
            if phase == 1 || phase == 0 { blockMomentum = false } // a new scroll (or a wheel mouse)
        }
        return false
    }
}
