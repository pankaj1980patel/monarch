import AppKit
import MonarchCore

/// Nine independent workspaces per display, i3 style, without macOS Spaces.
///
/// A window on a hidden workspace is parked just off a corner of its own display (never one
/// that borders the other display), with its frame saved, and comes back exactly where it was.
/// State survives restarts in workspaces.json.
///
/// All window moves for one switch run on the apps' own queues in parallel; the main thread
/// only decides what goes where.
@MainActor
final class WorkspaceManager {
    private let engine: WindowEngine
    private let displays: DisplayManager
    private let perf: PerformanceMonitor
    private let bridge: HammerspoonBridge
    private let hud = WorkspaceHUD()

    private(set) var state = WorkspaceState()
    /// Called after every change (menu bar indicator, overview).
    var onChange: (() -> Void)?
    /// Bridge commands that aren't about workspaces (overview, gesture state).
    var onOtherCommand: ((HammerspoonBridge.Command) -> Void)?
    /// Focus a window (shared with auto focus / switcher so focus history stays right).
    var focus: ((CGWindowID, String, Double) -> Void)?

    /// Only while Monarch owns the shortcuts; otherwise Hammerspoon manages workspaces.
    private(set) var isActive = false
    private var lastSwitch: Double = 0
    private var displayUUIDs: Set<String> = []
    private var restoreWork: DispatchWorkItem?

    static var fileURL: URL {
        ConfigurationStore.url.deletingLastPathComponent().appendingPathComponent("workspaces.json")
    }

    init(engine: WindowEngine, displays: DisplayManager, perf: PerformanceMonitor, bridge: HammerspoonBridge) {
        self.engine = engine
        self.displays = displays
        self.perf = perf
        self.bridge = bridge
        displayUUIDs = Set(displays.displays.map(\.uuid))

        engine.onRemove { [unowned self] id in
            if isActive, state.hidden.removeValue(forKey: String(id)) != nil { save() }
        }
        // Moved out of its parking spot by the user or an app (e.g. a layout): no longer parked.
        engine.onUpdate { [unowned self] w in
            guard isActive, let e = state.parked(w.id), !Parking.isAtPark(w.frame, e) else { return }
            state.hidden.removeValue(forKey: String(w.id))
            save()
        }
        // A parked window got focus (Dock click, notification, app switch): show its workspace.
        engine.onFocus { [unowned self] id in
            guard isActive, state.isParked(id), PerformanceMonitor.now() - lastSwitch > 0.6 else { return }
            reveal(id)
        }
        bridge.onCommand = { [unowned self] c in if isActive { handle(c) } }
    }

    /// Takes over (or hands back) workspaces. On takeover the newest state is loaded: while
    /// Hammerspoon runs, its saved state is always current (it manages workspaces itself while
    /// Monarch is off, and mirrors Monarch's state while Monarch is on).
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active { load() }
    }

    // MARK: Persistence

    private func load() {
        let hammerspoonRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "org.hammerspoon.Hammerspoon").isEmpty
        if hammerspoonRunning, let imported = HammerspoonBridge.importHammerspoonState() {
            state = imported
        } else if let data = try? Data(contentsOf: Self.fileURL),
                  let s = try? JSONDecoder().decode(WorkspaceState.self, from: data) {
            state = s
        }
        // Forget windows that closed while Monarch wasn't running. The window server knows
        // every window that exists, so this is exact and needs no waiting for app discovery.
        let alive = Self.existingWindowIDs()
        let before = state.hidden.count
        state.hidden = state.hidden.filter { UInt32($0.key).map(alive.contains) ?? false }
        if state.hidden.count != before || !FileManager.default.fileExists(atPath: Self.fileURL.path) { save() }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(state) {
            try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.fileURL, options: .atomic)
        }
        bridge.stateChanged()
        onChange?()
    }

    // MARK: Commands

    func perform(_ action: Action, eventTime: Double) {
        if let n = action.switchWorkspace, let d = mouseDisplay() { switchTo(n, on: d, eventTime: eventTime) }
        else if let n = action.moveWorkspace { moveFocused(to: n, eventTime: eventTime) }
        else if action == .restoreAllWindows { restoreAll(); hud.toast("All windows back", on: mouseDisplay()) }
    }

    private func handle(_ c: HammerspoonBridge.Command) {
        let now = PerformanceMonitor.now()
        switch c {
        case let .switchTo(n, uuid):
            if let d = display(uuid) ?? mouseDisplay() { switchTo(n, on: d, eventTime: now) }
        case let .place(id, uuid, n):
            if let d = display(uuid) { place(id, on: d, workspace: n) }
        case let .reveal(id):
            reveal(id)
        case .restoreAll:
            restoreAll()
        case .overview, .gesture:
            onOtherCommand?(c)
        }
    }

    /// Switches `display` to workspace `n`: parks what is showing there, brings back what was
    /// parked on `n`, focuses its top window (or `focusID`).
    func switchTo(_ n: Int, on display: Display, focusID: CGWindowID? = nil, eventTime: Double) {
        let uuid = display.uuid
        let cur = state.activeWorkspace(uuid)
        guard n != cur else {
            hud.flash(on: display, state: state, from: nil, target: nil)
            if let focusID { focus?(focusID, "12 workspace: reveal → focused", eventTime) }
            return
        }
        lastSwitch = PerformanceMonitor.now()

        var parks: [CGWindowID] = []
        for (z, id) in visibleWindows(on: display).enumerated() {
            guard let w = engine.windows[id] else { continue }
            state.hidden[String(id)] = entry(for: w.frame, ws: cur, display: display, z: z + 1)
            parks.append(id)
        }
        var restores: [(CGWindowID, CGRect)] = []
        for (id, e) in state.incoming(n, on: uuid) {
            state.hidden.removeValue(forKey: String(id))
            restores.append((id, e.relativeFrame.offsetBy(dx: display.visibleFrame.minX, dy: display.visibleFrame.minY)))
        }
        state.active[uuid] = n
        let top = focusID ?? restores.last?.0

        run(parks: parks, home: display, restores: restores) { [weak self] in
            guard let self else { return }
            self.save()
            if let top { self.focus?(top, "12 workspace: switch → focused", eventTime) }
            else { self.focusTopOrNothing(on: display, eventTime: eventTime) }
            self.perf.record("13 workspace: switch total", since: eventTime)
        }
        hud.flash(on: display, state: state, from: cur, target: nil)
    }

    /// Four-finger swipe: next (+1) / previous (−1) workspace on the screen under the mouse.
    func step(_ dir: Int, eventTime: Double) {
        guard let d = mouseDisplay() else { return }
        let n = max(1, min(WorkspaceState.count, state.activeWorkspace(d.uuid) + dir))
        switchTo(n, on: d, eventTime: eventTime)
    }

    /// ⌥⇧ N: sends the focused window to workspace `n` of its display.
    func moveFocused(to n: Int, eventTime: Double) {
        guard let id = engine.focusedID, !state.isParked(id), let w = engine.windows[id],
              let d = Geometry.display(for: w.frame, in: displays.displays) else { return }
        guard n != state.activeWorkspace(d.uuid) else { return }
        lastSwitch = PerformanceMonitor.now()
        state.hidden[String(id)] = entry(for: w.frame, ws: n, display: d, z: 0)
        run(parks: [id], home: d, restores: []) { [weak self] in
            self?.save()
            self?.focusTopOrNothing(on: d, eventTime: eventTime)
        }
        hud.flash(on: d, state: state, from: nil, target: n)
    }

    /// Overview drag: put window `id` on workspace `n` of `target` (visible if `n` is active there).
    func place(_ id: CGWindowID, on target: Display, workspace n: Int) {
        guard let w = engine.windows[id] else { return }
        let rel: CGRect
        if let e = state.parked(id) { rel = e.relativeFrame }
        else {
            let home = Geometry.display(for: w.frame, in: displays.displays) ?? target
            rel = w.frame.offsetBy(dx: -home.visibleFrame.minX, dy: -home.visibleFrame.minY)
        }
        let fitted = Parking.fit(rel, into: target.visibleFrame.size)
        lastSwitch = PerformanceMonitor.now()
        if n == state.activeWorkspace(target.uuid) {
            state.hidden.removeValue(forKey: String(id))
            run(parks: [], home: target, restores: [(id, fitted.offsetBy(dx: target.visibleFrame.minX, dy: target.visibleFrame.minY))]) {
                [weak self] in self?.save()
            }
        } else {
            state.hidden[String(id)] = ParkedWindow(ws: n, scr: target.uuid, x: fitted.minX, y: fitted.minY,
                                                    w: fitted.width, h: fitted.height, z: 99)
            run(parks: [id], home: target, restores: []) { [weak self] in self?.save() }
        }
    }

    /// Shows the workspace holding window `id` and focuses it.
    func reveal(_ id: CGWindowID, eventTime: Double = PerformanceMonitor.now()) {
        guard let e = state.parked(id) else { focus?(id, "12 workspace: reveal → focused", eventTime); return }
        if let w = engine.windows[id], !Parking.isAtPark(w.frame, e) {
            state.hidden.removeValue(forKey: String(id))       // moved out by hand: just forget it
            save()
            focus?(id, "12 workspace: reveal → focused", eventTime)
            return
        }
        if let d = display(e.scr) {
            switchTo(e.ws, on: d, focusID: id, eventTime: eventTime)
        } else if let d = displays.displays.first {            // its display is gone: bring it here
            state.hidden.removeValue(forKey: String(id))
            run(parks: [], home: d, restores: [(id, Parking.fit(e.relativeFrame, into: d.visibleFrame.size)
                .offsetBy(dx: d.visibleFrame.minX, dy: d.visibleFrame.minY))]) { [weak self] in
                self?.save()
                self?.focus?(id, "12 workspace: reveal → focused", eventTime)
            }
        }
    }

    /// ⌃⌥⇧ 0, and on display changes: every parked window back, all displays on workspace 1.
    func restoreAll() {
        var restores: [(CGWindowID, CGRect)] = []
        let list = displays.displays
        for (k, e) in state.hidden {
            guard let id = UInt32(k), let d = display(e.scr) ?? list.first else { continue }
            restores.append((id, Parking.fit(e.relativeFrame, into: d.visibleFrame.size)
                .offsetBy(dx: d.visibleFrame.minX, dy: d.visibleFrame.minY)))
        }
        state.hidden.removeAll()
        state.active.removeAll()
        guard let home = list.first else { save(); return }
        run(parks: [], home: home, restores: restores) { [weak self] in self?.save() }
        if restores.isEmpty { save() }
    }

    /// Display plugged in or out: bring everything back (like the Hammerspoon setup did),
    /// after the arrangement has settled.
    func displaysChanged() {
        let now = Set(displays.displays.map(\.uuid))
        guard now != displayUUIDs else { return }
        displayUUIDs = now
        restoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.state.hidden.isEmpty else { return }
            self.restoreAll()
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: Window moves

    /// Parks and restores windows, one hop per app, all apps in parallel; `done` runs on main.
    private func run(parks: [CGWindowID], home: Display, restores: [(CGWindowID, CGRect)], done: @escaping () -> Void) {
        var byApp: [pid_t: (parks: [CGWindowID], restores: [(CGWindowID, CGRect)])] = [:]
        for id in parks { if let w = engine.windows[id] { byApp[w.pid, default: ([], [])].parks.append(id) } }
        for r in restores { if let w = engine.windows[r.0] { byApp[w.pid, default: ([], [])].restores.append(r) } }

        let group = DispatchGroup()
        let screens = displays.displays
        let results = ParkResults()
        for (pid, work) in byApp {
            guard let app = engine.apps[pid] else { continue }
            app.queue.async(group: group) { @Sendable in
                for id in work.parks {
                    guard let win = app.element(for: id) else { continue }
                    // macOS full-screen windows live in their own Space: leave them alone.
                    if AX.bool(win, "AXFullScreen") == true { results.add(id, nil); continue }
                    results.add(id, Self.park(win, home: home, displays: screens))
                }
                for (id, frame) in work.restores {
                    guard let win = app.element(for: id), let current = AX.frame(win) else { continue }
                    WindowMover.apply(frame, to: win, app: app.element, current: current)
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for (id, spot) in results.all {
                    let key = String(id)
                    if let spot { self.state.hidden[key]?.px = spot.x; self.state.hidden[key]?.py = spot.y }
                    else { self.state.hidden.removeValue(forKey: key) }
                }
                done()
            }
        }
    }

    /// Parks one window off a corner of `home`; returns where macOS actually put it.
    /// App queue only.
    nonisolated private static func park(_ win: AXUIElement, home: Display, displays: [Display]) -> CGPoint? {
        guard let size = AX.size(win) else { return nil }
        var last: CGPoint?
        for spot in Parking.spots(for: size, screen: home.frame) {
            AX.setPoint(win, spot)
            guard let actual = AX.point(win) else { continue }
            last = actual
            if !Parking.overlapsOther(CGRect(origin: actual, size: size), home: home.id, displays: displays) { break }
        }
        return last
    }

    // MARK: Helpers

    private func entry(for frame: CGRect, ws: Int, display: Display, z: Int) -> ParkedWindow {
        let v = display.visibleFrame
        return ParkedWindow(ws: ws, scr: display.uuid, x: frame.minX - v.minX, y: frame.minY - v.minY,
                            w: frame.width, h: frame.height, z: z)
    }

    /// Windows showing on `display`, top-most first.
    func visibleWindows(on display: Display) -> [CGWindowID] {
        let screens = displays.displays
        return AutoFocusManager.zOrder().filter { id in
            guard let w = engine.windows[id], !w.isMinimized, !engine.hiddenPIDs.contains(w.pid), !state.isParked(id)
            else { return false }
            return Geometry.display(for: w.frame, in: screens)?.id == display.id
                && FocusLogic.visibleFraction(w.frame, on: display.frame) >= FocusLogic.minVisibleFraction
        }
    }

    /// After a switch or send: focus the top window left on that display. If there is none and
    /// focus is still on a now-parked window, move focus to the top window elsewhere so keys
    /// don't go to something hidden.
    private func focusTopOrNothing(on display: Display, eventTime: Double) {
        if let top = visibleWindows(on: display).first { focus?(top, "12 workspace: switch → focused", eventTime); return }
        guard let f = engine.focusedID, state.isParked(f) else { return }
        for d in displays.displays where d.id != display.id {
            if let top = visibleWindows(on: d).first { focus?(top, "12 workspace: switch → focused", eventTime); return }
        }
    }

    private func display(_ uuid: String) -> Display? { displays.displays.first { $0.uuid == uuid } }

    private func mouseDisplay() -> Display? {
        let p = AutoFocusManager.cursor()
        return displays.displays.first { $0.frame.contains(p) } ?? displays.displays.first
    }

    nonisolated private static func existingWindowIDs() -> Set<UInt32> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }
}

/// Collects park results from several app queues.
private final class ParkResults: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(CGWindowID, CGPoint?)] = []
    func add(_ id: CGWindowID, _ p: CGPoint?) { lock.lock(); items.append((id, p)); lock.unlock() }
    var all: [(CGWindowID, CGPoint?)] { lock.lock(); defer { lock.unlock() }; return items }
}
