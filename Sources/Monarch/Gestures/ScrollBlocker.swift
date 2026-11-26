import CoreGraphics
import Foundation
import MonarchCore
import Synchronization

/// Drops scroll events while a three- or four-finger swipe is under way (rules in
/// `ScrollGuard`). The touch callback reports frames; an event tap for scroll events only,
/// on its own thread (so a busy main thread never delays scrolling), asks the guard.
///
/// The tap exists only while gestures run with `blockScroll` on. Per scroll event it costs one
/// uncontended lock and a few comparisons.
enum ScrollBlocker {
    private static let state = Mutex(ScrollGuard())
    /// Touch frames are reported only while the tap is installed.
    private static let enabled = Atomic<Bool>(false)
    nonisolated(unsafe) private static var tap: CFMachPort?
    nonisolated(unsafe) private static var thread: Thread?
    nonisolated(unsafe) private static var loop: CFRunLoop?

    /// True while the tap is installed (creating it can fail without Accessibility).
    static var isInstalled: Bool { enabled.load(ordering: .relaxed) }

    /// Seconds on one clock for both threads.
    static func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

    /// From the touch callback, every frame. Never allocates.
    static func frame(locked: Bool, contacts: Int) {
        guard enabled.load(ordering: .relaxed) else { return }
        let t = now()
        state.withLock { $0.frame(locked: locked, contacts: contacts, now: t) }
    }

    /// Installs or removes the tap (main thread).
    static func setEnabled(_ on: Bool) {
        guard on != enabled.load(ordering: .relaxed) else { return }
        if on { install() } else { uninstall() }
    }

    private static func install() {
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback, userInfo: nil) else { return }
        tap = port
        state.withLock { $0.clear() }
        enabled.store(true, ordering: .relaxed)
        // CF objects aren't Sendable; they're handed to the thread once, before it runs.
        struct Handoff: @unchecked Sendable { let port: CFMachPort; let source: CFRunLoopSource? }
        let h = Handoff(port: port, source: CFMachPortCreateRunLoopSource(nil, port, 0))
        let ready = DispatchSemaphore(value: 0)
        let t = Thread {
            loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), h.source, .commonModes)
            CGEvent.tapEnable(tap: h.port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "Monarch scroll guard"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()
    }

    private static func uninstall() {
        enabled.store(false, ordering: .relaxed)
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let loop { CFRunLoopStop(loop) }
        tap = nil; loop = nil; thread = nil
        state.withLock { $0.clear() }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, _ in
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = ScrollBlocker.tap { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        case .scrollWheel:
            let phase = Int(event.getIntegerValueField(.scrollWheelEventScrollPhase))
            let momentum = Int(event.getIntegerValueField(.scrollWheelEventMomentumPhase))
            let t = ScrollBlocker.now()
            let drop = ScrollBlocker.state.withLock { $0.shouldDrop(phase: phase, momentum: momentum, now: t) }
            return drop ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
