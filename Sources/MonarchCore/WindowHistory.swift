import CoreGraphics
import Synchronization

/// Snapping state shared by all per-app queues: the press-again-to-cycle state and the
/// frames saved by the fill toggle.
/// Guarded by a Mutex because actions for different apps run on different queues.
public final class WindowHistory: Sendable {
    public static let cycleWindow: Double = 1.5   // seconds; same as Hammerspoon

    private struct CycleState { var key: String?; var window: UInt32 = 0; var index = 0; var time: Double = 0 }
    private struct State {
        var beforeFill: [UInt32: CGRect] = [:]
        var cycle = CycleState()
    }
    private let state = Mutex(State())

    public init() {}

    /// Picks the layout for a cycling key. A repeat press on the same window within
    /// `cycleWindow` seconds advances; otherwise it starts over.
    public func nextCycleIndex(key: String, window: UInt32, count: Int, now: Double) -> Int {
        state.withLock { s in
            var c = s.cycle
            if c.key == key, c.window == window, now - c.time < Self.cycleWindow {
                c.index = (c.index + 1) % count
            } else {
                c.index = 0
            }
            c.key = key; c.window = window; c.time = now
            s.cycle = c
            return c.index
        }
    }

    public func saveBeforeFill(_ window: UInt32, _ frame: CGRect) {
        state.withLock { $0.beforeFill[window] = frame }
    }

    public func takeBeforeFill(_ window: UInt32) -> CGRect? {
        state.withLock { $0.beforeFill.removeValue(forKey: window) }
    }

    public func peekBeforeFill(_ window: UInt32) -> CGRect? {
        state.withLock { $0.beforeFill[window] }
    }

    /// Drops state for a closed window.
    public func forget(_ window: UInt32) {
        state.withLock { s in
            s.beforeFill.removeValue(forKey: window)
            // A new window that reuses this ID must start its own cycle.
            if s.cycle.window == window { s.cycle = CycleState() }
        }
    }
}
