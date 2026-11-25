import AppKit
import MonarchCore

/// Cross-screen focus, same-app hover focus, ⌃⌥ N and directional focus.
///
/// Decisions use only the engine's cached state (updated by notifications), so the mouse path
/// never asks an app anything. The z-order query (one WindowServer call) runs only as the last
/// fallback, or to confirm a hover target is really on top.
@MainActor
final class AutoFocusManager {
    private let engine: WindowEngine
    private let displays: DisplayManager
    private let perf: PerformanceMonitor
    private let tracker = MouseTracker()
    private let toast: Toast
    private var history = FocusHistory()

    private(set) var crossScreen = true
    private(set) var sameAppHover = false
    private(set) var tapFailed = false
    private var active = false        // false while Monarch's shortcuts are off (Hammerspoon owns focus then)

    /// Saves toggle changes to config.json.
    var onToggle: ((_ cross: Bool, _ hover: Bool) -> Void)?

    init(engine: WindowEngine, displays: DisplayManager, perf: PerformanceMonitor, toast: Toast) {
        self.engine = engine
        self.displays = displays
        self.perf = perf
        self.toast = toast

        engine.onFocus { [unowned self] id in
            // While a ⌘Tab pick is on its way, other windows macOS focuses in passing (e.g. when a
            // workspace switch parks the focused app's windows) don't count as "recently used".
            if let p = engine.pendingFocusID, p != id { return }
            record(id)
        }
        engine.onRemove { [unowned self] id in history.forget(window: id) }
        tracker.onCross = { id, p in MainActor.assumeIsolated { self.crossed(to: id, at: p) } }
        tracker.onHover = { MainActor.assumeIsolated { self.hovered() } }
        tracker.onFailure = { MainActor.assumeIsolated { self.tapFailed = true } }
    }

    var isListening: Bool { tracker.isActive }
    /// Most recently used windows, newest first (fed by every focus change). Used by ⌘Tab.
    var mru: [UInt32] { history.mru }

    // MARK: Configuration

    func configure(cross: Bool, hover: Bool, active: Bool) {
        crossScreen = cross
        sameAppHover = hover
        self.active = active
        displaysChanged()
    }

    /// Also re-decides whether the mouse listener is needed: with one display there is no
    /// crossing, so it runs only for hover focus (off by default) and costs nothing otherwise.
    func displaysChanged() {
        let list = displays.displays
        tracker.update(displays: list.map { ($0.id, $0.frame) }, cursor: Self.cursor())
        history.keepDisplays(Set(list.map(\.id)))
        let cross = active && crossScreen && list.count > 1
        let hover = active && sameAppHover
        tracker.configure(cross: cross, hover: hover)
        tapFailed = (cross || hover) && !tracker.isActive
    }

    // MARK: Actions (shortcuts)

    func perform(_ action: Action, eventTime: Double) {
        switch action {
        case .toggleCrossScreenFocus:
            crossScreen.toggle()
            toast.show("Cross-screen focus: \(crossScreen ? "ON" : "OFF")")
            configure(cross: crossScreen, hover: sameAppHover, active: active)
            onToggle?(crossScreen, sameAppHover)
        case .toggleSameAppHover:
            sameAppHover.toggle()
            toast.show("Same-app hover focus: \(sameAppHover ? "ON" : "OFF")")
            configure(cross: crossScreen, hover: sameAppHover, active: active)
            onToggle?(crossScreen, sameAppHover)
        case .focusOtherScreen:
            focusOtherScreen(eventTime)
        case .focusWest: focus(direction: .west, eventTime)
        case .focusEast: focus(direction: .east, eventTime)
        case .focusNorth: focus(direction: .north, eventTime)
        case .focusSouth: focus(direction: .south, eventTime)
        default: break
        }
    }

    // MARK: History

    /// Monarch is focusing `id` itself (⌘Tab): it's the newest recent window right away,
    /// not when macOS's notification arrives.
    func noteFocusing(_ id: CGWindowID) {
        engine.noteFocusing(id)
        record(id)
    }

    /// Every focus change, however it happened (click, app switch, ⌘Tab, our own focusing),
    /// becomes the "last used" window of the display it is on.
    private func record(_ id: CGWindowID) {
        guard let w = engine.windows[id],
              let d = Geometry.display(for: w.frame, in: displays.displays),
              FocusLogic.visibleFraction(w.frame, on: d.frame) >= FocusLogic.minVisibleFraction
        else { return }
        history.record(window: id, display: d.id)
    }

    // MARK: Cross-screen

    private func crossed(to displayID: UInt32, at point: CGPoint) {
        guard active, crossScreen, let display = displays.displays.first(where: { $0.id == displayID }) else { return }
        let start = PerformanceMonitor.now()
        if let f = engine.focusedID { record(f) }   // the screen we left: remember what was in use
        guard let target = FocusLogic.windowForScreen(
            display, displays: displays.displays, focused: engine.focusedID,
            windows: candidates(), history: history, zOrder: { Self.zOrder() }) else { return }
        perf.stats.record("5 focus: decide on screen crossing", ms: (PerformanceMonitor.now() - start) * 1000)
        focus(target, metric: "6 focus: screen crossed → window focused", since: start)
    }

    // MARK: Same-app hover

    private func hovered() {
        guard active, sameAppHover, let fid = engine.focusedID, let focused = engine.windows[fid] else { return }
        let p = Self.cursor()
        if focused.frame.contains(p) { return }                     // still over the focused window
        let hiddenApp = engine.hiddenPIDs.contains(focused.pid)
        let hit = engine.windows.values.contains {
            $0.pid == focused.pid && $0.id != fid && !$0.isMinimized && !hiddenApp && $0.frame.contains(p)
        }
        guard hit else { return }                                   // not over another window of this app
        // Only if that window is really the top-most thing under the cursor.
        let start = PerformanceMonitor.now()
        guard let top = Self.topWindow(at: p), top != fid,
              let w = engine.windows[top], w.pid == focused.pid else { return }
        focus(top, metric: "7 focus: hover → window focused", since: start)
    }

    // MARK: ⌃⌥ N and ⌃⌥⇧ arrows

    private func focusOtherScreen(_ eventTime: Double) {
        let list = displays.displays
        let p = Self.cursor()
        guard list.count > 1,
              let current = list.first(where: { $0.frame.contains(p) }) ?? list.first,
              let target = Geometry.neighbor(of: current, .next, in: list) else {
            toast.show("Only one screen"); return
        }
        // Move the cursor first (no event is generated, so this isn't seen as a crossing).
        let center = CGPoint(x: target.visibleFrame.midX, y: target.visibleFrame.midY)
        CGWarpMouseCursorPosition(center)
        CGAssociateMouseAndMouseCursorPosition(1)
        tracker.setCurrent(target.id)
        if let f = engine.focusedID { record(f) }
        if let id = FocusLogic.windowForScreen(target, displays: list, focused: engine.focusedID,
                                               windows: candidates(), history: history,
                                               zOrder: { Self.zOrder() }) {
            focus(id, metric: "8 focus: ⌃⌥ N → window focused", since: eventTime)
        }
    }

    private func focus(direction: FocusLogic.Direction, _ eventTime: Double) {
        guard let fid = engine.focusedID, let f = engine.windows[fid] else { return }
        let list = displays.displays
        // Only windows actually showing: visible on some display, and not covered entirely is
        // approximated by "on-screen" from the window server.
        let onScreen = Set(Self.zOrder())
        let all = candidates()
        let pool = all.values.filter { c in
            c.id != fid && onScreen.contains(c.id)
                && list.contains { FocusLogic.visibleFraction(c.frame, on: $0.frame) >= FocusLogic.minVisibleFraction }
        }
        guard let id = FocusLogic.window(in: direction, from: f.frame, candidates: pool) else { NSSound.beep(); return }
        focus(id, metric: "9 focus: ⌃⌥⇧ arrow → window focused", since: eventTime)
    }

    // MARK: Helpers

    private func focus(_ id: CGWindowID, metric: String, since start: Double) {
        guard let w = engine.windows[id], let app = engine.apps[w.pid] else { return }
        if let d = Geometry.display(for: w.frame, in: displays.displays) { history.record(window: id, display: d.id) }
        WindowFocuser.focus(id, of: app, perf: perf, metric: metric, since: start)
    }

    private func candidates() -> [UInt32: FocusCandidate] {
        var out: [UInt32: FocusCandidate] = [:]
        out.reserveCapacity(engine.windows.count)
        for (id, w) in engine.windows {
            out[id] = FocusCandidate(id: id, pid: w.pid, frame: w.frame, isMinimized: w.isMinimized,
                                     appHidden: engine.hiddenPIDs.contains(w.pid))
        }
        return out
    }

    /// Cursor position in AX coordinates (top-left origin).
    /// From NSEvent.mouseLocation (no event object created), flipped to AX coordinates.
    static func cursor() -> CGPoint {
        let p = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// On-screen normal windows, front to back. One WindowServer call: fetch once per
    /// operation and pass it down.
    static func zOrder() -> [UInt32] { WindowList.zOrder() }

    /// The front-most normal window under `p`.
    static func topWindow(at p: CGPoint) -> UInt32? { WindowList.topWindow(at: p) }
}
