import CoreGraphics
import Foundation
import Synchronization

/// Listen-only mouse-move tap on its own thread.
///
/// Per mouse move it does one thing: find which display the cursor is on (a check against
/// at most a few cached rects). Crossing to another display is reported at once; otherwise,
/// if hover is wanted, a single debounced check fires once the cursor rests for 50 ms.
/// The tap is created once and switched on/off; while off it costs nothing.
final class MouseTracker: @unchecked Sendable {
    static let hoverPause = 0.05

    private struct State {
        var displays: [(id: UInt32, frame: CGRect)] = []
        var current: UInt32 = 0
        var crossEnabled = false
        var hoverEnabled = false
        var lastMove: Double = 0
        var hoverPending = false
    }
    private let state = Mutex(State())

    /// Called on the main queue: (new display, cursor position in AX coordinates).
    var onCross: (@Sendable (UInt32, CGPoint) -> Void)?
    /// Called on the main queue once the cursor has rested for `hoverPause` on one display.
    var onHover: (@Sendable () -> Void)?
    /// Called on the main queue if macOS refuses the tap.
    var onFailure: (@Sendable () -> Void)?

    private var tap: CFMachPort?
    private var thread: Thread?
    private let ready = DispatchSemaphore(value: 0)

    func update(displays: [(id: UInt32, frame: CGRect)], cursor: CGPoint) {
        state.withLock { s in
            s.displays = displays
            s.current = displays.first(where: { $0.frame.contains(cursor) })?.id ?? s.current
        }
    }

    /// Turns the tap on when either feature wants it, off otherwise.
    func configure(cross: Bool, hover: Bool) {
        state.withLock { $0.crossEnabled = cross; $0.hoverEnabled = hover; $0.hoverPending = false }
        let want = cross || hover
        // (Re)create the tap if it doesn't exist: macOS refuses it while Accessibility is
        // still being granted, so a later configure() (e.g. on grant) simply tries again.
        if want && tap == nil { startThread() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: want) }
    }

    var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Tells the tracker the cursor was moved programmatically (⌃⌥ N), so it doesn't
    /// report that as a crossing.
    func setCurrent(_ id: UInt32) { state.withLock { $0.current = id } }

    private func startThread() {
        let t = Thread { [self] in
            let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            let created = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let me = Unmanaged<MouseTracker>.fromOpaque(refcon).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        me.reenable()
                    } else {
                        me.moved(event.location)
                    }
                    return Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque())
            tap = created
            ready.signal()
            guard let created else {
                if let f = onFailure { DispatchQueue.main.async { f() } }
                return
            }
            let src = CFMachPortCreateRunLoopSource(nil, created, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CFRunLoopRun()
        }
        t.name = "monarch.mouse"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()   // tap exists (or failed) before configure() continues
    }

    private func reenable() {
        let want = state.withLock { $0.crossEnabled || $0.hoverEnabled }
        if want, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Runs on the tap thread for every mouse move. No allocation, no AX, no AppKit.
    private func moved(_ p: CGPoint) {
        enum Outcome { case none, cross(UInt32), scheduleHover }
        let now = PerformanceMonitor.now()
        let outcome: Outcome = state.withLock { s in
            var id = s.current
            for d in s.displays where d.frame.contains(p) { id = d.id; break }
            if id != s.current {
                let had = s.current != 0
                s.current = id
                s.hoverPending = false
                return had && s.crossEnabled ? .cross(id) : .none
            }
            guard s.hoverEnabled else { return .none }
            s.lastMove = now
            if s.hoverPending { return .none }
            s.hoverPending = true
            return .scheduleHover
        }
        switch outcome {
        case .none: break
        case let .cross(id):
            if let f = onCross { DispatchQueue.main.async { f(id, p) } }
        case .scheduleHover:
            scheduleHoverCheck(after: Self.hoverPause)
        }
    }

    /// Fires `onHover` once the cursor has been still for `hoverPause`; re-arms itself while it moves.
    private func scheduleHoverCheck(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            let remaining: Double? = state.withLock { s in
                guard s.hoverPending, s.hoverEnabled else { s.hoverPending = false; return nil }
                let still = PerformanceMonitor.now() - s.lastMove
                if still >= Self.hoverPause { s.hoverPending = false; return 0 }
                return Self.hoverPause - still
            }
            guard let remaining else { return }
            if remaining == 0 { onHover?() } else { scheduleHoverCheck(after: remaining) }
        }
    }
}
