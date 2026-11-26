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
    /// Leave out resting contacts (a thumb in `thumbArea`): the gesture's fingers are the ones
    /// that move together. Without it a resting thumb turns a two-finger scroll into a
    /// three-finger swipe, and a three-finger swipe into a four-finger one.
    public var thumbRejection = true
    /// Where on the trackpad a resting thumb is looked for: `left` (right-handed: the thumb
    /// rests left of the fingers), `right` (left-handed), `both` (a strip at each side, for
    /// either hand) or `anywhere`. A contact outside it always counts as a finger.
    public enum ThumbArea: String, Codable, Sendable, CaseIterable { case left, right, both, anywhere }
    public var thumbArea: ThumbArea = .left
    /// Width of the thumb area at a side, as a fraction of the trackpad's width (0.1…0.5).
    public var thumbAreaWidth = 1.0 / 3
    /// Drop scroll events while a three- or four-finger swipe is under way (see `ScrollGuard`):
    /// fingers lifting one by one would otherwise scroll the window under the mouse.
    public var blockScroll = true

    /// True if a contact that landed at `x` (0 = left edge, 1 = right edge) may be a thumb.
    public func inThumbArea(_ x: Float) -> Bool {
        let w = Float(thumbAreaWidth)
        switch thumbArea {
        case .left: return x < w
        case .right: return x > 1 - w
        case .both: return x < w || x > 1 - w
        case .anywhere: return true
        }
    }

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
        thumbRejection = try c.decodeIfPresent(Bool.self, forKey: .thumbRejection) ?? d.thumbRejection
        thumbArea = try c.decodeIfPresent(ThumbArea.self, forKey: .thumbArea) ?? d.thumbArea
        thumbAreaWidth = try c.decodeIfPresent(Double.self, forKey: .thumbAreaWidth) ?? d.thumbAreaWidth
        blockScroll = try c.decodeIfPresent(Bool.self, forKey: .blockScroll) ?? d.blockScroll
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
/// - Resting contacts (thumb rejection), by motion consensus: the gesture's fingers are the
///   largest group of contacts that move together (same direction, similar distance). Only a
///   contact that landed in the thumb area (`GestureConfig.thumbArea`) can be left out, if it
///   rests or moves differently; any other contact counts as a finger, as without thumb
///   rejection. The group is frozen at the lock.
///   So thumb + two fingers is a scroll (no group of three: no gesture), thumb + three fingers
///   a three-finger swipe, thumb + four fingers a four-finger swipe, and five fingers moving
///   together a palm (cancelled). A thumb that swipes along with the others is in the group.
/// - The gesture ends when its own fingers lift, even if a resting thumb stays down.
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
    // Current positions of the measured contacts, and scratch space for the consensus (fixed
    // storage: nothing is allocated per frame).
    private var cx = [Float](repeating: 0, count: 10)
    private var cy = [Float](repeating: 0, count: 10)
    private var mvx = [Double](repeating: 0, count: 10)
    private var mvy = [Double](repeating: 0, count: 10)
    private var mlen = [Double](repeating: 0, count: 10)
    private var compat = [UInt16](repeating: 0, count: 10)
    private var lastTime = -Double.infinity
    /// Which measured contacts are down this frame (bit j = ids[j]). A contact that lifts
    /// before the lock keeps its landing point, in case the same finger comes back.
    private var present: UInt16 = 0
    // Recent positions: 4 frames per contact (slot = j * 4 + frame % 4), for "how is it moving
    // now" next to "how far has it moved since landing".
    private var hx = [Float](repeating: 0, count: 40)
    private var hy = [Float](repeating: 0, count: 40)
    private var hslot = 0
    private var rvx = [Double](repeating: 0, count: 10)
    private var rvy = [Double](repeating: 0, count: 10)
    private var rlen = [Double](repeating: 0, count: 10)
    /// When a moving group first appeared in this measurement (observation window start).
    private var groupSince: Double?
    private var now = 0.0
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
        phase = .idle; began = false; count = 0; present = 0; groupSince = nil; lockedSample = nil; crossed = false; vn = 0; vi = 0
        return out
    }

    /// Feeds one frame of fingers on the glass, with the frame's timestamp (seconds).
    // Motion consensus (see the type's notes). Starting values from the design discussion;
    // distances are in fractions of the trackpad's longer side.
    /// Two contacts move together when both have moved at least this × `lockDistance`, the
    /// smaller movement is at least `consensusMinRatio` of the larger, and their directions
    /// agree to `consensusMinCosine`.
    public static let consensusMinMove = 0.5
    public static let consensusMinRatio = 0.45
    public static let consensusMinCosine = 0.85
    /// A contact outside the moving group is resting below this share of the group's movement.
    public static let restingShare = 0.35
    /// …and moving like a finger of the group from this share on (same direction).
    public static let participatingShare = 0.6
    /// Leaving a contact out waits until the group has moved this × `lockDistance`: a clearly
    /// still contact (below `stillShare`) after `decideStill`, anything less clear after
    /// `decideBy`. A finger of a real four-finger swipe that starts moving a few ms late looks
    /// still at first; the wait lets it catch up and join, instead of turning the swipe into a
    /// three-finger one. With no extra contact there's no wait.
    public static let stillShare = 0.15
    public static let decideStill = 1.5
    public static let decideBy = 2.5
    /// …and at least this long after the group started moving (seconds): long enough for a
    /// late finger's recent movement to match the others', while a resting thumb's stays ~0.
    public static let observeFor = 0.032
    /// Frames further apart than this (dropped frames) restart the measurement.
    public static let maxGap = 0.1

    public mutating func process(_ touches: UnsafeBufferPointer<TouchPoint>, time: Double) -> GestureOutput {
        var out = GestureOutput()
        let n = min(touches.count, 10)
        let gap = time - lastTime
        lastTime = time
        now = time

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
        // More contacts than a swipe has: a palm. With thumb rejection one resting extra is fine.
        if n > (config.thumbRejection ? 5 : 4) && phase != .locked { phase = .cancelled; return out }

        switch phase {
        case .idle, .tracking:
            guard sync(touches, gap: gap) else { return out }      // measurement (re)started this frame
            guard present.nonzeroBitCount >= 3 else { return out } // fewer than three down: wait
            var mask = present
            if config.thumbRejection {
                switch consensus() {
                case .wait: return out
                case .cancel: phase = .cancelled; return out
                case let .group(m): mask = m
                }
                if mask.nonzeroBitCount > 4 { phase = .cancelled; return out }   // five fingers: a palm
            }
            let k = mask.nonzeroBitCount
            guard k == 3 || k == 4, let (dx, dy) = average(touches, mask: mask) else { return out }
            let px = abs(dx) * aspect.w, py = abs(dy) * aspect.h
            // A ratio of 1 would lock a 45° diagonal to whichever axis is a hair ahead.
            let ratio = max(config.ratio, Self.minimumLockRatio)
            let axis: GestureAxis
            if px >= py * ratio && abs(dx) >= config.lockDistance { axis = .horizontal }
            else if py >= px * ratio && abs(dy) >= config.lockDistance { axis = .vertical }
            else { return out }
            freeze(mask)                                           // the gesture's fingers, from now on
            phase = .locked
            let s = SwipeSample(fingers: k, axis: axis, displacement: axis == .horizontal ? dx : dy, velocity: 0)
            lockedSample = s
            record(time, s.displacement)
            out.locked = s
            if s.distance >= config.threshold(fingers: k) { crossed = true; out.crossed = s }

        case .locked:
            // Its fingers are gone (a resting thumb may still be down): the gesture is over.
            guard ids[0..<count].contains(where: { id in touches.prefix(n).contains { $0.id == id } }) else {
                if var s = lockedSample { s.velocity = velocity(); out.ended = s }
                let wasBegan = began
                _ = reset()
                out.lifted = wasBegan
                return out
            }
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

    /// Keeps the measured contacts in step with the frame. Returns false when the measurement
    /// (re)started this frame: first contacts, a contact that just landed (every landing point
    /// is taken again, so fingers landing a moment apart don't look like they moved less), or
    /// a gap of dropped frames. A contact that lifted is kept, marked absent (`present`).
    private mutating func sync(_ touches: UnsafeBufferPointer<TouchPoint>, gap: Double) -> Bool {
        let n = min(touches.count, 10)
        var restart = phase == .idle || gap > Self.maxGap
        if !restart {
            for i in 0..<n where !ids[0..<count].contains(touches[i].id) { restart = true; break }
        }
        if restart {
            phase = .tracking
            count = n
            for i in 0..<n {
                ids[i] = touches[i].id; sx[i] = touches[i].x; sy[i] = touches[i].y; cx[i] = sx[i]; cy[i] = sy[i]
                for k in 0..<4 { hx[i * 4 + k] = sx[i]; hy[i * 4 + k] = sy[i] }
            }
            present = UInt16((1 << n) - 1)
            groupSince = nil
            return false
        }
        present = 0
        hslot = (hslot + 1) & 3
        for j in 0..<count {
            if let t = touches.prefix(n).first(where: { $0.id == ids[j] }) {
                cx[j] = t.x; cy[j] = t.y
                present |= 1 << j
            }                                                       // lifted for now: keeps its last position
            hx[j * 4 + hslot] = cx[j]; hy[j * 4 + hslot] = cy[j]
        }
        return true
    }

    private enum Consensus { case wait, cancel, group(UInt16) }

    /// Finds the gesture's fingers among the measured contacts by how they move, not where
    /// they are. Bit j of the group is ids[j].
    private mutating func consensus() -> Consensus {
        // Proportions of the trackpad, so equal numbers mean equal distances on the glass.
        let longer = max(aspect.w, aspect.h, 1e-9)
        let ax = aspect.w / longer, ay = aspect.h / longer
        let oldest = (hslot + 1) & 3                            // 3 frames back (~25 ms)
        for j in 0..<count where present & (1 << j) != 0 {
            mvx[j] = Double(cx[j] - sx[j]) * ax
            mvy[j] = Double(cy[j] - sy[j]) * ay
            mlen[j] = (mvx[j] * mvx[j] + mvy[j] * mvy[j]).squareRoot()
            rvx[j] = Double(cx[j] - hx[j * 4 + oldest]) * ax
            rvy[j] = Double(cy[j] - hy[j * 4 + oldest]) * ay
            rlen[j] = (rvx[j] * rvx[j] + rvy[j] * rvy[j]).squareRoot()
            compat[j] = 0
        }
        // Contacts that may be a thumb. None: every contact is a finger.
        var zone: UInt16 = 0
        for j in 0..<count where present & (1 << j) != 0 && config.inThumbArea(sx[j]) { zone |= 1 << j }
        if zone == 0 { return .group(present) }
        // Which pairs move together.
        let minMove = config.lockDistance * Self.consensusMinMove
        for i in 0..<count where present & (1 << i) != 0 {
            for j in (i + 1)..<count where present & (1 << j) != 0 && together(i, j, minMove: minMove) {
                compat[i] |= 1 << j; compat[j] |= 1 << i
            }
        }
        // The largest group whose members all move together (four, else three); among equal
        // groups the one that moved most. At most 2^10 masks, before the lock only.
        var best: UInt16 = 0, bestMove = -1.0
        for size in stride(from: min(4, present.nonzeroBitCount), through: 3, by: -1) {
            for m in 1..<(1 << count) where m.nonzeroBitCount == size && UInt16(m) & ~present == 0 {
                let mask = UInt16(m)
                var clique = true, moved = 0.0
                for j in 0..<count where mask & (1 << j) != 0 {
                    if (compat[j] | (1 << j)) & mask != mask { clique = false; break }
                    moved += mlen[j]
                }
                if clique && moved > bestMove { best = mask; bestMove = moved }
            }
            if best != 0 { break }
        }
        guard best != 0 else { return .wait }          // nothing moving together yet (or 2 fingers + thumb)

        // The group's movement (since landing, and recently), and the others next to it.
        var gx = 0.0, gy = 0.0, hx2 = 0.0, hy2 = 0.0
        let k = Double(best.nonzeroBitCount)
        for j in 0..<count where best & (1 << j) != 0 { gx += mvx[j]; gy += mvy[j]; hx2 += rvx[j]; hy2 += rvy[j] }
        gx /= k; gy /= k; hx2 /= k; hy2 /= k
        let glen = (gx * gx + gy * gy).squareRoot()
        let rglen = (hx2 * hx2 + hy2 * hy2).squareRoot()
        guard glen > 0 else { return .wait }
        if groupSince == nil { groupSince = now }
        let watched = now - (groupSince ?? now) >= Self.observeFor           // observation window done
        let moved = glen / config.lockDistance                               // group movement, × lockDistance
        let decided = moved >= Self.decideBy && watched
        var group = best
        for e in 0..<count where present & (1 << e) != 0 && best & (1 << e) == 0 {
            if zone & (1 << e) == 0 {                                        // not where a thumb rests: a finger
                if best.nonzeroBitCount >= 4 { return .cancel }
                group |= 1 << e
                continue
            }
            // Its movement relative to the group's: since landing, and over the last ~25 ms (a
            // finger that started late is behind on the first and matches on the second).
            let total = mlen[e] / glen
            let recent = rglen > 0 ? rlen[e] / rglen : total
            let share = max(total, recent)
            let useRecent = rglen > 0 && recent > total
            let (ex, ey, el, rx, ry, rl) = useRecent ? (rvx[e], rvy[e], rlen[e], hx2, hy2, rglen) : (mvx[e], mvy[e], mlen[e], gx, gy, glen)
            let cosine = el > 0 ? (ex * rx + ey * ry) / (el * rl) : 0
            if share < Self.stillShare {                                     // still: resting
                if moved < Self.decideStill || !watched { return .wait }
                continue
            }
            if share >= Self.restingShare && cosine < 0.5 {                  // clearly moving its own way
                if moved < Self.decideStill || !watched { return .wait }
                continue
            }
            if share >= Self.participatingShare && cosine >= Self.consensusMinCosine {
                // Moving like one of the fingers. With four already, that's five: a palm.
                if best.nonzeroBitCount >= 4 { return .cancel }
                if !decided { return .wait }                                 // it should join the group
                group |= 1 << e
                continue
            }
            if !decided { return .wait }                                     // unclear (or barely moving): wait
        }
        return group.nonzeroBitCount > 4 ? .cancel : .group(group)
    }

    /// Both contacts clearly moved, by similar amounts, in the same direction.
    private func together(_ a: Int, _ b: Int, minMove: Double) -> Bool {
        let la = mlen[a], lb = mlen[b]
        guard la >= minMove, lb >= minMove, min(la, lb) >= max(la, lb) * Self.consensusMinRatio else { return false }
        let dot = mvx[a] * mvx[b] + mvy[a] * mvy[b]
        return dot > 0 && dot >= Self.consensusMinCosine * la * lb
    }

    /// Keeps only the group's contacts (bit j = ids[j]) as the gesture's fingers.
    private mutating func freeze(_ mask: UInt16) {
        var k = 0
        for j in 0..<count where mask & (1 << j) != 0 {
            ids[k] = ids[j]; sx[k] = sx[j]; sy[k] = sy[j]; cx[k] = cx[j]; cy[k] = cy[j]
            k += 1
        }
        count = k
        present = UInt16((1 << k) - 1)
    }

    /// Average travel of the group's contacts (bit j = ids[j]) that are down.
    private func average(_ touches: UnsafeBufferPointer<TouchPoint>, mask: UInt16) -> (Double, Double)? {
        var dx = 0.0, dy = 0.0, k = 0
        for i in 0..<min(touches.count, 10) {
            guard let j = ids[0..<count].firstIndex(of: touches[i].id), mask & (1 << j) != 0 else { continue }
            dx += Double(touches[i].x - sx[j]); dy += Double(touches[i].y - sy[j]); k += 1
        }
        return k > 0 ? (dx / Double(k), dy / Double(k)) : nil
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
