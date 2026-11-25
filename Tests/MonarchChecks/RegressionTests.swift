import CoreGraphics
import Foundation
import MonarchCore

// Regression guards for current behaviour. Registered in main.swift.

func close(_ a: Double, _ b: Double, _ eps: Double = 1e-4) -> Bool { abs(a - b) <= eps }

// MARK: - Gestures

struct GestureRegressionTests {
    typealias Frame = [(Int32, Float, Float)]
    func feed(_ r: inout GestureRecognizer, _ frames: [Frame], start: Double = 0, step: Double = 0.01) -> [GestureOutput] {
        var out: [GestureOutput] = []
        for (i, f) in frames.enumerated() {
            let pts = f.map { TouchPoint(id: $0.0, x: $0.1, y: $0.2) }
            let o = pts.withUnsafeBufferPointer { r.process($0, time: start + Double(i) * step) }
            if !o.isEmpty { out.append(o) }
        }
        return out
    }
    func fingers(_ n: Int, _ dx: Float, _ dy: Float, ids: [Int32]? = nil) -> Frame {
        (0..<n).map { (ids?[$0] ?? Int32($0 + 1), 0.2 + Float($0) * 0.1 + dx, 0.5 + dy) }
    }
    func n(_ o: [GestureOutput], _ k: KeyPath<GestureOutput, SwipeSample?>) -> Int { o.filter { $0[keyPath: k] != nil }.count }

    func testMinimumLockRatioFloor() {
        expect(GestureRecognizer.minimumLockRatio == 1.2)
        var cfg = GestureConfig(); cfg.ratio = 1
        // dx 0.02 / dy 0.018: only 1.11x, below the 1.2 floor even though config says 1.
        var r = GestureRecognizer(config: cfg)
        let o = feed(&r, [fingers(3, 0, 0), fingers(3, 0.02, 0.018)])
        expect(n(o, \.locked) == 0)
        expect(r.current == nil)
        // dx 0.03 / dy 0.018: 1.67x, locks horizontal.
        var r2 = GestureRecognizer(config: cfg)
        let o2 = feed(&r2, [fingers(3, 0, 0), fingers(3, 0.03, 0.018)])
        expect(o2.compactMap(\.locked).first?.axis == .horizontal)
        // A ratio above the floor is honoured: 1.67x does not satisfy ratio 2.
        var cfg2 = GestureConfig(); cfg2.ratio = 2
        var r3 = GestureRecognizer(config: cfg2)
        expect(n(feed(&r3, [fingers(3, 0, 0), fingers(3, 0.03, 0.018)]), \.locked) == 0)
        // Exact diagonal never locks, whatever the ratio.
        cfg.ratio = 0.5
        var r4 = GestureRecognizer(config: cfg)
        expect(n(feed(&r4, [fingers(3, 0, 0), fingers(3, 0.05, 0.05)]), \.locked) == 0)
    }

    func testLockDistanceThreshold() {
        var r = GestureRecognizer(config: GestureConfig())          // lockDistance 0.012
        let o = feed(&r, [fingers(3, 0, 0), fingers(3, 0.011, 0)])
        expect(n(o, \.locked) == 0 && r.current == nil)
        let o2 = feed(&r, [fingers(3, 0.013, 0)], start: 1)
        expect(n(o2, \.locked) == 1 && r.current?.axis == .horizontal)
        var cfg = GestureConfig(); cfg.lockDistance = 0.05
        var r2 = GestureRecognizer(config: cfg)
        expect(n(feed(&r2, [fingers(3, 0, 0), fingers(3, 0.04, 0)]), \.locked) == 0)
        expect(n(feed(&r2, [fingers(3, 0.06, 0)], start: 1), \.locked) == 1)
    }

    func testFirstFrameOnlyBaselinesAndBegins() {
        var r = GestureRecognizer(config: GestureConfig())
        let o = feed(&r, [fingers(3, 0, 0)])
        expect(o.count == 1 && o[0].began && o[0].locked == nil && !o[0].lifted)
        // Two fingers never begin.
        var r2 = GestureRecognizer(config: GestureConfig())
        expect(feed(&r2, [fingers(2, 0, 0), fingers(2, 0.2, 0)]).isEmpty)
        expect(feed(&r2, [[]], start: 1).isEmpty)                   // lifting 2 fingers: nothing
    }

    func testCrossedOnceAndAtLockWhenJumpIsBig() {
        var r = GestureRecognizer(config: GestureConfig())
        let o = feed(&r, [fingers(3, 0, 0), fingers(3, 0.2, 0), fingers(3, 0.3, 0), fingers(3, 0.4, 0), []])
        expect(n(o, \.locked) == 1 && n(o, \.crossed) == 1 && n(o, \.ended) == 1)
        // The jump already exceeds the threshold, so lock and crossed arrive in the same frame.
        expect(o[1].locked != nil && o[1].crossed != nil)
        // Slow approach: crossed arrives later, in a later frame than locked.
        var r2 = GestureRecognizer(config: GestureConfig())
        let o2 = feed(&r2, [fingers(3, 0, 0), fingers(3, 0.02, 0), fingers(3, 0.05, 0), fingers(3, 0.08, 0), fingers(3, 0.2, 0), []])
        let li = o2.firstIndex { $0.locked != nil }, ci = o2.firstIndex { $0.crossed != nil }
        expect(li != nil && ci != nil && li! < ci!)
        expect(n(o2, \.crossed) == 1)
        // Threshold: 0.06 does not cross for three fingers, 0.08 does.
        var r3 = GestureRecognizer(config: GestureConfig())
        expect(n(feed(&r3, [fingers(3, 0, 0), fingers(3, 0.06, 0)]), \.crossed) == 0)
        expect(n(feed(&r3, [fingers(3, 0.08, 0)], start: 1), \.crossed) == 1)
        // Four fingers need 0.10.
        var r4 = GestureRecognizer(config: GestureConfig())
        expect(n(feed(&r4, [fingers(4, 0, 0), fingers(4, 0.08, 0)]), \.crossed) == 0)
        expect(n(feed(&r4, [fingers(4, 0.11, 0)], start: 1), \.crossed) == 1)
    }

    func testEndedAndLiftedTogetherAndOnlyOnce() {
        var r = GestureRecognizer(config: GestureConfig())
        let o = feed(&r, [fingers(3, 0, 0), fingers(3, 0, 0.1), []])
        let last = o.last
        expect(last?.ended != nil && last?.lifted == true && last?.began == false)
        // More empty frames afterwards produce nothing.
        expect(feed(&r, [[], [], []], start: 1).isEmpty)
        // Lift without a lock: lifted only.
        var r2 = GestureRecognizer(config: GestureConfig())
        let o2 = feed(&r2, [fingers(3, 0, 0), fingers(3, 0.001, 0), []])
        expect(o2.last?.lifted == true && o2.last?.ended == nil)
    }

    func testFiveFingersCancelBeforeLock() {
        var r = GestureRecognizer(config: GestureConfig())
        let o = feed(&r, [fingers(5, 0, 0), fingers(5, 0, 0.3), fingers(3, 0, 0.3), fingers(3, 0, 0.6), []])
        expect(n(o, \.locked) == 0 && n(o, \.crossed) == 0 && n(o, \.ended) == 0)
        expect(o.filter(\.began).count == 1 && o.filter(\.lifted).count == 1)
        // After lifting, a fresh gesture works again.
        let o2 = feed(&r, [fingers(3, 0, 0), fingers(3, 0, 0.1), []], start: 2)
        expect(n(o2, \.locked) == 1 && n(o2, \.ended) == 1)
    }

    func testFiveFingersAfterLockDoNotCancel() {
        var r = GestureRecognizer(config: GestureConfig())
        let o = feed(&r, [fingers(3, 0, 0), fingers(3, 0, 0.03), fingers(5, 0, 0.1, ids: [1, 2, 3, 4, 5]), []])
        expect(n(o, \.locked) == 1 && n(o, \.ended) == 1)
        expect(o.compactMap(\.ended).first?.direction == .up)
    }

    func testPartialLiftsAfterLockKeepGesture() {
        var r = GestureRecognizer(config: GestureConfig())
        let f2: Frame = [(1, 0.2, 0.5 + 0.12), (2, 0.3, 0.5 + 0.12)]
        let o = feed(&r, [fingers(3, 0, 0), fingers(3, 0, 0.03), f2, [(1, 0.2, 0.5 + 0.2)], []])
        expect(n(o, \.locked) == 1 && n(o, \.crossed) == 1 && n(o, \.ended) == 1)
        let e = o.compactMap(\.ended).first
        expect(e?.fingers == 3 && e?.direction == .up && close(e?.displacement ?? 0, 0.2, 0.005))
        expect(o.filter(\.lifted).count == 1)
    }

    func testPartialLiftBeforeLockWaitsThenResumes() {
        var r = GestureRecognizer(config: GestureConfig())
        let two: Frame = [(1, 0.2, 0.5), (2, 0.3, 0.5)]
        let o = feed(&r, [fingers(3, 0, 0), two, two, fingers(3, 0.1, 0)])
        // Same finger ids come back: still measured from the original landing point.
        expect(o.compactMap(\.locked).first?.axis == .horizontal)
        expect(close(o.compactMap(\.locked).first?.displacement ?? 0, 0.1, 0.005))
    }

    func testFreshFingerSetBeforeLockRestartsMeasurement() {
        // A fourth finger joins: baseline restarts, so the 4-finger swipe is measured from there.
        var r = GestureRecognizer(config: GestureConfig())
        let o = feed(&r, [fingers(3, 0, 0), fingers(3, 0.005, 0), fingers(4, 0.5, 0), fingers(4, 0.6, 0)])
        let l = o.compactMap(\.locked).first
        expect(l?.fingers == 4 && close(l?.displacement ?? 0, 0.1, 0.005))
        // Different ids with the same count also restart.
        var r2 = GestureRecognizer(config: GestureConfig())
        let o2 = feed(&r2, [fingers(3, 0, 0), fingers(3, 0.5, 0, ids: [1, 2, 9])])
        expect(n(o2, \.locked) == 0)
        let o3 = feed(&r2, [fingers(3, 0.6, 0, ids: [1, 2, 9])], start: 1)
        expect(close(o3.compactMap(\.locked).first?.displacement ?? 0, 0.1, 0.005))
        // A finger joining after the lock does not change the locked finger count.
        var r3 = GestureRecognizer(config: GestureConfig())
        let o4 = feed(&r3, [fingers(3, 0, 0), fingers(3, 0.05, 0), fingers(4, 0.1, 0), []])
        expect(o4.compactMap(\.ended).first?.fingers == 3 && n(o4, \.locked) == 1)
    }

    func testAspectCorrection() {
        // Equal raw movement on both axes: diagonal on a square pad, no lock.
        var r = GestureRecognizer(config: GestureConfig())
        expect(n(feed(&r, [fingers(3, 0, 0), fingers(3, 0.03, 0.03)]), \.locked) == 0)
        // On a pad twice as wide, the same raw movement is horizontal.
        var wide = GestureRecognizer(config: GestureConfig())
        wide.aspect = (2, 1)
        expect(feed(&wide, [fingers(3, 0, 0), fingers(3, 0.03, 0.03)]).compactMap(\.locked).first?.axis == .horizontal)
        // Tall pad: vertical.
        var tall = GestureRecognizer(config: GestureConfig())
        tall.aspect = (1, 2)
        expect(feed(&tall, [fingers(3, 0, 0), fingers(3, 0.03, 0.03)]).compactMap(\.locked).first?.axis == .vertical)
        // Displacement itself stays in raw trackpad fractions.
        var wide2 = GestureRecognizer(config: GestureConfig())
        wide2.aspect = (2, 1)
        expect(close(feed(&wide2, [fingers(3, 0, 0), fingers(3, 0.03, 0.03)]).compactMap(\.locked).first?.displacement ?? 0, 0.03, 0.001))
    }

    func testVelocitySignsAndEdgeCases() {
        // Left swipe: negative velocity, direction left.
        var r = GestureRecognizer(config: GestureConfig())
        let o = feed(&r, [fingers(3, 0, 0), fingers(3, -0.03, 0), fingers(3, -0.06, 0), fingers(3, -0.09, 0), []])
        let e = o.compactMap(\.ended).first
        expect(e?.direction == .left && (e?.velocity ?? 0) < 0 && close(e?.velocity ?? 0, -3, 0.05))
        // Down swipe.
        var r2 = GestureRecognizer(config: GestureConfig())
        let o2 = feed(&r2, [fingers(3, 0, 0), fingers(3, 0, -0.03), fingers(3, 0, -0.06), []])
        expect(o2.compactMap(\.ended).first?.direction == .down && (o2.compactMap(\.ended).first?.velocity ?? 0) < 0)
        // Right swipe: positive.
        var r3 = GestureRecognizer(config: GestureConfig())
        let o3 = feed(&r3, [fingers(3, 0, 0), fingers(3, 0.03, 0), fingers(3, 0.06, 0), []])
        expect(o3.compactMap(\.ended).first?.direction == .right && (o3.compactMap(\.ended).first?.velocity ?? 0) > 0)
        // A single sample after lock: velocity 0.
        var r4 = GestureRecognizer(config: GestureConfig())
        let o4 = feed(&r4, [fingers(3, 0, 0), fingers(3, 0.1, 0), []])
        expect(o4.compactMap(\.ended).first?.velocity == 0)
        // Samples 2 ms apart (<= 4 ms span): velocity 0.
        var r5 = GestureRecognizer(config: GestureConfig())
        let o5 = feed(&r5, [fingers(3, 0, 0), fingers(3, 0.03, 0), fingers(3, 0.1, 0), []], step: 0.002)
        expect(o5.compactMap(\.ended).first?.velocity == 0)
        // Only the last ~80 ms count: a fast start followed by a slow tail reads slow.
        var r6 = GestureRecognizer(config: GestureConfig())
        let o6 = feed(&r6, [fingers(3, 0, 0), fingers(3, 0.02, 0), fingers(3, 0.3, 0), fingers(3, 0.301, 0), fingers(3, 0.302, 0), []], step: 0.1)
        expect(abs(o6.compactMap(\.ended).first?.velocity ?? 99) < 0.1)
    }

    func testResetSemantics() {
        var r = GestureRecognizer(config: GestureConfig())
        expect(r.reset().isEmpty)                                    // idle reset: nothing
        _ = feed(&r, [fingers(3, 0, 0), fingers(3, 0, 0.05)])
        expect(r.current?.axis == .vertical)
        let out = r.reset()
        expect(out.lifted && out.ended == nil && out.locked == nil)
        expect(r.current == nil)
        expect(r.reset().isEmpty)                                    // second reset: nothing
        // After reset a new gesture begins again and is fully recognised.
        let o = feed(&r, [fingers(3, 0, 0), fingers(3, 0.1, 0), []], start: 3)
        expect(o.filter(\.began).count == 1 && n(o, \.locked) == 1 && n(o, \.ended) == 1)
        // Reset after only fingers down (no lock): lifted too.
        var r2 = GestureRecognizer(config: GestureConfig())
        _ = feed(&r2, [fingers(3, 0, 0)])
        expect(r2.reset().lifted)
        // Reset clears cancellation: a palm gesture, reset, then 3 fingers work.
        var r3 = GestureRecognizer(config: GestureConfig())
        _ = feed(&r3, [fingers(5, 0, 0), fingers(5, 0, 0.2)])
        _ = r3.reset()
        expect(n(feed(&r3, [fingers(3, 0, 0), fingers(3, 0, 0.1)], start: 2), \.locked) == 1)
    }

    func testCurrentOnlyWhileLocked() {
        var r = GestureRecognizer(config: GestureConfig())
        expect(r.current == nil)
        _ = feed(&r, [fingers(3, 0, 0)])
        expect(r.current == nil)
        _ = feed(&r, [fingers(3, 0, 0.05)], start: 1)
        expect(r.current?.fingers == 3 && r.current?.direction == .up)
        _ = feed(&r, [fingers(3, 0, 0.09)], start: 2)
        expect(close(r.current?.displacement ?? 0, 0.09, 0.005))
        _ = feed(&r, [[]], start: 3)
        expect(r.current == nil)
    }

    func testSwipeSampleDirectionAndDistance() {
        var r = GestureRecognizer(config: GestureConfig())
        let e = feed(&r, [fingers(3, 0, 0), fingers(3, 0, -0.25), []]).compactMap(\.ended).first
        expect(e?.direction == .down && e?.distance == abs(e?.displacement ?? 0) && close(e?.distance ?? 0, 0.25, 0.001))
        expect(GestureAxis.horizontal.rawValue == 1 && GestureAxis.vertical.rawValue == 2)
        expect(SwipeDirection.left.rawValue == "left" && SwipeDirection.up.rawValue == "up")
        expect(GestureOutput().isEmpty)
        var o = GestureOutput(); o.lifted = true
        expect(!o.isEmpty)
    }

    func testMoreThanTenTouchesDoNotCrash() {
        var r = GestureRecognizer(config: GestureConfig())
        let big: Frame = (0..<12).map { (Int32($0), 0.1, 0.1) }
        let o = feed(&r, [big, big, []])
        expect(o.filter(\.began).count == 1 && o.filter(\.lifted).count == 1)
    }

    func testFourFingerHorizontalOnly() {
        var r = GestureRecognizer(config: GestureConfig())
        let o = feed(&r, [fingers(4, 0, 0), fingers(4, 0.05, 0.001), fingers(4, 0.12, 0.002), []])
        expect(o.compactMap(\.locked).first?.fingers == 4 && o.compactMap(\.crossed).first?.direction == .right)
        expect(o.compactMap(\.ended).first?.fingers == 4)
    }

    func testConfigDefaultsAndThreshold() {
        let c = GestureConfig()
        expect(c.enabled && c.trigger == .swipe)
        expect(c.threeFinger == 0.07 && c.fourFinger == 0.10 && c.ratio == 1.5)
        expect(c.clickGuard == 0.35 && c.lockDistance == 0.012 && c.overviewTravel == 0.18)
        expect(c.threshold(fingers: 3) == 0.07)
        expect(c.threshold(fingers: 4) == 0.10)
        expect(c.threshold(fingers: 5) == 0.10 && c.threshold(fingers: 2) == 0.10)
        expect(GestureConfig.Trigger.swipe.rawValue == "swipe" && GestureConfig.Trigger.lift.rawValue == "lift")
    }

    func testConfigDecoding() throws {
        let dec = JSONDecoder()
        let empty = try dec.decode(GestureConfig.self, from: Data("{}".utf8))
        expect(empty == GestureConfig())
        let p = try dec.decode(GestureConfig.self, from: Data(#"{"trigger":"lift","fourFinger":0.2,"enabled":false}"#.utf8))
        expect(p.trigger == .lift && p.fourFinger == 0.2 && !p.enabled)
        expect(p.threeFinger == 0.07 && p.ratio == 1.5 && p.lockDistance == 0.012 && p.overviewTravel == 0.18)
        let q = try dec.decode(GestureConfig.self, from: Data(#"{"lockDistance":0.03,"overviewTravel":0.3,"clickGuard":1,"ratio":3,"threeFinger":0.5}"#.utf8))
        expect(q.lockDistance == 0.03 && q.overviewTravel == 0.3 && q.clickGuard == 1 && q.ratio == 3 && q.threeFinger == 0.5)
        // Encode / decode round trip.
        var c = GestureConfig(); c.trigger = .lift; c.ratio = 2.5
        let back = try dec.decode(GestureConfig.self, from: try JSONEncoder().encode(c))
        expect(back == c)
    }

    func testHammerspoonImportValueTypes() {
        let dflt = GestureConfig()
        // Int values are accepted.
        let a = GestureConfig(hammerspoon: ["sw3": 1, "sw4": 2, "ratio": 3, "guard": 1])
        expect(a.threeFinger == 1 && a.fourFinger == 2 && a.ratio == 3 && a.clickGuard == 1)
        // Doubles too.
        let b = GestureConfig(hammerspoon: ["sw3": 0.05, "sw4": 0.15, "ratio": 1.75, "guard": 0.5, "trigger": "lift"])
        expect(b.threeFinger == 0.05 && b.fourFinger == 0.15 && b.ratio == 1.75 && b.clickGuard == 0.5 && b.trigger == .lift)
        // Strings are ignored (numbers only).
        let c = GestureConfig(hammerspoon: ["sw3": "0.5", "sw4": "x", "ratio": "2", "guard": "1"])
        expect(c.threeFinger == dflt.threeFinger && c.fourFinger == dflt.fourFinger)
        expect(c.ratio == dflt.ratio && c.clickGuard == dflt.clickGuard)
        // Empty dict and unknown trigger keep defaults.
        expect(GestureConfig(hammerspoon: [:]) == dflt)
        expect(GestureConfig(hammerspoon: ["trigger": "bogus"]).trigger == .swipe)
        expect(GestureConfig(hammerspoon: ["trigger": 5]).trigger == .swipe)
        // Keys Monarch owns are untouched by the import.
        let d = GestureConfig(hammerspoon: ["sw3": 0.2])
        expect(d.lockDistance == dflt.lockDistance && d.overviewTravel == dflt.overviewTravel && d.enabled)
    }

    func testInteractiveDecisionBoundaries() {
        expect(InteractiveDecision.complete(progress: 0.5, velocity: 0))
        expect(!InteractiveDecision.complete(progress: 0.4999, velocity: 0))
        expect(InteractiveDecision.complete(progress: 1, velocity: 0))
        expect(!InteractiveDecision.complete(progress: 0, velocity: 0))
        expect(InteractiveDecision.complete(progress: 0.1, velocity: 1.5001))
        expect(!InteractiveDecision.complete(progress: 0.1, velocity: 1.5))          // not a flick: progress decides
        expect(!InteractiveDecision.complete(progress: 0.9, velocity: -1.5001))
        expect(InteractiveDecision.complete(progress: 0.9, velocity: -1.5))
        expect(InteractiveDecision.complete(progress: 0.5, velocity: 1.4))
        expect(!InteractiveDecision.complete(progress: 0.49, velocity: 1.4))
        expect(InteractiveDecision.complete(progress: 0, velocity: 100))
        expect(!InteractiveDecision.complete(progress: 1, velocity: -100))
    }
}

// MARK: - Switcher

struct SwitcherRegressionTests {
    func all(_ id: UInt32) -> Bool { true }

    func testDedupAndFilters() {
        let o = SwitcherLogic.order(focused: 5, mru: [3, 5, 3, 4], zOrder: [4, 9, 9, 1], others: [1, 7, 7], include: all)
        expect(o == [5, 3, 4, 9, 1, 7])
        // Filter drops the focused window too, and others.
        let f = SwitcherLogic.order(focused: 5, mru: [3, 4], zOrder: [9], others: [7], include: { $0 != 5 && $0 != 7 })
        expect(f == [3, 4, 9])
        // No focused window.
        expect(SwitcherLogic.order(focused: nil, mru: [2, 1], zOrder: [1, 3], others: [], include: all) == [2, 1, 3])
        // Nothing at all.
        expect(SwitcherLogic.order(focused: nil, mru: [], zOrder: [], others: [], include: all).isEmpty)
        // Everything filtered out.
        expect(SwitcherLogic.order(focused: 1, mru: [2], zOrder: [3], others: [4], include: { _ in false }).isEmpty)
    }

    func testMaxItemsCap() {
        expect(SwitcherLogic.maxItems == 20)
        let mru = Array(UInt32(1)...UInt32(30))
        let o = SwitcherLogic.order(focused: nil, mru: mru, zOrder: [], others: [], include: all)
        expect(o.count == 20 && o.first == 1 && o.last == 20)
        let o2 = SwitcherLogic.order(focused: 99, mru: mru, zOrder: [], others: [], include: all)
        expect(o2.count == 20 && o2.first == 99 && o2.last == 19)
        // Cap also applies across the stages.
        let z = Array(UInt32(100)...UInt32(130))
        let o3 = SwitcherLogic.order(focused: nil, mru: [1, 2, 3], zOrder: z, others: [500], include: all)
        expect(o3.count == 20 && o3[3] == 100 && !o3.contains(500))
    }

    func testZOrderLazy() {
        nonisolated(unsafe) var calls = 0
        let z: () -> [UInt32] = { calls += 1; return [200, 201] }
        // focused + 19 mru fill the list: z not evaluated, others not consulted.
        let mru = Array(UInt32(1)...UInt32(19))
        let full = SwitcherLogic.order(focused: 99, mru: mru, zOrder: z, others: [300], include: all)
        expect(calls == 0 && full.count == 20 && !full.contains(300) && !full.contains(200))
        // 20 mru, no focused: also full.
        let full2 = SwitcherLogic.order(focused: nil, mru: Array(UInt32(1)...UInt32(20)), zOrder: z, others: [300], include: all)
        expect(calls == 0 && full2.count == 20)
        // 19 total: z is needed.
        let part = SwitcherLogic.order(focused: nil, mru: Array(UInt32(1)...UInt32(19)), zOrder: z, others: [300], include: all)
        expect(calls == 1 && part.count == 20 && part.last == 200 && !part.contains(300))
        // Not full: both evaluated, z first.
        let few = SwitcherLogic.order(focused: 1, mru: [2], zOrder: z, others: [300], include: all)
        expect(calls == 2 && few == [1, 2, 200, 201, 300])
        // Filtered mru leaves room, so z is called even with 25 mru entries.
        let filt = SwitcherLogic.order(focused: nil, mru: Array(UInt32(1)...UInt32(25)), zOrder: z, others: [], include: { ($0 > 10 && $0 < 15) || $0 >= 200 })
        expect(calls == 3 && filt == [11, 12, 13, 14, 200, 201])
    }

    func testInitialIndex() {
        // Focused first: needs at least two windows.
        expect(SwitcherLogic.initialIndex(count: 0, focusedFirst: true, step: 1) == nil)
        expect(SwitcherLogic.initialIndex(count: 1, focusedFirst: true, step: 1) == nil)
        expect(SwitcherLogic.initialIndex(count: 1, focusedFirst: true, step: -1) == nil)
        expect(SwitcherLogic.initialIndex(count: 2, focusedFirst: true, step: 1) == 1)
        expect(SwitcherLogic.initialIndex(count: 2, focusedFirst: true, step: -1) == 1)
        expect(SwitcherLogic.initialIndex(count: 5, focusedFirst: true, step: 1) == 1)
        expect(SwitcherLogic.initialIndex(count: 5, focusedFirst: true, step: -1) == 4)
        expect(SwitcherLogic.initialIndex(count: 5, focusedFirst: true, step: 0) == 1)
        // Not focused first: one window is enough.
        expect(SwitcherLogic.initialIndex(count: 0, focusedFirst: false, step: 1) == nil)
        expect(SwitcherLogic.initialIndex(count: 0, focusedFirst: false, step: -1) == nil)
        expect(SwitcherLogic.initialIndex(count: 1, focusedFirst: false, step: 1) == 0)
        expect(SwitcherLogic.initialIndex(count: 1, focusedFirst: false, step: -1) == 0)
        expect(SwitcherLogic.initialIndex(count: 3, focusedFirst: false, step: 1) == 0)
        expect(SwitcherLogic.initialIndex(count: 3, focusedFirst: false, step: -1) == 2)
        expect(SwitcherLogic.initialIndex(count: 3, focusedFirst: false, step: 0) == 0)
    }

    func testMoveWraps() {
        expect(SwitcherLogic.move(0, by: -1, count: 5) == 4)
        expect(SwitcherLogic.move(0, by: -7, count: 5) == 3)
        expect(SwitcherLogic.move(4, by: 1, count: 5) == 0)
        expect(SwitcherLogic.move(2, by: 0, count: 5) == 2)
        expect(SwitcherLogic.move(1, by: -5, count: 5) == 1)
        expect(SwitcherLogic.move(3, by: 12, count: 5) == 0)
        expect(SwitcherLogic.move(0, by: 1, count: 1) == 0)
        expect(SwitcherLogic.move(0, by: -1, count: 1) == 0)
        expect(SwitcherLogic.move(1, by: -1, count: 2) == 0)
    }
}

// MARK: - Workspaces

struct WorkspaceRegressionTests {
    func testSendAllActions() {
        for n in 1...9 {
            let a = Action(rawValue: "workspace.sendAll.\(n)")
            expect(a?.sendAllWorkspace == n && a?.switchWorkspace == nil && a?.moveWorkspace == nil && a?.isWorkspaceAction == true)
            expect(a?.defaultShortcut == "ctrl+alt+shift+\(n)")
        }
        expect(Action.workspace4.sendAllWorkspace == nil && Action.moveToWorkspace4.sendAllWorkspace == nil)
        expect(Action.restoreAllWindows.sendAllWorkspace == nil)
        expect(Shortcut(Action.sendAllToWorkspace3.defaultShortcut)?.description == "⌃⌥⇧ 3")
    }

    func testMakeRoomPushesOnlyTargetWorkspaceDown() {
        var s = WorkspaceState()
        s.hidden["1"] = ParkedWindow(ws: 2, scr: "A", x: 0, y: 0, w: 10, h: 10, z: 1)
        s.hidden["2"] = ParkedWindow(ws: 2, scr: "A", x: 0, y: 0, w: 10, h: 10, z: 2)
        s.hidden["3"] = ParkedWindow(ws: 3, scr: "A", x: 0, y: 0, w: 10, h: 10, z: 1)   // other workspace
        s.hidden["4"] = ParkedWindow(ws: 2, scr: "B", x: 0, y: 0, w: 10, h: 10, z: 1)   // other display
        s.makeRoom(3, onTopOf: 2, on: "A")
        expect(s.hidden["1"]?.z == 4 && s.hidden["2"]?.z == 5)
        expect(s.hidden["3"]?.z == 1 && s.hidden["4"]?.z == 1)
        // Sent windows get z 1…3: restored after the old ones, so they end up on top.
        s.hidden["5"] = ParkedWindow(ws: 2, scr: "A", x: 0, y: 0, w: 10, h: 10, z: 1)
        s.hidden["6"] = ParkedWindow(ws: 2, scr: "A", x: 0, y: 0, w: 10, h: 10, z: 2)
        expect(s.incoming(2, on: "A").map(\.id) == [2, 1, 6, 5])
    }

    func pw(_ ws: Int, _ scr: String = "A", z: Int = 1, px: Double? = nil, py: Double? = nil) -> ParkedWindow {
        ParkedWindow(ws: ws, scr: scr, x: 10, y: 20, w: 300, h: 200, z: z, px: px, py: py)
    }

    func testDefaultsAndLookups() {
        var s = WorkspaceState()
        expect(WorkspaceState.count == 9)
        expect(s.activeWorkspace("A") == 1 && s.activeWorkspace("") == 1)
        expect(s.active.isEmpty && s.hidden.isEmpty)
        s.active["A"] = 4
        expect(s.activeWorkspace("A") == 4 && s.activeWorkspace("B") == 1)
        s.hidden["12"] = pw(2)
        expect(s.isParked(12) && !s.isParked(13) && s.parked(12)?.ws == 2 && s.parked(13) == nil)
        expect(s.workspace(of: 12, displayUUID: "A").number == 2 && !s.workspace(of: 12, displayUUID: "A").shown)
        let w = s.workspace(of: 99, displayUUID: "A")
        expect(w.number == 4 && w.shown)
        expect(s.workspace(of: 99, displayUUID: "B").number == 1)
    }

    func testIncomingOrderAndFilters() {
        var s = WorkspaceState()
        s.hidden["1"] = pw(2, z: 1)
        s.hidden["2"] = pw(2, z: 3)
        s.hidden["3"] = pw(2, z: 2)
        s.hidden["4"] = pw(3, z: 1)
        s.hidden["5"] = pw(2, "B", z: 1)
        s.hidden["bad"] = pw(2, z: 9)
        // Bottom-most (highest z) first so the top window is restored last.
        expect(s.incoming(2, on: "A").map(\.id) == [2, 3, 1])
        expect(s.incoming(3, on: "A").map(\.id) == [4])
        expect(s.incoming(2, on: "B").map(\.id) == [5])
        expect(s.incoming(7, on: "A").isEmpty)
        expect(s.incoming(2, on: "nope").isEmpty)
    }

    func testUsedAndMenuTitle() {
        var s = WorkspaceState()
        expect(s.used(on: "A") == [1])
        expect(s.menuTitle(displayOrder: []) == "")
        expect(s.menuTitle(displayOrder: ["A"]) == "[1]")
        expect(s.menuTitle(displayOrder: ["A", "B"]) == "[1]  │  [1]")
        s.active["A"] = 5
        s.hidden["1"] = pw(2)
        s.hidden["2"] = pw(9)
        s.hidden["3"] = pw(5)             // parked window on the active workspace: no duplicate
        s.hidden["4"] = pw(7, "B")
        expect(s.used(on: "A") == [2, 5, 9])
        expect(s.used(on: "B") == [1, 7])
        expect(s.menuTitle(displayOrder: ["A"]) == "2 [5] 9")
        expect(s.menuTitle(displayOrder: ["A", "B"]) == "2 [5] 9  │  [1] 7")
        expect(s.menuTitle(displayOrder: ["B", "A"]) == "[1] 7  │  2 [5] 9")
        expect(s.menuTitle(displayOrder: ["unknown"]) == "[1]")
    }

    func testJSONRoundTripWithOptionalParkPoint() throws {
        var s = WorkspaceState()
        s.active = ["A": 3, "B": 1]
        s.hidden["7"] = pw(2, px: 100.5, py: 200)
        s.hidden["8"] = pw(4)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(WorkspaceState.self, from: data)
        expect(back == s)
        expect(back.hidden["7"]?.px == 100.5 && back.hidden["7"]?.py == 200)
        expect(back.hidden["8"]?.px == nil && back.hidden["8"]?.py == nil)
        // Stored JSON without px/py decodes as nil (state files from before the park point existed).
        let json = #"{"active":{},"hidden":{"1":{"ws":2,"scr":"A","x":1,"y":2,"w":3,"h":4,"z":5}}}"#
        let old = try JSONDecoder().decode(WorkspaceState.self, from: Data(json.utf8))
        expect(old.hidden["1"]?.px == nil && old.hidden["1"]?.z == 5 && old.hidden["1"]?.w == 3)
    }

    func testParkedWindowRelativeFrame() {
        expect(pw(1).relativeFrame == CGRect(x: 10, y: 20, width: 300, height: 200))
    }

    func testHammerspoonImportShape() {
        let plist: [String: Any] = [
            "active": ["U1": 3, "U2": 2.0],
            "hidden": [
                "10": ["ws": 2, "scr": "U1", "x": 5, "y": 6, "w": 700.5, "h": 500, "z": 4, "px": 100, "py": 200.5],
                "11": ["ws": 4, "scr": "U1"],
                "abc": ["ws": 2, "scr": "U1"],
                "12": ["scr": "U1"],
                "13": ["ws": 2],
                "14": "junk",
            ] as [String: Any],
        ]
        let s = WorkspaceState(hammerspoon: plist)
        expect(s.activeWorkspace("U1") == 3 && s.activeWorkspace("U2") == 2)
        expect(s.hidden.count == 2)
        let a = s.hidden["10"]
        expect(a?.ws == 2 && a?.scr == "U1" && a?.x == 5 && a?.w == 700.5 && a?.z == 4 && a?.px == 100 && a?.py == 200.5)
        // Missing geometry gets defaults.
        let b = s.hidden["11"]
        expect(b?.x == 0 && b?.y == 0 && b?.w == 800 && b?.h == 600 && b?.z == 0 && b?.px == nil && b?.py == nil)
        // Wrong shape / missing keys are skipped, empty plist is an empty state.
        expect(WorkspaceState(hammerspoon: [:]) == WorkspaceState())
        expect(WorkspaceState(hammerspoon: ["active": "bad", "hidden": 3]) == WorkspaceState())
    }

    func testParkingSpots() {
        let sf = CGRect(x: 560, y: 1440, width: 1440, height: 900)
        let spots = Parking.spots(for: CGSize(width: 700, height: 500), screen: sf)
        expect(spots.count == 4)
        expect(spots[0] == CGPoint(x: 1999, y: 2339))
        expect(spots[1] == CGPoint(x: -139, y: 2339))
        expect(spots[2] == CGPoint(x: 1999, y: 1480))
        expect(spots[3] == CGPoint(x: -139, y: 1480))
        // The first spot leaves exactly a 1x1 corner on screen.
        let f = CGRect(origin: spots[0], size: CGSize(width: 700, height: 500)).intersection(sf)
        expect(f.width == 1 && f.height == 1)
    }

    func testOverlapsOtherThresholds() {
        let displays = [lg, mac]
        // Parked bottom-right of the MacBook: sticks out into nothing.
        expect(!Parking.overlapsOther(CGRect(x: 1999, y: 2339, width: 700, height: 500), home: 2, displays: displays))
        // Overlap of exactly 2 pt each way does not count; 3 pt does.
        let two = CGRect(x: 2558, y: 1438, width: 700, height: 500)       // 2 pt into the LG's corner
        expect(!Parking.overlapsOther(two, home: 2, displays: displays))
        let three = CGRect(x: 2557, y: 1437, width: 700, height: 500)
        expect(Parking.overlapsOther(three, home: 2, displays: displays))
        // Thin in one direction only is not enough.
        expect(!Parking.overlapsOther(CGRect(x: 2558, y: 1000, width: 700, height: 2), home: 2, displays: displays))
        // The home display itself is ignored; touching edges don't count.
        expect(!Parking.overlapsOther(CGRect(x: 0, y: 0, width: 100, height: 100), home: 1, displays: displays))
        expect(!Parking.overlapsOther(CGRect(x: 0, y: 1440, width: 500, height: 500), home: 1, displays: [lg]))
        expect(Parking.overlapsOther(CGRect(x: 600, y: 1500, width: 100, height: 100), home: 1, displays: displays))
        expect(!Parking.overlapsOther(CGRect(x: 5, y: 5, width: 10, height: 10), home: 1, displays: []))
    }

    func testIsAtParkTolerance() {
        let e = pw(2, px: 100, py: 200)
        expect(Parking.isAtPark(CGRect(x: 100, y: 200, width: 50, height: 50), e))
        expect(Parking.isAtPark(CGRect(x: 105.9, y: 200, width: 50, height: 50), e))
        expect(!Parking.isAtPark(CGRect(x: 106, y: 200, width: 50, height: 50), e))
        expect(Parking.isAtPark(CGRect(x: 94.1, y: 200, width: 50, height: 50), e))
        expect(!Parking.isAtPark(CGRect(x: 94, y: 200, width: 50, height: 50), e))
        expect(Parking.isAtPark(CGRect(x: 100, y: 205.9, width: 50, height: 50), e))
        expect(!Parking.isAtPark(CGRect(x: 100, y: 206, width: 50, height: 50), e))
        expect(!Parking.isAtPark(CGRect(x: 100, y: 194, width: 50, height: 50), e))
        expect(Parking.isAtPark(CGRect(x: 100, y: 194.5, width: 999, height: 1), e))   // size is irrelevant
        // Park still in flight: nil in either coordinate means "still there".
        expect(Parking.isAtPark(CGRect(x: 5000, y: 5000, width: 1, height: 1), pw(2)))
        expect(Parking.isAtPark(CGRect(x: 5000, y: 5000, width: 1, height: 1), pw(2, px: 100)))
        expect(Parking.isAtPark(CGRect(x: 5000, y: 5000, width: 1, height: 1), pw(2, py: 200)))
    }

    func testFitClamps() {
        let size = CGSize(width: 1000, height: 800)
        expect(Parking.fit(CGRect(x: 10, y: 20, width: 300, height: 200), into: size) == CGRect(x: 10, y: 20, width: 300, height: 200))
        expect(Parking.fit(CGRect(x: -50, y: -5, width: 300, height: 200), into: size) == CGRect(x: 0, y: 0, width: 300, height: 200))
        expect(Parking.fit(CGRect(x: 900, y: 700, width: 300, height: 200), into: size) == CGRect(x: 700, y: 600, width: 300, height: 200))
        expect(Parking.fit(CGRect(x: 100, y: 100, width: 2000, height: 1600), into: size) == CGRect(x: 0, y: 0, width: 1000, height: 800))
        expect(Parking.fit(CGRect(x: 0, y: 0, width: 1000, height: 800), into: size) == CGRect(x: 0, y: 0, width: 1000, height: 800))
        expect(Parking.fit(CGRect(x: 0, y: 0, width: 1200, height: 100), into: size) == CGRect(x: 0, y: 0, width: 1000, height: 100))
    }
}

// MARK: - Overview

struct OverviewRegressionTests {
    func testCardsShapes() {
        let empty = OverviewModel.cards(active: 1, visible: [], parked: [])
        expect(empty.count == 2)
        expect(empty[0].workspace == 1 && !empty[0].isPlus && empty[0].isActive && empty[0].windows.isEmpty)
        expect(empty[1].workspace == 2 && empty[1].isPlus && !empty[1].isActive && empty[1].windows.isEmpty)
        // Active 3 with windows, parked on 1 and 5; plus card is the first free number (2), placed last.
        let c = OverviewModel.cards(active: 3, visible: [30, 31], parked: [(10, 1, 2), (11, 1, 1), (50, 5, 1)])
        expect(c.map(\.workspace) == [1, 3, 5, 2])
        expect(c.map(\.isPlus) == [false, false, false, true])
        expect(c.map(\.isActive) == [false, true, false, false])
        expect(c[0].windows == [11, 10])                   // by z, top-most first
        expect(c[1].windows == [30, 31])                   // visible order kept
        expect(c[2].windows == [50])
        expect(c[3].windows.isEmpty)
    }

    func testCardsEdgeCases() {
        // Parked windows claiming the active workspace are ignored.
        let c = OverviewModel.cards(active: 2, visible: [1], parked: [(9, 2, 1)])
        expect(c.first(where: { $0.isActive })?.windows == [1])
        // Nine used workspaces: no plus card.
        let parked = (1...9).filter { $0 != 4 }.map { (id: UInt32($0) * 10, ws: $0, z: 1) }
        let full = OverviewModel.cards(active: 4, visible: [], parked: parked)
        expect(full.count == 9 && !full.contains { $0.isPlus })
        expect(full.map(\.workspace) == Array(1...9))
        // Active workspace 9, nothing else: plus is workspace 1, placed after.
        let c9 = OverviewModel.cards(active: 9, visible: [], parked: [])
        expect(c9.map(\.workspace) == [9, 1] && c9[1].isPlus)
        // Plus card is the first empty number, not the max + 1.
        let gap = OverviewModel.cards(active: 1, visible: [1], parked: [(2, 2, 1), (3, 4, 1)])
        expect(gap.last?.workspace == 3 && gap.last?.isPlus == true)
        // Multiple windows on one parked workspace sort by z ascending.
        let z = OverviewModel.cards(active: 1, visible: [], parked: [(5, 2, 3), (6, 2, 1), (7, 2, 2)])
        expect(z.first(where: { $0.workspace == 2 })?.windows == [6, 7, 5])
    }

    func testLayoutColumnThreshold() {
        expect(OverviewModel.layout(cardCount: 5, size: CGSize(width: 1699, height: 1000)).cols == 3)
        expect(OverviewModel.layout(cardCount: 5, size: CGSize(width: 1700, height: 1000)).cols == 4)
        expect(OverviewModel.layout(cardCount: 5, size: CGSize(width: 2560, height: 1440)).cols == 4)
        // Never more columns than cards, never fewer than 1.
        expect(OverviewModel.layout(cardCount: 1, size: CGSize(width: 2560, height: 1440)).cols == 1)
        expect(OverviewModel.layout(cardCount: 2, size: CGSize(width: 2560, height: 1440)).cols == 2)
        expect(OverviewModel.layout(cardCount: 3, size: CGSize(width: 1000, height: 800)).cols == 3)
        let none = OverviewModel.layout(cardCount: 0, size: CGSize(width: 1000, height: 800))
        expect(none.cols == 1 && none.cardFrames.isEmpty)
    }

    func testLayoutFramesInsideAndCentred() {
        var ok = true
        func soft(_ c: @autoclosure () -> Bool, line: Int = #line) { if !c() { ok = false; print("  soft check failed at line \(line)") } }
        for (cnt, size) in [(1, CGSize(width: 2560, height: 1440)), (4, CGSize(width: 1440, height: 875)),
                            (7, CGSize(width: 1920, height: 1080)), (9, CGSize(width: 2560, height: 1440)),
                            (10, CGSize(width: 1440, height: 900))] {
            let l = OverviewModel.layout(cardCount: cnt, size: size)
            let area = CGRect(origin: .zero, size: size)
            soft(l.cardFrames.count == cnt)
            soft(l.cardFrames.allSatisfy { area.contains($0) })
            soft(l.cardFrames.allSatisfy { $0.height <= 460 })
            // Horizontal centring: space left of the first card equals space right of the widest row.
            let first = l.cardFrames[0]
            let rowMaxX = l.cardFrames.prefix(l.cols).map(\.maxX).max() ?? 0
            soft(close(Double(first.minX), Double(size.width - rowMaxX), 0.001))
            // No overlaps.
            for i in 0..<l.cardFrames.count {
                for j in (i + 1)..<max(l.cardFrames.count, i + 1) { soft(!l.cardFrames[i].intersects(l.cardFrames[j])) }
            }
        }
        // Exact numbers: one card on 2560x1440.
        let one = OverviewModel.layout(cardCount: 1, size: CGSize(width: 2560, height: 1440))
        soft(one.cardFrames[0] == CGRect(x: 44, y: 92, width: 2472, height: 460))
        soft(one.rowHeight == 40 && one.rowsTop == 56 && one.maxRows == 9)
        expect(ok)
    }

    func testLayoutGridPositionsAndRows() {
        let l = OverviewModel.layout(cardCount: 9, size: CGSize(width: 1920, height: 1080))
        expect(l.cols == 4)                                  // 1920 >= 1700
        let f = l.cardFrames
        expect(f[0].minY == 92 && f[1].minY == 92 && f[3].minY == 92 && f[4].minY > f[0].maxY)
        expect(close(Double(f[4].minY - f[0].maxY), 22) && close(Double(f[1].minX - f[0].maxX), 22))
        expect(f[0].minX == f[4].minX && f[0].minX == f[8].minX)
        expect(f.allSatisfy { $0.width == f[0].width && $0.height == f[0].height })
        let l3 = OverviewModel.layout(cardCount: 9, size: CGSize(width: 1440, height: 875))
        expect(l3.cols == 3 && l3.cardFrames[3].minX == l3.cardFrames[0].minX && l3.cardFrames[3].minY > l3.cardFrames[0].maxY)
        // Very short display: rows never go negative.
        let tiny = OverviewModel.layout(cardCount: 1, size: CGSize(width: 1000, height: 150))
        expect(tiny.maxRows == 0)
        // Smaller cards fit fewer rows.
        let small = OverviewModel.layout(cardCount: 1, size: CGSize(width: 1000, height: 300))
        expect(small.maxRows == Int((small.cardFrames[0].height - 64) / 40))
    }

    func testSelectionMoves() {
        typealias S = OverviewModel.Selection
        let cards = [3], rows = [[0, 2, 1]], cols = [3]
        func mv(_ s: S, _ dx: Int, _ dy: Int) -> S { OverviewModel.move(s, dx: dx, dy: dy, cards: cards, rows: rows, cols: cols) }
        expect(mv(S(screen: 0, card: 2, row: 0), 1, 0) == S(screen: 0, card: 2, row: 0))       // edge, one screen
        expect(mv(S(screen: 0, card: 0, row: 0), -1, 0) == S(screen: 0, card: 0, row: 0))
        expect(mv(S(screen: 0, card: 0, row: 0), 0, 0) == S(screen: 0, card: 0, row: 0))
        // Row is clamped to the new card's row count when moving sideways.
        expect(mv(S(screen: 0, card: 1, row: 2), 1, 0) == S(screen: 0, card: 2, row: 1))
        expect(mv(S(screen: 0, card: 1, row: 2), -1, 0) == S(screen: 0, card: 0, row: 0))
        // Vertical walk through the card's rows, then stop (no card below).
        expect(mv(S(screen: 0, card: 1, row: 0), 0, 1) == S(screen: 0, card: 1, row: 1))
        expect(mv(S(screen: 0, card: 1, row: 1), 0, 1) == S(screen: 0, card: 1, row: 2))
        expect(mv(S(screen: 0, card: 1, row: 2), 0, 1) == S(screen: 0, card: 1, row: 2))
        expect(mv(S(screen: 0, card: 1, row: 0), 0, -1) == S(screen: 0, card: 1, row: 0))
        expect(mv(S(screen: 0, card: 1, row: 2), 0, -1) == S(screen: 0, card: 1, row: 1))
        // Invalid selection is returned unchanged.
        expect(mv(S(screen: 3, card: 0, row: 0), 1, 0) == S(screen: 3, card: 0, row: 0))
        expect(mv(S(screen: 0, card: 7, row: 0), 0, 1) == S(screen: 0, card: 7, row: 0))
    }

    func testSelectionAcrossRowsAndScreens() {
        typealias S = OverviewModel.Selection
        // Screen 0: 5 cards in 2 columns; screen 1: 3 cards; screen 2: empty.
        let cards = [5, 3, 0], rows = [[1, 0, 2, 0, 1], [1, 1, 1], []], cols = [2, 3, 1]
        func mv(_ s: S, _ dx: Int, _ dy: Int) -> S { OverviewModel.move(s, dx: dx, dy: dy, cards: cards, rows: rows, cols: cols) }
        // Down from the last row goes to the card below, row 0.
        expect(mv(S(screen: 0, card: 0, row: 1), 0, 1) == S(screen: 0, card: 2, row: 0))
        // Up from row 0 goes to the card above, landing on its last row.
        expect(mv(S(screen: 0, card: 2, row: 0), 0, -1) == S(screen: 0, card: 0, row: 1))
        expect(mv(S(screen: 0, card: 4, row: 0), 0, -1) == S(screen: 0, card: 2, row: 2))
        // Card 3 has no card below (3 + 2 = 5 is out of range).
        expect(mv(S(screen: 0, card: 3, row: 0), 0, 1) == S(screen: 0, card: 3, row: 0))
        // Right off the last card goes to the next screen's first card.
        expect(mv(S(screen: 0, card: 4, row: 1), 1, 0) == S(screen: 1, card: 0, row: 1))
        // Left off the first card of screen 1 goes to the last card of screen 0 (row clamped).
        expect(mv(S(screen: 1, card: 0, row: 1), -1, 0) == S(screen: 0, card: 4, row: 1))
        expect(mv(S(screen: 1, card: 0, row: 0), -1, 0) == S(screen: 0, card: 4, row: 0))
        // Left off the first card of the first screen: stay.
        expect(mv(S(screen: 0, card: 0, row: 1), -1, 0) == S(screen: 0, card: 0, row: 1))
        // Next screen has no cards: stay put.
        expect(mv(S(screen: 1, card: 2, row: 0), 1, 0) == S(screen: 1, card: 2, row: 0))
        // Row clamping when jumping to a card with fewer rows.
        expect(mv(S(screen: 0, card: 2, row: 2), -1, 0) == S(screen: 0, card: 1, row: 0))
    }
}

// MARK: - Focus

struct FocusRegressionTests {
    func cand(_ id: UInt32, _ f: CGRect, min: Bool = false, hidden: Bool = false) -> FocusCandidate {
        FocusCandidate(id: id, pid: 1, frame: f, isMinimized: min, appHidden: hidden)
    }
    func at(_ cx: CGFloat, _ cy: CGFloat) -> CGRect { CGRect(x: cx - 5, y: cy - 5, width: 10, height: 10) }

    func testVisibleFraction() {
        let area = CGRect(x: 0, y: 0, width: 100, height: 100)
        expect(FocusLogic.visibleFraction(CGRect(x: 10, y: 10, width: 20, height: 20), on: area) == 1)
        expect(FocusLogic.visibleFraction(CGRect(x: 200, y: 200, width: 20, height: 20), on: area) == 0)
        expect(FocusLogic.visibleFraction(CGRect(x: 100, y: 0, width: 20, height: 20), on: area) == 0)    // touching
        expect(FocusLogic.visibleFraction(CGRect(x: 90, y: 0, width: 20, height: 20), on: area) == 0.5)
        expect(FocusLogic.visibleFraction(CGRect(x: 90, y: 90, width: 20, height: 20), on: area) == 0.25)
        expect(FocusLogic.visibleFraction(CGRect(x: -50, y: -50, width: 200, height: 200), on: area) == 0.25)
        expect(FocusLogic.visibleFraction(CGRect(x: 0, y: 0, width: 0, height: 20), on: area) == 0)
        expect(FocusLogic.visibleFraction(CGRect(x: 0, y: 0, width: 20, height: 0), on: area) == 0)
        expect(FocusLogic.visibleFraction(CGRect(x: 10, y: 10, width: 20, height: 20), on: CGRect(x: 0, y: 0, width: 0, height: 0)) == 0)
        expect(FocusLogic.minVisibleFraction == 0.3)
    }

    func testIsUsableAtMinVisibleBoundary() {
        // 30 of 100 pt visible on the LG's left edge: exactly the minimum, still usable.
        let edge = CGRect(x: -70, y: 500, width: 100, height: 100)
        expect(FocusLogic.isUsable(cand(1, edge), on: lg, in: [lg, mac]))
        expect(!FocusLogic.isUsable(cand(1, CGRect(x: -71, y: 500, width: 100, height: 100)), on: lg, in: [lg, mac]))
        // A window is only usable on the display that holds most of it.
        expect(!FocusLogic.isUsable(cand(1, edge), on: mac, in: [lg, mac]))
        // Minimized or hidden-app windows are never usable.
        expect(!FocusLogic.isUsable(cand(1, at(500, 500), min: true), on: lg, in: [lg, mac]))
        expect(!FocusLogic.isUsable(cand(1, at(500, 500), hidden: true), on: lg, in: [lg, mac]))
    }

    func testHistoryBehaviour() {
        var h = FocusHistory()
        expect(FocusHistory.mruLimit == 60 && h.mru.isEmpty && h.lastByDisplay.isEmpty)
        h.record(window: 1, display: 10)
        h.record(window: 2, display: 10)
        h.record(window: 3, display: 20)
        expect(h.mru == [3, 2, 1] && h.lastByDisplay == [10: 2, 20: 3])
        h.record(window: 1, display: 20)                       // re-recording moves to front, no duplicate
        expect(h.mru == [1, 3, 2] && h.lastByDisplay[20] == 1 && h.lastByDisplay[10] == 2)
        // Forget removes from mru and from every display that pointed at it.
        h.record(window: 1, display: 10)
        expect(h.lastByDisplay == [10: 1, 20: 1])
        h.forget(window: 1)
        expect(h.mru == [3, 2] && h.lastByDisplay.isEmpty)
        h.forget(window: 999)                                  // unknown: no-op
        expect(h.mru == [3, 2])
        h.record(window: 5, display: 10); h.record(window: 6, display: 20)
        h.keepDisplays([20])
        expect(h.lastByDisplay == [20: 6] && h.mru.contains(5))      // mru is not display-bound
        h.keepDisplays([])
        expect(h.lastByDisplay.isEmpty)
        // MRU is capped at 60, newest first.
        var big = FocusHistory()
        for i in 1...70 { big.record(window: UInt32(i), display: 1) }
        expect(big.mru.count == 60 && big.mru.first == 70 && big.mru.last == 11)
        big.record(window: 11, display: 1)                     // already inside: stays at 60
        expect(big.mru.count == 60 && big.mru.first == 11 && big.mru.last == 12)
    }

    func testWindowForScreenFallbacks() {
        let a = cand(1, at(500, 500)), b = cand(2, at(1500, 500)), m = cand(3, at(1000, 1900))
        let wins: [UInt32: FocusCandidate] = [1: a, 2: b, 3: m]
        var h = FocusHistory()
        // Focused window already usable on the display: nothing to do (and no z-order lookup).
        nonisolated(unsafe) var zCalls = 0
        let z: () -> [UInt32] = { zCalls += 1; return [2, 1] }
        expect(FocusLogic.windowForScreen(lg, displays: [lg, mac], focused: 1, windows: wins, history: h, zOrder: z) == nil)
        expect(zCalls == 0)
        // Last used on that display wins over the MRU.
        h.record(window: 1, display: 1)
        h.record(window: 2, display: 2)      // recorded against another display, ignored for the LG
        h.record(window: 3, display: 3)
        expect(FocusLogic.windowForScreen(lg, displays: [lg, mac], focused: 3, windows: wins, history: h, zOrder: z) == 1)
        expect(zCalls == 0)
        // Last used is gone: MRU supplies the next one on that display.
        var w2 = wins; w2[1] = cand(1, at(500, 500), min: true)
        expect(FocusLogic.windowForScreen(lg, displays: [lg, mac], focused: 3, windows: w2, history: h, zOrder: z) == 2)
        // Nothing in history: top-most in z-order.
        let fresh = FocusHistory()
        expect(FocusLogic.windowForScreen(lg, displays: [lg, mac], focused: 3, windows: wins, history: fresh, zOrder: z) == 2)
        expect(zCalls == 1)
        // z-order skips unusable windows.
        expect(FocusLogic.windowForScreen(mac, displays: [lg, mac], focused: 1, windows: wins, history: fresh, zOrder: { [1, 2, 3] }) == 3)
        // Nothing usable anywhere: nil. Focused id unknown to the window list counts as not usable.
        expect(FocusLogic.windowForScreen(mac, displays: [lg, mac], focused: 77, windows: [1: a], history: fresh, zOrder: { [1, 99] }) == nil)
        expect(FocusLogic.windowForScreen(lg, displays: [lg, mac], focused: nil, windows: [:], history: fresh, zOrder: { [] }) == nil)
        // Focused is minimized: not "already there".
        expect(FocusLogic.windowForScreen(lg, displays: [lg, mac], focused: 1, windows: [1: cand(1, at(500, 500), min: true), 2: b], history: fresh, zOrder: { [2] }) == 2)
    }

    func testDirectionalTiesAndCone() {
        let from = CGRect(x: 500, y: 500, width: 100, height: 100)         // centre (550, 550)
        // Tie: equal score above and below, the first listed wins.
        let up = cand(1, at(850, 450)), dn = cand(2, at(850, 650))
        expect(FocusLogic.window(in: .east, from: from, candidates: [up, dn]) == 1)
        expect(FocusLogic.window(in: .east, from: from, candidates: [dn, up]) == 2)
        // 45 degrees exactly is inside the cone; beyond is out.
        expect(FocusLogic.window(in: .east, from: from, candidates: [cand(3, at(850, 850))]) == 3)
        expect(FocusLogic.window(in: .east, from: from, candidates: [cand(3, at(850, 851))]) == nil)
        // Straight ahead far beats close but off to the side.
        expect(FocusLogic.window(in: .east, from: from, candidates: [cand(4, at(800, 700)), cand(5, at(900, 550))]) == 5)
        // Behind, itself, minimized, app-hidden are never picked.
        expect(FocusLogic.window(in: .east, from: from, candidates: [cand(6, at(300, 550)), cand(7, from)]) == nil)
        expect(FocusLogic.window(in: .east, from: from, candidates: [cand(8, at(850, 550), min: true), cand(9, at(900, 550), hidden: true)]) == nil)
        expect(FocusLogic.window(in: .east, from: from, candidates: []) == nil)
        // All four directions.
        let cs = [cand(10, at(250, 550)), cand(11, at(850, 550)), cand(12, at(550, 250)), cand(13, at(550, 850))]
        expect(FocusLogic.window(in: .west, from: from, candidates: cs) == 10)
        expect(FocusLogic.window(in: .east, from: from, candidates: cs) == 11)
        expect(FocusLogic.window(in: .north, from: from, candidates: cs) == 12)       // y grows downwards
        expect(FocusLogic.window(in: .south, from: from, candidates: cs) == 13)
        // Same direction: nearer wins.
        expect(FocusLogic.window(in: .west, from: from, candidates: [cand(14, at(100, 550)), cand(15, at(300, 550))]) == 15)
    }
}

// MARK: - Geometry

struct GeometryRegressionTests {
    func testRectRounding() {
        // 1/3 of 2560: 853.33 -> 853, right edge 1706.67 -> 1707, width 854.
        let a = Geometry.rect(for: UnitRect(1.0 / 3, 0, 1.0 / 3, 1), in: CGRect(x: 0, y: 25, width: 2560, height: 1415))
        expect(a == CGRect(x: 853, y: 25, width: 854, height: 1415))
        // .5 rounds up (away from zero).
        let h = Geometry.rect(for: UnitRect(0.5, 0, 0.5, 1), in: CGRect(x: 0, y: 0, width: 5, height: 5))
        expect(h == CGRect(x: 3, y: 0, width: 2, height: 5))
        // Negative origin (display to the left of primary).
        let n = Geometry.rect(for: UnitRect(0.5, 0, 0.5, 1), in: CGRect(x: -1440, y: 0, width: 1440, height: 900))
        expect(n == CGRect(x: -720, y: 0, width: 720, height: 900))
        // Full unit rect returns the area (already integral).
        expect(Geometry.rect(for: UnitRect(0, 0, 1, 1), in: lg.visibleFrame) == lg.visibleFrame)
        // Centre 70%: 0.15 / 0.7 of the LG visible frame.
        let c = Geometry.rect(for: UnitRect(0.15, 0.15, 0.7, 0.7), in: lg.visibleFrame)
        expect(c == CGRect(x: 384, y: 237, width: 1792, height: 991))
        // Zero-size rect.
        expect(Geometry.rect(for: UnitRect(0.5, 0.5, 0, 0), in: CGRect(x: 0, y: 0, width: 100, height: 100)) == CGRect(x: 50, y: 50, width: 0, height: 0))
    }

    func testCocoaToAXOnSecondaryDisplay() {
        // MacBook below the LG: Cocoa y is negative, AX y is beyond the primary height.
        let r = Geometry.cocoaToAX(CGRect(x: 560, y: -900, width: 1440, height: 900), primaryHeight: 1440)
        expect(r == CGRect(x: 560, y: 1440, width: 1440, height: 900))
        expect(Geometry.cocoaToAX(CGRect(x: 0, y: 0, width: 10, height: 20), primaryHeight: 100) == CGRect(x: 0, y: 80, width: 10, height: 20))
    }

    func testNeighborVariants() {
        let left = Display(id: 3, name: "L", isBuiltin: false, frame: CGRect(x: -1440, y: 0, width: 1440, height: 900),
                           visibleFrame: CGRect(x: -1440, y: 0, width: 1440, height: 900))
        let right = Display(id: 4, name: "R", isBuiltin: false, frame: CGRect(x: 2560, y: 0, width: 1920, height: 1080),
                            visibleFrame: CGRect(x: 2560, y: 0, width: 1920, height: 1080))
        let far = Display(id: 5, name: "F", isBuiltin: false, frame: CGRect(x: 5000, y: 0, width: 1000, height: 800),
                          visibleFrame: CGRect(x: 5000, y: 0, width: 1000, height: 800))
        expect(Geometry.neighbor(of: lg, .east, in: [lg, right])?.id == 4)
        expect(Geometry.neighbor(of: lg, .west, in: [lg, right])?.id == 4)             // nothing west: falls back to next
        expect(Geometry.neighbor(of: lg, .east, in: [lg, right, far])?.id == 4)         // nearest east
        expect(Geometry.neighbor(of: far, .west, in: [lg, right, far])?.id == 4)
        expect(Geometry.neighbor(of: lg, .west, in: [lg, left, mac])?.id == 3)
        // Next: by position left-to-right then top-to-bottom, wrapping.
        let all = [mac, lg, left]
        expect(Geometry.neighbor(of: left, .next, in: all)?.id == 1)
        expect(Geometry.neighbor(of: lg, .next, in: all)?.id == 2)
        expect(Geometry.neighbor(of: mac, .next, in: all)?.id == 3)
        // Stacked: next toggles.
        expect(Geometry.neighbor(of: lg, .next, in: [lg, mac])?.id == 2 && Geometry.neighbor(of: mac, .next, in: [lg, mac])?.id == 1)
        // Single display / not in the list.
        expect(Geometry.neighbor(of: lg, .west, in: [lg]) == nil && Geometry.neighbor(of: lg, .east, in: []) == nil)
        expect(Geometry.neighbor(of: lg, .next, in: [mac, left])?.id == 2)
    }

    func testMapAndClamp() {
        // Identity mapping keeps the frame.
        let r = CGRect(x: 100, y: 100, width: 800, height: 600)
        expect(Geometry.map(r, from: lg.visibleFrame, to: lg.visibleFrame) == r)
        // Zero-size source falls back to clamping.
        let z = Geometry.map(CGRect(x: 0, y: 0, width: 5000, height: 5000), from: .zero, to: mac.visibleFrame)
        expect(z == mac.visibleFrame)
        // Full frame maps to the full destination.
        expect(Geometry.map(lg.visibleFrame, from: lg.visibleFrame, to: mac.visibleFrame) == mac.visibleFrame)
        // Result is always inside the destination.
        let off = Geometry.map(CGRect(x: 2500, y: 1400, width: 400, height: 400), from: lg.visibleFrame, to: mac.visibleFrame)
        expect(mac.visibleFrame.contains(off))
        // Clamp: unchanged when inside; shifted from either side; origin-offset area.
        let area = CGRect(x: 100, y: 50, width: 400, height: 300)
        expect(Geometry.clamp(CGRect(x: 150, y: 80, width: 100, height: 100), into: area) == CGRect(x: 150, y: 80, width: 100, height: 100))
        expect(Geometry.clamp(CGRect(x: 0, y: 0, width: 100, height: 100), into: area) == CGRect(x: 100, y: 50, width: 100, height: 100))
        expect(Geometry.clamp(CGRect(x: 480, y: 340, width: 100, height: 100), into: area) == CGRect(x: 400, y: 250, width: 100, height: 100))
        expect(Geometry.clamp(CGRect(x: 0, y: 0, width: 900, height: 100), into: area) == CGRect(x: 100, y: 50, width: 400, height: 100))
        expect(Geometry.clamp(CGRect(x: 0, y: 0, width: 100, height: 900), into: area) == CGRect(x: 100, y: 50, width: 100, height: 300))
    }

    func testNearlyEqualAndSameSizeTolerance() {
        let a = CGRect(x: 100, y: 100, width: 500, height: 400)
        expect(Geometry.nearlyEqual(a, a))
        expect(Geometry.nearlyEqual(a, CGRect(x: 101, y: 100, width: 500, height: 400)))
        expect(!Geometry.nearlyEqual(a, CGRect(x: 101.01, y: 100, width: 500, height: 400)))
        expect(!Geometry.nearlyEqual(a, CGRect(x: 100, y: 98.9, width: 500, height: 400)))
        expect(Geometry.nearlyEqual(a, CGRect(x: 100, y: 100, width: 501, height: 399)))
        expect(!Geometry.nearlyEqual(a, CGRect(x: 100, y: 100, width: 502, height: 400)))
        expect(!Geometry.nearlyEqual(a, CGRect(x: 100, y: 100, width: 500, height: 402)))
        expect(Geometry.nearlyEqual(a, CGRect(x: 103, y: 100, width: 500, height: 400), tolerance: 3))
        expect(!Geometry.nearlyEqual(a, CGRect(x: 103.1, y: 100, width: 500, height: 400), tolerance: 3))
        expect(!Geometry.nearlyEqual(a, CGRect(x: 100.1, y: 100, width: 500, height: 400), tolerance: 0))
        expect(Geometry.sameSize(a, CGRect(x: 9, y: 9, width: 501, height: 399)))
        expect(!Geometry.sameSize(a, CGRect(x: 100, y: 100, width: 501.5, height: 400)))
        expect(!Geometry.sameSize(a, CGRect(x: 100, y: 100, width: 500, height: 398.9)))
        expect(Geometry.sameSize(a, CGRect(x: 100, y: 100, width: 505, height: 405), tolerance: 5))
    }

    func testDisplayForWindowEdgeCases() {
        expect(Geometry.display(for: CGRect(x: 0, y: 0, width: 10, height: 10), in: []) == nil)
        // Off every display: nearest by distance.
        expect(Geometry.display(for: CGRect(x: 3000, y: 100, width: 10, height: 10), in: [lg, mac])?.id == 1)
        expect(Geometry.display(for: CGRect(x: 700, y: 3000, width: 10, height: 10), in: [lg, mac])?.id == 2)
        expect(Geometry.display(for: CGRect(x: 300, y: 2000, width: 10, height: 10), in: [lg, mac])?.id == 2)
        // Only touching an edge: still no overlap, nearest wins.
        expect(Geometry.display(for: CGRect(x: 2560, y: 100, width: 50, height: 50), in: [lg, mac])?.id == 1)
        // Larger overlap wins; equal overlap keeps the earlier display in the list.
        let w = CGRect(x: 1000, y: 1400, width: 100, height: 80)           // 40 pt on LG, 40 on MacBook
        expect(Geometry.display(for: w, in: [lg, mac])?.id == 1)
        expect(Geometry.display(for: w, in: [mac, lg])?.id == 2)
        // Single display always returns it.
        expect(Geometry.display(for: CGRect(x: -9999, y: -9999, width: 1, height: 1), in: [lg])?.id == 1)
    }

    func testDisplayAndUnitRectInit() {
        expect(lg.uuid == "")
        let d = Display(id: 9, name: "X", isBuiltin: true, frame: .zero, visibleFrame: .zero, uuid: "U")
        expect(d.uuid == "U" && d.isBuiltin && d.name == "X")
        expect(UnitRect(0.1, 0.2, 0.3, 0.4) == UnitRect(0.1, 0.2, 0.3, 0.4))
        expect(UnitRect(0.1, 0.2, 0.3, 0.4).h == 0.4 && UnitRect(0.1, 0.2, 0.3, 0.4).x == 0.1)
    }
}

// MARK: - Shortcut

struct ShortcutRegressionTests {
    func testDescriptionSymbolsForSpecialKeys() {
        var ok = true
        func soft(_ c: @autoclosure () -> Bool, line: Int = #line) { if !c() { ok = false; print("  soft check failed at line \(line)") } }
        let pairs: [(String, String)] = [("left", "←"), ("right", "→"), ("up", "↑"), ("down", "↓"), ("return", "↩"),
                                         ("delete", "⌫"), ("space", "Space"), ("tab", "⇥"), ("escape", "⎋"),
                                         ("enter", "↩"), ("backspace", "⌫"), ("esc", "⎋")]
        for (k, sym) in pairs {
            soft(Shortcut("ctrl+" + k)?.description == "⌃ " + sym)
        }
        soft(Shortcut("a")?.description == " A")
        soft(Shortcut("cmd+`")?.description == "⌘ `")
        soft(Shortcut("alt+/")?.description == "⌥ /")
        soft(Shortcut("alt+5")?.description == "⌥ 5")
        soft(Shortcut("ctrl+f12")?.description == "⌃ F12")
        soft(Shortcut("ctrl+home")?.description == "⌃ HOME")
        expect(ok)
    }

    func testModifierOrderIsFixed() {
        expect(Shortcut("cmd+shift+alt+ctrl+a")?.description == "⌃⌥⇧⌘ A")
        expect(Shortcut("ctrl+alt+shift+cmd+a")?.description == "⌃⌥⇧⌘ A")
        expect(Shortcut("shift+cmd+a")?.description == "⇧⌘ A")
        expect(Shortcut("alt+ctrl+a")?.description == "⌃⌥ A")
        expect(Shortcut("cmd+tab")?.description == "⌘ ⇥")
        expect(Shortcut("ctrl+alt+shift+cmd+a")?.modifiers == Shortcut.control | Shortcut.option | Shortcut.shift | Shortcut.cmd)
        expect(Shortcut.cmd == 256 && Shortcut.shift == 512 && Shortcut.option == 2048 && Shortcut.control == 4096)
    }

    func testAliasesCaseAndWhitespace() {
        var ok = true
        func soft(_ c: @autoclosure () -> Bool, line: Int = #line) { if !c() { ok = false; print("  soft check failed at line \(line)") } }
        for text in ["cmd+a", "command+a", "⌘+a", "CMD+A", "Command+a", " cmd + a "] {
            soft(Shortcut(text)?.modifiers == Shortcut.cmd && Shortcut(text)?.keyCode == 0)
        }
        for text in ["alt+a", "opt+a", "option+a", "⌥+a", "ALT+a"] { soft(Shortcut(text)?.modifiers == Shortcut.option) }
        for text in ["ctrl+a", "control+a", "⌃+a", "Ctrl+A"] { soft(Shortcut(text)?.modifiers == Shortcut.control) }
        for text in ["shift+a", "⇧+a", "SHIFT+a"] { soft(Shortcut(text)?.modifiers == Shortcut.shift) }
        soft(Shortcut("CTRL+Alt+LEFT")?.keyCode == 123)
        soft(Shortcut("ctrl+a") == Shortcut("CONTROL+A"))
        soft(Shortcut("ctrl+a") != Shortcut("ctrl+b"))
        soft(Shortcut("ctrl+a") != Shortcut("alt+a"))
        soft(Set([Shortcut("ctrl+a")!, Shortcut("control+a")!]).count == 1)
        // Duplicate modifiers collapse.
        soft(Shortcut("ctrl+ctrl+a")?.modifiers == Shortcut.control)
        // No modifier is allowed.
        soft(Shortcut("f5")?.modifiers == 0 && Shortcut("f5")?.keyCode == 96)
        expect(ok)
    }

    func testKeyCodeAliasesAndSpotChecks() {
        var ok = true
        func soft(_ c: @autoclosure () -> Bool, line: Int = #line) { if !c() { ok = false; print("  soft check failed at line \(line)") } }
        soft(Shortcut("return")?.keyCode == 36 && Shortcut("enter")?.keyCode == 36)
        soft(Shortcut("escape")?.keyCode == 53 && Shortcut("esc")?.keyCode == 53)
        soft(Shortcut("delete")?.keyCode == 51 && Shortcut("backspace")?.keyCode == 51)
        soft(Shortcut("forwarddelete")?.keyCode == 117)
        let spots: [(String, UInt32)] = [("a", 0), ("s", 1), ("z", 6), ("p", 35), ("`", 50), ("/", 44), ("0", 29), ("1", 18),
                                         ("9", 25), ("tab", 48), ("space", 49), ("left", 123), ("right", 124), ("down", 125),
                                         ("up", 126), ("f1", 122), ("f12", 111), ("home", 115), ("end", 119),
                                         ("pageup", 116), ("pagedown", 121), ("=", 24), ("-", 27), (";", 41), (",", 43), (".", 47)]
        for (k, c) in spots { soft(Shortcut(k)?.keyCode == c) }
        expect(ok)
    }

    func testRejects() {
        expect(Shortcut("") == nil)
        expect(Shortcut("+") == nil)
        expect(Shortcut("ctrl") == nil)
        expect(Shortcut("ctrl+alt+cmd+shift") == nil)
        expect(Shortcut("ctrl+nosuchkey") == nil)
        expect(Shortcut("a+b") == nil)
        expect(Shortcut("ctrl+a+left") == nil)
        expect(Shortcut("f13") == nil)
        expect(Shortcut("meta+a") == nil)
        expect(Shortcut("super+a") == nil)
        expect(Shortcut("ctrl+ä") == nil)
    }
}

// MARK: - Actions and Configuration

struct ActionRegressionTests {
    func testRawValuesAreStable() {
        var ok = true
        func soft(_ c: @autoclosure () -> Bool, line: Int = #line) { if !c() { ok = false; print("  soft check failed at line \(line)") } }
        let spots: [(Action, String)] = [
            (.snapLeft, "snap.left"), (.snapRight, "snap.right"), (.snapTop, "snap.top"), (.snapBottom, "snap.bottom"),
            (.maximize, "snap.maximize"), (.center, "snap.center"), (.topLeft, "snap.topLeft"),
            (.leftTwoThirds, "snap.leftTwoThirds"), (.rightTwoThirds, "snap.rightTwoThirds"),
            (.moveScreenWest, "screen.moveWest"), (.moveScreenEast, "screen.moveEast"),
            (.moveScreenNextMaximize, "screen.moveNextMaximize"), (.fillToggle, "window.fillToggle"),
            (.toggleCrossScreenFocus, "focus.toggleCrossScreen"), (.toggleSameAppHover, "focus.toggleSameAppHover"),
            (.focusOtherScreen, "focus.otherScreen"), (.focusWest, "focus.west"), (.focusSouth, "focus.south"),
            (.arrangeAll, "arrange.all"), (.arrange1, "arrange.1"), (.arrange9, "arrange.9"),
            (.switcherNext, "switcher.next"), (.switcherPrevious, "switcher.previous"),
            (.switcherWorkspaceNext, "switcher.workspaceNext"), (.switcherWorkspacePrevious, "switcher.workspacePrevious"),
            (.workspace1, "workspace.1"), (.workspace9, "workspace.9"), (.moveToWorkspace1, "workspace.move.1"),
            (.moveToWorkspace9, "workspace.move.9"), (.restoreAllWindows, "workspace.restoreAll"),
            (.toggleOverview, "overview.toggle"), (.showHelp, "help.show"), (.reloadConfig, "config.reload"),
            (.gestureStatus, "gestures.status")]
        for (a, raw) in spots {
            soft(a.rawValue == raw && Action(rawValue: raw) == a)
        }
        let raws = Action.allCases.map(\.rawValue)
        soft(Set(raws).count == raws.count)
        soft(raws.allSatisfy { $0.contains(".") && !$0.contains(" ") })
        soft(Action(rawValue: "nope") == nil)
        expect(ok)
    }

    func testNumberedActionMappings() {
        var ok = true
        func soft(_ c: @autoclosure () -> Bool, line: Int = #line) { if !c() { ok = false; print("  soft check failed at line \(line)") } }
        for n in 1...9 {
            let s = Action(rawValue: "workspace.\(n)")
            let m = Action(rawValue: "workspace.move.\(n)")
            let a = Action(rawValue: "arrange.\(n)")
            soft(s?.switchWorkspace == n && s?.moveWorkspace == nil && s?.arrangeCount == nil)
            soft(m?.moveWorkspace == n && m?.switchWorkspace == nil && m?.arrangeCount == nil)
            soft(a?.arrangeCount == n && a?.switchWorkspace == nil && a?.moveWorkspace == nil)
            soft(s?.isWorkspaceAction == true && m?.isWorkspaceAction == true && a?.isWorkspaceAction == false)
            soft(s?.defaultShortcut == "alt+\(n)" && m?.defaultShortcut == "alt+shift+\(n)")
            soft(a?.defaultShortcut == "ctrl+alt+cmd+\(n)")
        }
        soft(Action.arrangeAll.arrangeCount == 0 && Action.arrangeAll.defaultShortcut == "ctrl+alt+cmd+0")
        soft(Action.restoreAllWindows.isWorkspaceAction)
        soft(Action.restoreAllWindows.switchWorkspace == nil && Action.restoreAllWindows.moveWorkspace == nil)
        soft(Action.restoreAllWindows.defaultShortcut == "ctrl+alt+shift+0")
        expect(ok)
    }

    func testPredicatesPartitionEveryCase() {
        var ok = true
        func soft(_ c: @autoclosure () -> Bool, line: Int = #line) { if !c() { ok = false; print("  soft check failed at line \(line)") } }
        var switchers = 0, workspaces = 0, focus = 0, arranges = 0
        for a in Action.allCases {
            let p = a.rawValue.split(separator: ".").first.map(String.init) ?? ""
            soft(a.isSwitcherAction == (p == "switcher"))
            soft(a.isWorkspaceAction == (p == "workspace"))
            soft(a.isFocusAction == (p == "focus"))
            soft((a.arrangeCount != nil) == (p == "arrange"))
            // switch / move numbers exist only for workspace actions and are in range.
            if let n = a.switchWorkspace { soft(a.isWorkspaceAction && (1...9).contains(n)) }
            if let n = a.moveWorkspace { soft(a.isWorkspaceAction && (1...9).contains(n)) }
            if let n = a.sendAllWorkspace { soft(a.isWorkspaceAction && (1...9).contains(n)) }
            soft([a.switchWorkspace, a.moveWorkspace, a.sendAllWorkspace].compactMap { $0 }.count <= 1)
            if let n = a.arrangeCount { soft((0...9).contains(n)) }
            soft([a.isSwitcherAction, a.isWorkspaceAction, a.isFocusAction].filter { $0 }.count <= 1)
            if a.isSwitcherAction { switchers += 1 }
            if a.isWorkspaceAction { workspaces += 1 }
            if a.isFocusAction { focus += 1 }
            if a.arrangeCount != nil { arranges += 1 }
        }
        soft(switchers == 4 && workspaces == 28 && focus == 7 && arranges == 10)
        expect(ok)
    }

    func testEveryDefaultParsesAndIsUniqueWithExpectedModifiers() {
        var ok = true
        func soft(_ c: @autoclosure () -> Bool, line: Int = #line) { if !c() { ok = false; print("  soft check failed at line \(line)") } }
        var seen = Set<Shortcut>()
        for a in Action.allCases {
            let s = Shortcut(a.defaultShortcut)
            soft(s != nil)
            if let s { soft(seen.insert(s).inserted) }
            soft(!a.defaultShortcut.isEmpty && a.defaultShortcut == a.defaultShortcut.lowercased())
        }
        soft(Shortcut(Action.switcherNext.defaultShortcut)?.description == "⌘ ⇥")
        soft(Shortcut(Action.switcherWorkspacePrevious.defaultShortcut)?.description == "⇧⌘ `")
        soft(Shortcut(Action.snapLeft.defaultShortcut)?.description == "⌃⌥ ←")
        soft(Shortcut(Action.toggleOverview.defaultShortcut)?.description == "⌃⌥ Space")
        soft(Shortcut(Action.showHelp.defaultShortcut)?.description == "⌃⌥ /")
        soft(Shortcut(Action.workspace3.defaultShortcut)?.description == "⌥ 3")
        soft(Shortcut(Action.moveToWorkspace3.defaultShortcut)?.description == "⌥⇧ 3")
        expect(ok)
    }

    func testSnapLayoutPlans() {
        var ok = true
        func soft(_ c: @autoclosure () -> Bool, line: Int = #line) { if !c() { ok = false; print("  soft check failed at line \(line)") } }
        let snap: [Action] = [.snapLeft, .snapRight, .snapTop, .snapBottom, .maximize, .center, .topLeft, .topRight,
                              .bottomLeft, .bottomRight, .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds]
        for a in Action.allCases {
            soft((SnapLayouts.plan(for: a) != nil) == snap.contains(a))
        }
        if case .cycle(let key, let rects)? = SnapLayouts.plan(for: .snapLeft) {
            soft(key == "left" && rects.count == 3 && rects[0] == UnitRect(0, 0, 0.5, 1))
        } else { soft(false) }
        if case .cycle(let key, let rects)? = SnapLayouts.plan(for: .snapRight) {
            soft(key == "right" && rects.count == 3 && rects[0] == UnitRect(0.5, 0, 0.5, 1))
        } else { soft(false) }
        soft(SnapLayouts.plan(for: .maximize) == .unit(UnitRect(0, 0, 1, 1)))
        soft(SnapLayouts.plan(for: .fillToggle) == nil)
        // Every rect lies within the unit square.
        for a in snap {
            var rects: [UnitRect] = []
            switch SnapLayouts.plan(for: a) {
            case .unit(let r)?: rects = [r]
            case .cycle(_, let rs)?: rects = rs
            case nil: break
            }
            for r in rects { soft(r.x >= 0 && r.y >= 0 && r.x + r.w <= 1.0000001 && r.y + r.h <= 1.0000001 && r.w > 0 && r.h > 0) }
        }
        expect(ok)
    }
}

struct ConfigRegressionTests {
    func decode(_ json: String) throws -> AppConfiguration { try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8)) }

    func testDefaultsAndEmptyFile() throws {
        var ok = true
        func soft(_ c: @autoclosure () -> Bool, line: Int = #line) { if !c() { ok = false; print("  soft check failed at line \(line)") } }
        let d = AppConfiguration()
        soft(d.version == 1 && d.snappingEnabled && d.axTimeout == 0.25 && d.crossScreenFocus && !d.sameAppHover && d.gestures == nil)
        soft(d.bindings.count == Action.allCases.count)
        soft(d.bindings == AppConfiguration.defaultBindings)
        for a in Action.allCases { soft(d.bindings[a.rawValue] == a.defaultShortcut) }
        let e = try decode("{}")
        soft(e == d)
        let r = d.resolvedBindings()
        soft(r.errors.isEmpty && r.bindings.count == Action.allCases.count)
        soft(r.bindings.map(\.0) == Action.allCases)                    // in declaration order
        expect(ok)
    }

    func testScalarsDecode() throws {
        let c = try decode(#"{"version":3,"snappingEnabled":false,"axTimeout":1.5,"crossScreenFocus":false,"sameAppHover":true}"#)
        expect(c.version == 3 && !c.snappingEnabled && c.axTimeout == 1.5 && !c.crossScreenFocus && c.sameAppHover)
        expect(c.bindings == AppConfiguration.defaultBindings)
    }

    func testEmptyStringDisablesAndMissingFallsBack() throws {
        let c = try decode(#"{"bindings":{"snap.left":"","snap.right":"ctrl+cmd+right"}}"#)
        let r = c.resolvedBindings()
        expect(r.errors.isEmpty)
        expect(!r.bindings.contains { $0.0 == .snapLeft })
        expect(r.bindings.first { $0.0 == .snapRight }?.1 == Shortcut("ctrl+cmd+right"))
        expect(r.bindings.count == Action.allCases.count - 1)
        // An action whose key was removed from the dictionary falls back to its default.
        var m = AppConfiguration()
        m.bindings.removeValue(forKey: "snap.left")
        let mr = m.resolvedBindings()
        expect(mr.errors.isEmpty && mr.bindings.first { $0.0 == .snapLeft }?.1 == Shortcut(Action.snapLeft.defaultShortcut))
        // Disabling everything yields no bindings and no errors.
        var none = AppConfiguration()
        for k in none.bindings.keys { none.bindings[k] = "" }
        expect(none.resolvedBindings().bindings.isEmpty && none.resolvedBindings().errors.isEmpty)
    }

    func testErrorReporting() throws {
        let c = try decode(#"{"bindings":{"snap.left":"ctrl+nokey","bogus.action":"ctrl+a","snap.top":"ctrl+a+b"}}"#)
        let r = c.resolvedBindings()
        expect(r.errors.contains(#"snap.left: "ctrl+nokey""#))
        expect(r.errors.contains(#"snap.top: "ctrl+a+b""#))
        expect(r.errors.contains(#"unknown action "bogus.action""#))
        expect(r.errors.count == 3)
        // Bad entries are skipped, the rest still resolve.
        expect(!r.bindings.contains { $0.0 == .snapLeft || $0.0 == .snapTop })
        expect(r.bindings.count == Action.allCases.count - 2)
    }

    func testGesturesDecoding() throws {
        let none = try decode("{}"); expect(none.gestures == nil)
        let empty = try decode(#"{"gestures":{}}"#)
        expect(empty.gestures == GestureConfig())
        let p = try decode(#"{"gestures":{"ratio":2,"trigger":"lift"}}"#)
        expect(p.gestures?.ratio == 2 && p.gestures?.trigger == .lift)
        expect(p.gestures?.threeFinger == 0.07 && p.gestures?.fourFinger == 0.10 && p.gestures?.enabled == true)
    }

    func testRoundTrip() throws {
        var c = AppConfiguration()
        c.bindings["snap.left"] = "ctrl+cmd+left"
        c.bindings["snap.center"] = ""
        c.sameAppHover = true
        c.axTimeout = 0.5
        var g = GestureConfig(); g.trigger = .lift; g.fourFinger = 0.2
        c.gestures = g
        let back = try JSONDecoder().decode(AppConfiguration.self, from: try JSONEncoder().encode(c))
        expect(back == c)
    }
}

// MARK: - Arrange / History / Perf

struct ArrangeRegressionTests {
    func testColumnCountsTable() {
        var ok = true
        func soft(_ c: @autoclosure () -> Bool, line: Int = #line) { if !c() { ok = false; print("  soft check failed at line \(line)") } }
        let table: [Int: [Int]] = [1: [1], 2: [1, 1], 3: [1, 2], 4: [2, 2], 5: [1, 2, 2], 6: [2, 2, 2],
                                   7: [2, 2, 3], 8: [2, 3, 3], 9: [3, 3, 3]]
        for (n, counts) in table { soft(ArrangeLayout.columnCounts(n) == counts) }
        soft(ArrangeLayout.columnCounts(0).isEmpty && ArrangeLayout.columnCounts(-3).isEmpty)
        for n in 1...30 {
            let c = ArrangeLayout.columnCounts(n)
            soft(c.reduce(0, +) == n && c == c.sorted() && c.max()! - c.min()! <= 1)
        }
        expect(ok)
    }

    func testFramesTileOddAreaWithoutGaps() {
        var ok = true
        func soft(_ c: @autoclosure () -> Bool, line: Int = #line) { if !c() { ok = false; print("  soft check failed at line \(line)") } }
        let area = CGRect(x: 7, y: 13, width: 1001, height: 777)
        for n in 1...12 {
            let f = ArrangeLayout.frames(count: n, in: area)
            soft(f.count == n)
            soft(f.allSatisfy { area.contains($0) && $0.width > 0 && $0.height > 0 })
            soft(f.reduce(0) { $0 + $1.width * $1.height } == area.width * area.height)
            for i in 0..<n {
                for j in (i + 1)..<max(n, i + 1) {
                    let x = f[i].intersection(f[j])
                    soft(x.isNull || x.width * x.height == 0)
                }
            }
            // The front-most window gets the biggest slot (to within rounding).
            let a0 = f[0].width * f[0].height
            soft(f.allSatisfy { $0.width * $0.height <= a0 + 1000 })
        }
        soft(ArrangeLayout.frames(count: 0, in: area).isEmpty)
        soft(ArrangeLayout.frames(count: -1, in: area).isEmpty)
        soft(ArrangeLayout.frames(count: 1, in: area) == [area])
        // 3 windows: big left, two stacked right.
        let t = ArrangeLayout.frames(count: 3, in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        soft(t[0] == CGRect(x: 0, y: 0, width: 500, height: 800))
        soft(t[1] == CGRect(x: 500, y: 0, width: 500, height: 400) && t[2] == CGRect(x: 500, y: 400, width: 500, height: 400))
        // 2 windows: halves in order, left first.
        let two = ArrangeLayout.frames(count: 2, in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        soft(two == [CGRect(x: 0, y: 0, width: 500, height: 800), CGRect(x: 500, y: 0, width: 500, height: 800)])
        expect(ok)
    }
}

struct HistoryRegressionTests {
    let f1 = CGRect(x: 0, y: 0, width: 100, height: 100)
    let f2 = CGRect(x: 50, y: 50, width: 200, height: 200)
    let f3 = CGRect(x: 9, y: 9, width: 9, height: 9)

    func testForgetResetsCycleForReusedID() {
        let h = WindowHistory()
        expect(h.nextCycleIndex(key: "left", window: 1, count: 3, now: 0) == 0)
        expect(h.nextCycleIndex(key: "left", window: 1, count: 3, now: 0.5) == 1)
        h.forget(1)                                   // closed; a new window reuses ID 1
        expect(h.nextCycleIndex(key: "left", window: 1, count: 3, now: 0.8) == 0)
        // Forgetting another window leaves the cycle alone.
        expect(h.nextCycleIndex(key: "left", window: 1, count: 3, now: 1.0) == 1)
        h.forget(2)
        expect(h.nextCycleIndex(key: "left", window: 1, count: 3, now: 1.2) == 2)
    }

    func testCycleResetRules() {
        expect(WindowHistory.cycleWindow == 1.5)
        let h = WindowHistory()
        expect(h.nextCycleIndex(key: "left", window: 1, count: 3, now: 0) == 0)
        // Exactly cycleWindow later: too late, restarts.
        expect(h.nextCycleIndex(key: "left", window: 1, count: 3, now: 1.5) == 0)
        // 1.49 s after the previous press: advances. The window is measured from the last press.
        let g = WindowHistory()
        expect(g.nextCycleIndex(key: "left", window: 1, count: 3, now: 0) == 0)
        expect(g.nextCycleIndex(key: "left", window: 1, count: 3, now: 1.49) == 1)
        expect(g.nextCycleIndex(key: "left", window: 1, count: 3, now: 2.9) == 2)
        // Another window with the same key restarts at 0.
        let k = WindowHistory()
        expect(k.nextCycleIndex(key: "left", window: 1, count: 3, now: 0) == 0)
        expect(k.nextCycleIndex(key: "left", window: 2, count: 3, now: 0.1) == 0)
        // After switching windows, going back to window 1 restarts too.
        expect(k.nextCycleIndex(key: "left", window: 1, count: 3, now: 0.2) == 0)
        // A different key in between breaks the chain.
        let m = WindowHistory()
        _ = m.nextCycleIndex(key: "left", window: 1, count: 3, now: 0)
        _ = m.nextCycleIndex(key: "right", window: 1, count: 3, now: 0.1)
        expect(m.nextCycleIndex(key: "left", window: 1, count: 3, now: 0.2) == 0)
        // Wrap with count 2 and count 1.
        let w = WindowHistory()
        expect(w.nextCycleIndex(key: "a", window: 1, count: 2, now: 0) == 0)
        expect(w.nextCycleIndex(key: "a", window: 1, count: 2, now: 0.1) == 1)
        expect(w.nextCycleIndex(key: "a", window: 1, count: 2, now: 0.2) == 0)
        let one = WindowHistory()
        _ = one.nextCycleIndex(key: "a", window: 1, count: 1, now: 0)
        expect(one.nextCycleIndex(key: "a", window: 1, count: 1, now: 0.1) == 0)
    }

    func testFillSaveTakePeek() {
        let h = WindowHistory()
        expect(h.peekBeforeFill(1) == nil && h.takeBeforeFill(1) == nil)
        h.saveBeforeFill(1, f1)
        h.saveBeforeFill(1, f2)                                 // overwrite
        expect(h.peekBeforeFill(1) == f2 && h.peekBeforeFill(1) == f2)   // peek does not consume
        h.saveBeforeFill(2, f3)
        expect(h.takeBeforeFill(1) == f2 && h.takeBeforeFill(1) == nil && h.peekBeforeFill(2) == f3)
        expect(h.takeBeforeFill(2) == f3 && h.takeBeforeFill(2) == nil)
    }

    func testForgetClearsWindowOnly() {
        let h = WindowHistory()
        h.saveBeforeFill(1, f2)
        h.saveBeforeFill(2, f3)
        h.forget(1)
        expect(h.peekBeforeFill(1) == nil && h.takeBeforeFill(1) == nil)
        expect(h.peekBeforeFill(2) == f3)
        h.forget(99)                                            // unknown: no-op
        expect(h.peekBeforeFill(2) == f3)
    }
}

struct PerfRegressionTests {
    func testUnknownAndEmpty() {
        let p = PerfStats()
        expect(PerfStats.capacity == 256)
        expect(p.summary("nothing") == nil && p.metrics.isEmpty)
        p.record("a", ms: 1)
        expect(p.summary("b") == nil && p.metrics == ["a"])
    }

    func testSinglePercentilesAndMetricsSorted() {
        let p = PerfStats()
        p.record("z", ms: 4); p.record("a", ms: 1); p.record("m", ms: 2)
        expect(p.metrics == ["a", "m", "z"])
        let sz = p.summary("z"); expect(sz?.count == 1 && sz?.last == 4 && sz?.median == 4 && sz?.p95 == 4 && sz?.max == 4)
    }

    func testKnownPercentiles() {
        let p = PerfStats()
        for v in stride(from: 100, through: 1, by: -1) { p.record("x", ms: Double(v)) }      // 100...1
        let s = p.summary("x")
        expect(s?.count == 100 && s?.last == 1 && s?.max == 100)
        expect(s?.median == 51)            // index round(99 * 0.5) = 50
        expect(s?.p95 == 95)               // index round(94.05) = 94
        let two = PerfStats()
        two.record("t", ms: 20); two.record("t", ms: 10)
        expect(two.summary("t")?.median == 20 && two.summary("t")?.p95 == 20 && two.summary("t")?.last == 10)
        let three = PerfStats()
        for v in [3.0, 1.0, 2.0] { three.record("t", ms: v) }
        expect(three.summary("t")?.median == 2 && three.summary("t")?.max == 3)
    }

    func testRingWrapAtCapacity() {
        let p = PerfStats()
        for v in 1...256 { p.record("r", ms: Double(v)) }
        expect(p.summary("r")?.count == 256 && p.summary("r")?.max == 256)
        p.record("r", ms: 1000)                                     // overwrites value 1
        let s = p.summary("r")
        expect(s?.count == 256 && s?.max == 1000 && s?.last == 1000)
        let q = PerfStats()
        for v in 1...300 { q.record("r", ms: Double(v)) }          // holds 45...300
        let t = q.summary("r")
        expect(t?.count == 256 && t?.max == 300 && t?.last == 300)
        expect(t?.median == 173 && t?.p95 == 287)
        // Metrics are independent rings.
        q.record("other", ms: 5)
        expect(q.summary("other")?.count == 1 && q.summary("r")?.count == 256)
    }
}

// MARK: - Help

struct HelpRegressionTests {
    func defaults() -> [Action: Shortcut] {
        Dictionary(uniqueKeysWithValues: AppConfiguration().resolvedBindings().bindings)
    }
    let st = HelpSheet.States(cross: true, hover: false)

    func testDefaultSectionTitlesAndFamilies() {
        let s = HelpSheet.sections(bindings: defaults(), states: st, gestures: true)
        expect(s.map(\.title) == ["Auto focus (mouse)", "Snap", "Two screens", "Workspaces (per screen)",
                                  "Switch (raises only one window)", "Helpers"])
        let ws = s.first { $0.title.hasPrefix("Workspaces") }!
        expect(ws.rows.contains(HelpSheet.Row(keys: "⌥ 1…9", text: "Show workspace N on screen under mouse")))
        expect(ws.rows.contains(HelpSheet.Row(keys: "⌥⇧ 1…9", text: "Send focused window to workspace N")))
        expect(ws.rows.contains(HelpSheet.Row(keys: "⌃⌥⇧ 1…9", text: "Send all windows on screen to workspace N")))
        expect(ws.rows.contains { $0.keys == "4 fingers" } && ws.rows.contains { $0.keys == "3 fingers" })
        expect(ws.rows.contains { $0.text == "Overview (also 3-finger swipe ↑)" && $0.keys == "⌃⌥ Space" })
        let snap = s.first { $0.title == "Snap" }!
        expect(snap.rows.last == HelpSheet.Row(keys: "⌃⌥⌘ 1…9", text: "Tile top N windows (0 = all)"))
        expect(snap.rows.first == HelpSheet.Row(keys: "⌃⌥ ←", text: "Left ½ → ⅓ → ⅔ (repeat)"))
        expect(snap.rows.count == 16)
        expect(s.last?.rows.map(\.keys) == ["⌃⌥ /", "⌃⌥⇧ R", "⌃⌥⇧ G"])
    }

    func testOnOffAndGestureFlag() {
        let on = HelpSheet.sections(bindings: defaults(), states: HelpSheet.States(cross: true, hover: false), gestures: false)
        let focus = on.first { $0.title.hasPrefix("Auto focus") }!
        expect(focus.rows[0].text == "Cross-screen focus on/off  [ON]")
        expect(focus.rows[1].text == "Same-app hover focus on/off  [OFF]")
        let flip = HelpSheet.sections(bindings: defaults(), states: HelpSheet.States(cross: false, hover: true), gestures: false)
        let f2 = flip.first { $0.title.hasPrefix("Auto focus") }!
        expect(f2.rows[0].text.hasSuffix("[OFF]") && f2.rows[1].text.hasSuffix("[ON]"))
        // Without gestures, no finger rows and the overview row has no suffix.
        let ws = on.first { $0.title.hasPrefix("Workspaces") }!
        expect(!ws.rows.contains { $0.keys.contains("fingers") })
        expect(ws.rows.contains { $0.text == "Overview" })
    }

    func testRebindDisableAndFamilyBreaks() {
        var b = defaults()
        b[.snapLeft] = Shortcut("ctrl+cmd+left")
        b.removeValue(forKey: .snapRight)
        var s = HelpSheet.sections(bindings: b, states: st, gestures: false)
        let snap = s.first { $0.title == "Snap" }!
        expect(snap.rows.first == HelpSheet.Row(keys: "⌃⌘ ←", text: "Left ½ → ⅓ → ⅔ (repeat)"))
        expect(!snap.rows.contains { $0.text.hasPrefix("Right ½") })
        // Rebinding the whole family to a new modifier shows it; a broken family disappears.
        for n in 1...9 { b[Action(rawValue: "workspace.\(n)")!] = Shortcut("ctrl+\(n)") }
        s = HelpSheet.sections(bindings: b, states: st, gestures: false)
        expect(s.first { $0.title.hasPrefix("Workspaces") }!.rows.contains { $0.keys == "⌃ 1…9" })
        b[.workspace9] = Shortcut("alt+9")
        s = HelpSheet.sections(bindings: b, states: st, gestures: false)
        expect(!s.first { $0.title.hasPrefix("Workspaces") }!.rows.contains { $0.text.hasPrefix("Show workspace") })
        b.removeValue(forKey: .workspace1)
        s = HelpSheet.sections(bindings: b, states: st, gestures: false)
        expect(!s.first { $0.title.hasPrefix("Workspaces") }!.rows.contains { $0.text.hasPrefix("Show workspace") })
        // The tile row follows arrangeAll and vanishes when it is unbound.
        b[.arrangeAll] = Shortcut("ctrl+cmd+0")
        expect(HelpSheet.sections(bindings: b, states: st, gestures: false).first { $0.title == "Snap" }!.rows.last?.keys == "⌃⌘ 1…9")
        b.removeValue(forKey: .arrangeAll)
        expect(!HelpSheet.sections(bindings: b, states: st, gestures: false).first { $0.title == "Snap" }!.rows.contains { $0.text.hasPrefix("Tile") })
    }

    func testEmptyBindingsDropSections() {
        expect(HelpSheet.sections(bindings: [:], states: st, gestures: false).isEmpty)
        let g = HelpSheet.sections(bindings: [:], states: st, gestures: true)
        expect(g.count == 1 && g[0].title.hasPrefix("Workspaces") && g[0].rows.count == 2)
        // Only help bound: only the Helpers section.
        let h = HelpSheet.sections(bindings: [.showHelp: Shortcut("ctrl+alt+/")!], states: st, gestures: false)
        expect(h.map(\.title) == ["Helpers"] && h[0].rows == [HelpSheet.Row(keys: "⌃⌥ /", text: "This sheet")])
    }

    func testColumnsBalance() {
        func sec(_ n: Int) -> HelpSheet.Section {
            HelpSheet.Section(title: "t\(n)", rows: (0..<n).map { HelpSheet.Row(keys: "k\($0)", text: "x") })
        }
        expect(HelpSheet.columns([]).left.isEmpty && HelpSheet.columns([]).right.isEmpty)
        let one = HelpSheet.columns([sec(3)])
        expect(one.left.count == 1 && one.right.isEmpty)
        let two = HelpSheet.columns([sec(3), sec(9)])
        expect(two.left.count == 1 && two.right.count == 1)
        let eq = HelpSheet.columns([sec(1), sec(1), sec(1)])
        expect(eq.left.count == 1 && eq.right.count == 2)          // ties keep the earlier split
        let big = HelpSheet.columns([sec(10), sec(1), sec(1)])
        expect(big.left.count == 1 && big.right.count == 2)
        // Order is preserved and nothing is lost; the split minimises the taller column.
        for sets in [[2, 5, 3, 8, 1], [4, 4, 4, 4], [1, 9, 1, 9], [6, 2, 2, 2, 2, 6]] {
            let secs = sets.map(sec)
            let c = HelpSheet.columns(secs)
            expect((c.left + c.right).map(\.title) == secs.map(\.title))
            expect(!c.left.isEmpty && !c.right.isEmpty)
            func h(_ x: [HelpSheet.Section]) -> Int { x.reduce(0) { $0 + $1.rows.count + 2 } }
            let total = h(secs)
            var best = Int.max, run = 0
            for k in 0..<secs.count - 1 { run += secs[k].rows.count + 2; best = min(best, max(run, total - run)) }
            expect(max(h(c.left), h(c.right)) == best)
        }
        // The real sheet splits into two non-empty columns.
        let real = HelpSheet.sections(bindings: defaults(), states: st, gestures: true)
        let rc = HelpSheet.columns(real)
        expect(!rc.left.isEmpty && !rc.right.isEmpty && rc.left.count + rc.right.count == real.count)
    }
}

// MARK: - Config validation (⌃⌥⇧ R applies a file only if it's valid)

struct ConfigValidationTests {
    func testDefaultsAreValid() {
        expect(AppConfiguration().validate().isEmpty)
        var c = AppConfiguration(); c.gestures = GestureConfig()
        expect(c.validate().isEmpty)
    }

    func testBadShortcutUnknownActionAndDuplicates() {
        var c = AppConfiguration()
        c.bindings["snap.left"] = "ctrl+alt+nonsense"
        c.bindings["snap.undo"] = "ctrl+alt+delete"                  // removed action
        c.bindings["snap.center"] = "ctrl+alt+right"                 // same as snap.right
        let p = c.validate()
        expect(p.contains { $0.hasPrefix("snap.left:") })
        expect(p.contains("unknown action \"snap.undo\""))
        expect(p.contains { $0.contains("snap.center and snap.right") })
        expect(p.count == 3)
    }

    func testEmptyBindingDisablesWithoutError() {
        var c = AppConfiguration()
        c.bindings["snap.center"] = ""
        expect(c.validate().isEmpty)
    }

    func testRanges() {
        var c = AppConfiguration()
        c.axTimeout = 0
        var g = GestureConfig(); g.ratio = 0.5; g.threeFinger = 2
        c.gestures = g
        let p = c.validate()
        expect(p.contains { $0.hasPrefix("axTimeout") })
        expect(p.contains { $0.hasPrefix("gestures.ratio") } && p.contains { $0.hasPrefix("gestures.threeFinger") })
        expect(p.count == 3)
    }

    func testDecodedFileWithMistakes() throws {
        let json = #"{"bindings": {"workspace.1": "alt+1", "workspace.2": "alt+1", "bogus": "alt+x"}}"#
        let c = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        let p = c.validate()
        expect(p.contains("unknown action \"bogus\"") && p.contains { $0.contains("workspace.1 and workspace.2") })
    }
}
