/// Keeps a three- or four-finger swipe from also scrolling the window under the mouse.
///
/// macOS scrolls whenever exactly two fingers move. During a swipe that happens when the
/// fingers lift one by one (the last two are still moving), and the scroll then coasts on
/// (momentum events) for up to a second or two. So while a swipe is recognized (locked) on any
/// trackpad, trackpad scrolling is suppressed:
/// - until that swipe ends (its own fingers have lifted; a resting thumb doesn't count, or
///   scrolling would stay blocked for as long as the thumb rests),
/// - for `tail` seconds after the last swipe ends,
/// - and coasting (momentum) events after it, until a new scroll starts or `momentumMax`.
///
/// Each trackpad has its own bit, so one trackpad can't end another's swipe.
/// A mouse wheel (non-continuous scrolling) is never touched.
///
/// Fail-safe: touch frames arrive continuously while a swipe's fingers are down. If none came
/// for `stale` seconds (a lost lift frame, trackpad unplugged, gestures stopped), the guard
/// lets go, so scrolling can never stay blocked.
///
/// Scrolling before the swipe is recognized (two fingers landing a moment before the third)
/// isn't touched: it can't be told apart from a real scroll yet.
public struct ScrollGuard: Sendable, Equatable {
    public static let tail = 0.25
    public static let stale = 0.3
    public static let momentumMax = 3.0

    private var lockedMask: UInt16 = 0
    private var lastFrame = -Double.infinity
    private var releasedAt = -Double.infinity
    private var blockMomentum = false

    public init() {}

    /// One touch frame of trackpad `device` (0…15): whether its swipe is locked. Returns true
    /// when guarding starts (the scroll filter should be switched on).
    @discardableResult
    public mutating func frame(device: Int, locked: Bool, now: Double) -> Bool {
        let bit = UInt16(1) << UInt16(min(max(device, 0), 15))
        if locked {
            let started = lockedMask == 0
            lockedMask |= bit
            lastFrame = now
            return started
        }
        guard lockedMask & bit != 0 else { return false }
        lockedMask &= ~bit                                       // this trackpad's swipe ended
        lastFrame = now
        if lockedMask == 0 { release(at: now) }
        return false
    }

    private mutating func release(at t: Double) {
        lockedMask = 0
        releasedAt = t
        blockMomentum = true
    }

    /// Gestures stopped (or reset): suppress nothing.
    public mutating func clear() { self = ScrollGuard() }

    /// Whether to suppress a scroll event. `phase` and `momentum` are its scroll phase and
    /// momentum phase (0 = none; phase 1 = began); `continuous` is false for a mouse wheel.
    public mutating func shouldDrop(phase: Int, momentum: Int, continuous: Bool, now: Double) -> Bool {
        guard continuous else { return false }                   // a mouse wheel: never
        if lockedMask != 0 {
            if now - lastFrame <= Self.stale { return true }
            release(at: lastFrame)                               // lost the lift: let go
        }
        if now - releasedAt <= Self.tail { return true }
        if blockMomentum {
            if now - releasedAt > Self.momentumMax { blockMomentum = false; return false }
            if momentum != 0 { return true }                     // the swipe's scroll coasting on
            if phase == 1 || phase == 0 { blockMomentum = false } // a new scroll
        }
        return false
    }

    /// Nothing left to suppress: the scroll filter can be switched off.
    public func isIdle(now: Double) -> Bool {
        lockedMask == 0 && now - releasedAt > Self.tail && (!blockMomentum || now - releasedAt > Self.momentumMax)
    }
}
