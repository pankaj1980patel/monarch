import AppKit
import MonarchCore

/// Snapping, undo, moving between screens and the fill toggle.
///
/// The main thread only picks the frontmost app and copies the display list (microseconds);
/// all Accessibility work then runs on that app's own queue in a single hop.
@MainActor
final class SnapManager {
    private let engine: WindowEngine
    private let displays: DisplayManager
    private let perf: PerformanceMonitor
    private let history = WindowHistory()

    init(engine: WindowEngine, displays: DisplayManager, perf: PerformanceMonitor) {
        self.engine = engine
        self.displays = displays
        self.perf = perf
    }

    /// `eventTime` is the key press's timestamp, so the recorded time covers the whole path.
    func perform(_ action: Action, eventTime: Double) {
        perf.record("1 hotkey → main thread", since: eventTime)
        if let n = action.arrangeCount { arrange(n, eventTime: eventTime); return }
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let app = engine.app(for: front.processIdentifier, name: front.localizedName ?? "?")
        let screens = displays.displays
        let history = self.history, perf = self.perf
        let queued = PerformanceMonitor.now()

        app.queue.async { @Sendable in
            let started = PerformanceMonitor.now()
            perf.stats.record("2 queue wait", ms: (started - queued) * 1000)
            let state = perf.signposter.beginInterval("action", "\(action.rawValue)")
            defer { perf.signposter.endInterval("action", state) }

            guard let win = AX.element(app.element, kAXFocusedWindowAttribute)
                    ?? AX.element(app.element, kAXMainWindowAttribute),
                  let current = AX.frame(win),
                  let display = Geometry.display(for: current, in: screens) else { return }
            let id = AX.windowID(win) ?? CGWindowID(truncatingIfNeeded: CFHash(win))

            let moved = Self.run(action, win: win, id: id, current: current, display: display,
                                 screens: screens, app: app, history: history)
            if moved {
                perf.record("3 AX work (move window)", since: started)
                perf.record("4 total: key press → window moved", since: eventTime)
            }
        }
    }

    /// ⌃⌥⌘ N: tile the N front-most windows on the screen under the mouse (0 = all of them).
    /// Only windows actually showing there count, which is the screen's current workspace:
    /// windows on hidden workspaces are parked off-screen and excluded.
    private func arrange(_ n: Int, eventTime: Double) {
        let screens = displays.displays
        let cursor = AutoFocusManager.cursor()
        guard let display = screens.first(where: { $0.frame.contains(cursor) }) ?? screens.first else { return }

        var picked: [ManagedWindow] = []
        for id in AutoFocusManager.zOrder() {                 // front to back
            guard let w = engine.windows[id], !w.isMinimized, !engine.hiddenPIDs.contains(w.pid),
                  Geometry.display(for: w.frame, in: screens)?.id == display.id,
                  FocusLogic.visibleFraction(w.frame, on: display.frame) >= FocusLogic.minVisibleFraction
            else { continue }
            picked.append(w)
            if n > 0 && picked.count == n { break }
        }
        guard !picked.isEmpty else { beep(); return }

        let frames = ArrangeLayout.frames(count: picked.count, in: display.visibleFrame)
        var byApp: [pid_t: [(CGWindowID, CGRect)]] = [:]
        for (w, f) in zip(picked, frames) { byApp[w.pid, default: []].append((w.id, f)) }

        // One hop per app, all apps in parallel; the group times the whole arrangement.
        let group = DispatchGroup()
        let history = self.history
        for (pid, items) in byApp {
            guard let app = engine.apps[pid] else { continue }
            app.queue.async(group: group) { @Sendable in
                for (id, frame) in items {
                    guard let win = app.element(for: id), let current = AX.frame(win) else { continue }
                    history.remember(id, current)
                    WindowMover.apply(frame, to: win, app: app.element, current: current)
                }
            }
        }
        let perf = self.perf
        // Main queue: a closure written in this @MainActor method must run on the main thread
        // (on a background queue Swift's isolation check stops the app — the step 6 crash).
        group.notify(queue: .main) {
            perf.record("4b total: ⌃⌥⌘ N arrange", since: eventTime)
        }
    }

    /// Runs on the app's queue. Returns true if a frame was sent.
    nonisolated private static func run(_ action: Action, win: AXUIElement, id: CGWindowID, current: CGRect,
                                        display: Display, screens: [Display], app: TrackedApp,
                                        history: WindowHistory) -> Bool {
        let area = display.visibleFrame
        switch action {
        case .undo:
            guard let saved = history.swapForUndo(id, current: current) else { beep(); return false }
            return WindowMover.apply(saved, to: win, app: app.element, current: current)

        case .moveScreenWest, .moveScreenEast, .moveScreenNextMaximize:
            let dir: Geometry.Direction = action == .moveScreenWest ? .west : action == .moveScreenEast ? .east : .next
            guard let target = Geometry.neighbor(of: display, dir, in: screens) else { beep(); return false }
            history.remember(id, current)
            let frame = action == .moveScreenNextMaximize
                ? target.visibleFrame
                : Geometry.map(current, from: area, to: target.visibleFrame)
            return WindowMover.apply(frame, to: win, app: app.element, current: current)

        case .fillToggle:
            return fill(win: win, id: id, current: current, area: area, app: app, history: history)

        default:
            guard let plan = SnapLayouts.plan(for: action) else { return false }
            let unit: UnitRect
            switch plan {
            case let .unit(u):
                history.remember(id, current)
                unit = u
            case let .cycle(key, rects):
                let i = history.nextCycleIndex(key: key, window: id, count: rects.count,
                                               current: current, now: PerformanceMonitor.now())
                unit = rects[i]
            }
            return WindowMover.apply(Geometry.rect(for: unit, in: area), to: win, app: app.element, current: current)
        }
    }

    /// ⌃⌘F: fill the screen without macOS full screen (the other display stays usable);
    /// press again to restore. A window already in macOS full screen is taken out and filled.
    nonisolated private static func fill(win: AXUIElement, id: CGWindowID, current: CGRect, area: CGRect,
                                         app: TrackedApp, history: WindowHistory) -> Bool {
        if AX.bool(win, "AXFullScreen") == true {
            AX.setBool(win, "AXFullScreen", false)
            let ref = AXRef(win)
            // Wait for the exit animation, then fill the window's own display.
            app.queue.asyncAfter(deadline: .now() + 0.8) {
                guard let f = AX.frame(ref.element) else { return }
                history.saveBeforeFill(id, f)
                WindowMover.apply(area, to: ref.element, app: app.element, current: f)
            }
            return false
        }
        if Geometry.nearlyEqual(current, area, tolerance: 4), let before = history.takeBeforeFill(id) {
            return WindowMover.apply(before, to: win, app: app.element, current: current)
        }
        history.saveBeforeFill(id, current)
        return WindowMover.apply(area, to: win, app: app.element, current: current)
    }
}

/// Audible "can't do that" (nothing to undo, no other screen). AppKit wants the main thread.
private func beep() { DispatchQueue.main.async { NSSound.beep() } }
