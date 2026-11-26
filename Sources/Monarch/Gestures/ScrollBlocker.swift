import CoreGraphics
import Foundation
import MonarchCore
import Synchronization

/// Suppresses trackpad scrolling while a three- or four-finger swipe is under way (rules in
/// `ScrollGuard`). The touch callback reports frames; an event tap for scroll events only,
/// on its own thread (so a busy main thread never delays scrolling), asks the guard.
///
/// The tap is created while gestures run on a trackpad with `blockScroll` on, but it's
/// switched off except around swipes: the touch thread switches it on when a swipe locks,
/// and the tap thread switches it off again once the guard is idle. Outside swipes, scroll
/// events don't pass through Monarch at all.
enum ScrollBlocker {
    private static let state = Mutex(ScrollGuard())
    /// Touch frames are reported only while the tap exists.
    private static let installed = Atomic<Bool>(false)

    /// CF objects aren't Sendable; the port is only used through this box, under the lock.
    private struct Port: @unchecked Sendable { let port: CFMachPort; let loop: CFRunLoop? }
    private static let port = Mutex<Port?>(nil)

    /// True while the tap exists (creating it can fail without Accessibility).
    static var isInstalled: Bool { installed.load(ordering: .relaxed) }

    /// Seconds on one clock for both threads.
    static func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

    /// From the touch callback, every frame of trackpad `device`. Never allocates.
    static func frame(device: Int, locked: Bool) {
        guard installed.load(ordering: .relaxed) else { return }
        let t = now()
        let start = state.withLock { $0.frame(device: device, locked: locked, now: t) }
        if start { setTap(true) }                                // once per swipe
    }

    private static func setTap(_ on: Bool) {
        port.withLock { p in if let p { CGEvent.tapEnable(tap: p.port, enable: on) } }
    }

    /// Creates or removes the tap (main thread).
    static func setEnabled(_ on: Bool) {
        guard on != installed.load(ordering: .relaxed) else { return }
        if on { install() } else { uninstall() }
    }

    private static func install() {
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback, userInfo: nil) else {
            Log.error(.gestures, "scroll guard: couldn't create the scroll event tap (Accessibility?)")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { CFMachPortInvalidate(tap); return }
        CGEvent.tapEnable(tap: tap, enable: false)               // off until a swipe locks
        state.withLock { $0.clear() }
        struct Handoff: @unchecked Sendable { let tap: CFMachPort; let source: CFRunLoopSource }
        let h = Handoff(tap: tap, source: source)
        let ready = DispatchSemaphore(value: 0)
        let t = Thread {
            port.withLock { $0 = Port(port: h.tap, loop: CFRunLoopGetCurrent()) }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), h.source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "Monarch scroll guard"
        t.qualityOfService = .userInteractive
        t.start()
        ready.wait()
        installed.store(true, ordering: .relaxed)
        Log.info(.gestures, "scroll guard ready")
    }

    private static func uninstall() {
        installed.store(false, ordering: .relaxed)
        let p = port.withLock { p -> Port? in defer { p = nil }; return p }
        if let p {
            CGEvent.tapEnable(tap: p.port, enable: false)
            CFMachPortInvalidate(p.port)
            if let loop = p.loop { CFRunLoopStop(loop) }
        }
        state.withLock { $0.clear() }
    }

    private static let deltaFields: [CGEventField] = [
        .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
        .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
        .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
    ]

    private static let callback: CGEventTapCallBack = { _, type, event, _ in
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-enabled only if a swipe still needs it.
            let busy = !ScrollBlocker.state.withLock { $0.isIdle(now: ScrollBlocker.now()) }
            if busy { ScrollBlocker.setTap(true) }
            return Unmanaged.passUnretained(event)
        case .scrollWheel:
            let phase = Int(event.getIntegerValueField(.scrollWheelEventScrollPhase))
            let momentum = Int(event.getIntegerValueField(.scrollWheelEventMomentumPhase))
            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let t = ScrollBlocker.now()
            let (drop, idle) = ScrollBlocker.state.withLock { g in
                (g.shouldDrop(phase: phase, momentum: momentum, continuous: continuous, now: t), g.isIdle(now: t))
            }
            if idle { ScrollBlocker.setTap(false) }               // swipe over: out of the way again
            guard drop else { return Unmanaged.passUnretained(event) }
            // A scroll's end (ended 4, cancelled 8, momentum end 3) still goes through, with no
            // movement, so apps don't stay in a "scrolling" state. Everything else is dropped.
            if phase == 4 || phase == 8 || momentum == 3 {
                for f in ScrollBlocker.deltaFields { event.setIntegerValueField(f, value: 0) }
                event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
                event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
                return Unmanaged.passUnretained(event)
            }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
