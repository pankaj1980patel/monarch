/// Trackpad gesture settings (config.json "gestures").
public struct GestureConfig: Codable, Sendable, Equatable {
    public enum Trigger: String, Codable, Sendable { case swipe, lift }
    public var enabled = true
    /// Four-finger workspace switch: `swipe` acts as soon as the distance is reached,
    /// `lift` when the fingers come up. (Three-finger gestures always decide on lift.)
    public var trigger: Trigger = .swipe
    /// Distance (fraction of the trackpad) a three / four finger swipe must travel to count.
    public var threeFinger = 0.07
    public var fourFinger = 0.10
    /// The main axis must be this many times the other axis (real trackpad proportions).
    public var ratio = 1.5
    /// Seconds after the fingers lift during which overview clicks are ignored.
    public var clickGuard = 0.35
    /// Movement (fraction of the trackpad) after which finger count and direction are locked.
    public var lockDistance = 0.012
    /// Three-finger travel (fraction of the trackpad) that fully opens / closes the overview.
    public var overviewTravel = 0.18

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GestureConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        trigger = try c.decodeIfPresent(Trigger.self, forKey: .trigger) ?? d.trigger
        threeFinger = try c.decodeIfPresent(Double.self, forKey: .threeFinger) ?? d.threeFinger
        fourFinger = try c.decodeIfPresent(Double.self, forKey: .fourFinger) ?? d.fourFinger
        ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? d.ratio
        clickGuard = try c.decodeIfPresent(Double.self, forKey: .clickGuard) ?? d.clickGuard
        lockDistance = try c.decodeIfPresent(Double.self, forKey: .lockDistance) ?? d.lockDistance
        overviewTravel = try c.decodeIfPresent(Double.self, forKey: .overviewTravel) ?? d.overviewTravel
    }

    /// The settings Hammerspoon uses from its saved "gesture.cfg" (numbers only, like Hammerspoon).
    public init(hammerspoon cfg: [String: Any]) {
        self.init()
        if let t = cfg["trigger"] as? String, let tr = Trigger(rawValue: t) { trigger = tr }
        func num(_ k: String) -> Double? { (cfg[k] is String) ? nil : (cfg[k] as? Double) ?? (cfg[k] as? Int).map(Double.init) }
        threeFinger = num("sw3") ?? threeFinger
        fourFinger = num("sw4") ?? fourFinger
        ratio = num("ratio") ?? ratio
        clickGuard = num("guard") ?? clickGuard
    }

    public func threshold(fingers: Int) -> Double { fingers == 3 ? threeFinger : fourFinger }
}

/// One finger on the trackpad. Positions are 0…1 with y growing upwards.
public struct TouchPoint: Sendable, Equatable {
    public var id: Int32
    public var x: Float
    public var y: Float
    public init(id: Int32, x: Float, y: Float) { self.id = id; self.x = x; self.y = y }
}

public enum SwipeDirection: String, Sendable { case left, right, up, down }
public enum GestureAxis: UInt8, Sendable { case horizontal = 1, vertical = 2 }

/// A locked gesture: finger count and axis are fixed; displacement is signed along the axis
/// (right / up positive), in fractions of the trackpad.
public struct SwipeSample: Sendable, Equatable {
    public var fingers: Int
    public var axis: GestureAxis
    public var displacement: Double
    /// Speed along the axis at release (fractions of the trackpad per second, signed).
    public var velocity: Double
    public var direction: SwipeDirection {
        switch axis {
        case .horizontal: displacement < 0 ? .left : .right
        case .vertical: displacement < 0 ? .down : .up
        }
    }
    public var distance: Double { abs(displacement) }
}

/// What one frame produced. Plain fields, no allocation.
public struct GestureOutput: Sendable, Equatable {
    /// Three or more fingers came down (overview click guard starts).
    public var began = false
    /// Finger count and axis just locked.
    public var locked: SwipeSample?
    /// The locked swipe just travelled its threshold (once per gesture).
    public var crossed: SwipeSample?
    /// All fingers lifted after a locked swipe (exactly once per gesture).
    public var ended: SwipeSample?
    /// All fingers are off again after `began` (exactly once).
    public var lifted = false
    public init() {}
    public var isEmpty: Bool { !began && locked == nil && crossed == nil && ended == nil && !lifted }
}

/// Deterministic three/four-finger swipe recognition for one trackpad.
///
/// - Tracking: from the moment 3+ fingers are down, every finger is followed by its id and the
///   movement is the average of each finger's travel from where it landed (fingers landing a
///   little apart don't spoil it). A finger joining before the lock restarts the measurement.
/// - Lock: once the movement reaches `lockDistance` and one axis dominates by `ratio`, the
///   finger count and axis are fixed until every finger lifts. Later finger changes, wobble on
///   the other axis and direction reversals can't turn it into a different gesture.
/// - Five or more fingers cancel the gesture (a palm, not a swipe).
/// - Events: `began`, `locked`, `crossed` (threshold reached), `ended` (lift), `lifted` —
///   each at most once per gesture.
///
/// No allocation per frame: fixed storage for 10 fingers and 8 velocity samples.
public struct GestureRecognizer: Sendable {
    public var config: GestureConfig
    /// Real trackpad proportions, so a 45° swipe on a wide trackpad is really 45°.
    public var aspect: (w: Double, h: Double) = (1, 1)

    private enum Phase { case idle, tracking, locked, cancelled }
    private var phase = Phase.idle
    private var began = false
    private var ids = [Int32](repeating: 0, count: 10)
    private var sx = [Float](repeating: 0, count: 10)
    private var sy = [Float](repeating: 0, count: 10)
    private var count = 0
    private var lockedSample: SwipeSample?
    private var crossed = false
    // Velocity ring: (time, displacement) along the locked axis.
    private var vt = [Double](repeating: 0, count: 8)
    private var vd = [Double](repeating: 0, count: 8)
    private var vn = 0, vi = 0

    public init(config: GestureConfig) { self.config = config }

    /// Direction lock needs at least this much dominance, whatever `ratio` says.
    public static let minimumLockRatio = 1.2

    /// The current locked gesture (for continuous feedback), or nil.
    public var current: SwipeSample? { phase == .locked ? lockedSample : nil }

    /// Forgets everything (sleep, device change). Returns `lifted` if a gesture was in progress.
    public mutating func reset() -> GestureOutput {
        var out = GestureOutput()
        out.lifted = began
        phase = .idle; began = false; count = 0; lockedSample = nil; crossed = false; vn = 0; vi = 0
        return out
    }

    /// Feeds one frame of fingers on the glass, with the frame's timestamp (seconds).
    public mutating func process(_ touches: UnsafeBufferPointer<TouchPoint>, time: Double) -> GestureOutput {
        var out = GestureOutput()
        let n = min(touches.count, 10)

        if n == 0 {                                              // all lifted
            if phase == .locked, var s = lockedSample {
                s.velocity = velocity()
                out.ended = s
            }
            let wasBegan = began
            _ = reset()
            out.lifted = wasBegan
            return out
        }
        if n >= 3 && !began { began = true; out.began = true }
        if phase == .cancelled { return out }
        if touches.count >= 5 && phase != .locked { phase = .cancelled; return out }

        switch phase {
        case .idle, .tracking:
            guard n >= 3 else { return out }          // partial lift before the lock: wait
            // New finger set (more fingers, or a different finger): restart measuring.
            var fresh = phase == .idle || n > count
            if !fresh && n == count {
                for i in 0..<n where !ids[0..<count].contains(touches[i].id) { fresh = true; break }
            }
            if fresh {
                phase = .tracking
                count = n
                for i in 0..<n { ids[i] = touches[i].id; sx[i] = touches[i].x; sy[i] = touches[i].y }
                return out
            }
            guard n == count, n == 3 || n == 4, let (dx, dy) = average(touches) else { return out }
            let px = abs(dx) * aspect.w, py = abs(dy) * aspect.h
            // A ratio of 1 would lock a 45° diagonal to whichever axis is a hair ahead.
            let ratio = max(config.ratio, Self.minimumLockRatio)
            let axis: GestureAxis
            if px >= py * ratio && abs(dx) >= config.lockDistance { axis = .horizontal }
            else if py >= px * ratio && abs(dy) >= config.lockDistance { axis = .vertical }
            else { return out }
            phase = .locked
            let s = SwipeSample(fingers: n, axis: axis, displacement: axis == .horizontal ? dx : dy, velocity: 0)
            lockedSample = s
            record(time, s.displacement)
            out.locked = s
            if s.distance >= config.threshold(fingers: n) { crossed = true; out.crossed = s }

        case .locked:
            guard var s = lockedSample, let (dx, dy) = average(touches) else { return out }
            s.displacement = s.axis == .horizontal ? dx : dy
            lockedSample = s
            record(time, s.displacement)
            if !crossed && s.distance >= config.threshold(fingers: s.fingers) { crossed = true; out.crossed = s }

        case .cancelled:
            break
        }
        return out
    }

    /// Average travel of the fingers that are still down and were part of the measurement.
    private func average(_ touches: UnsafeBufferPointer<TouchPoint>) -> (Double, Double)? {
        var dx = 0.0, dy = 0.0, k = 0
        for i in 0..<min(touches.count, 10) {
            guard let j = ids[0..<count].firstIndex(of: touches[i].id) else { continue }
            dx += Double(touches[i].x - sx[j]); dy += Double(touches[i].y - sy[j]); k += 1
        }
        return k > 0 ? (dx / Double(k), dy / Double(k)) : nil
    }

    private mutating func record(_ t: Double, _ d: Double) {
        vt[vi] = t; vd[vi] = d
        vi = (vi + 1) % 8
        vn = min(vn + 1, 8)
    }

    /// Speed over the last ~80 ms of samples.
    private func velocity() -> Double {
        guard vn >= 2 else { return 0 }
        let last = (vi + 7) % 8
        var first = last
        for k in 1..<vn {
            let j = (last - k + 8) % 8
            if vt[last] - vt[j] > 0.08 { break }
            first = j
        }
        let dt = vt[last] - vt[first]
        return dt > 0.004 ? (vd[last] - vd[first]) / dt : 0
    }
}

/// How the overview reacts when three fingers lift: finish or go back.
public enum InteractiveDecision {
    /// `progress` 0…1 toward the goal; `velocity` in progress per second (toward the goal positive).
    public static func complete(progress: Double, velocity: Double) -> Bool {
        if velocity > 1.5 { return true }          // a flick toward the goal
        if velocity < -1.5 { return false }        // a flick back
        return progress >= 0.5
    }
}
