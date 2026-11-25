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
            guard isActive, let e = state.parked(w.id), !moves.isParking(w.id) else { return }
            if e.px == nil {
                // Parked, but its spot was never read back: learn it from this frame if the
                // window is still off screen; if it's back on screen, it's no longer parked.
                if isOffScreen(w.frame) {
                    state.hidden[String(w.id)]?.px = w.frame.minX
                    state.hidden[String(w.id)]?.py = w.frame.minY
                } else {
                    state.hidden.removeValue(forKey: String(w.id))
                }
                save()
                return
            }
            guard !Parking.isAtPark(w.frame, e) else { return }
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

    /// Encodes on main (the state is small), writes on a background queue so a slow disk never
    /// delays the HUD or the focus change. Writes that come in quick succession collapse into
    /// one: only the newest state is written. Listeners of the file are told after it's written.
    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(state) { Self.writer.write(data, to: Self.fileURL) { [weak self] in self?.bridge.stateChanged() } }
        onChange?()
    }

    private static let writer = StateWriter()

    /// Waits for a queued write (on quit, so the last switch isn't lost).
    func flushSave() { Self.writer.flush() }

    // MARK: Commands

    func perform(_ action: Action, eventTime: Double) {
        if let n = action.switchWorkspace, let d = mouseDisplay() { switchTo(n, on: d, eventTime: eventTime) }
        else if let n = action.moveWorkspace { moveFocused(to: n, eventTime: eventTime) }
        else if let n = action.sendAllWorkspace, let d = mouseDisplay() { sendAll(to: n, from: d, eventTime: eventTime) }
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
        for (z, id) in leaving(display).enumerated() {
            guard let w = engine.windows[id] else { continue }
            state.hidden[String(id)] = entry(for: moves.restoreTarget(id) ?? w.frame, ws: cur, display: display, z: z + 1)
            parks.append(id)
        }
        var restores: [(CGWindowID, CGRect)] = []
        var previous: [CGWindowID: ParkedWindow] = [:]
        for (id, e) in state.incoming(n, on: uuid) {
            state.hidden.removeValue(forKey: String(id))
            previous[id] = e
            restores.append((id, e.relativeFrame.offsetBy(dx: display.visibleFrame.minX, dy: display.visibleFrame.minY)))
        }
        state.active[uuid] = n
        let top = focusID ?? restores.last?.0
        earlyFocused = nil
        earlyFocusTime = eventTime

        run(parks: parks, home: display, restores: restores, focusOn: top, previous: previous) { [weak self] in
            guard let self else { return }
            self.save()
            if let top { if self.earlyFocused != top { self.focus?(top, "12 workspace: switch → focused", eventTime) } }
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
        state.hidden[String(id)] = entry(for: moves.restoreTarget(id) ?? w.frame, ws: n, display: d, z: 0)
        run(parks: [id], home: d, restores: []) { [weak self] in
            self?.save()
            self?.focusTopOrNothing(on: d, eventTime: eventTime)
        }
        hud.flash(on: d, state: state, from: nil, target: n)
    }

    /// ⌃⌥⇧ N: sends every window showing on `display` to its workspace `n`, keeping their
    /// stacking order, on top of the windows already there. The screen stays where it is.
    func sendAll(to n: Int, from display: Display, eventTime: Double) {
        let cur = state.activeWorkspace(display.uuid)
        let ids = leaving(display).filter { engine.windows[$0] != nil }
        guard n != cur, !ids.isEmpty else { hud.flash(on: display, state: state, from: nil, target: nil); return }
        lastSwitch = PerformanceMonitor.now()
        state.makeRoom(ids.count, onTopOf: n, on: display.uuid)
        for (z, id) in ids.enumerated() {
            guard let w = engine.windows[id] else { continue }
            state.hidden[String(id)] = entry(for: moves.restoreTarget(id) ?? w.frame, ws: n, display: display, z: z + 1)
        }
        run(parks: ids, home: display, restores: []) { [weak self] in
            guard let self else { return }
            self.save()
            self.focusTopOrNothing(on: display, eventTime: eventTime)
            self.perf.record("13 workspace: send all total", since: eventTime)
        }
        hud.flash(on: display, state: state, from: nil, target: n)
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
        var previous: [CGWindowID: ParkedWindow] = [:]
        let list = displays.displays
        for (k, e) in state.hidden {
            guard let id = UInt32(k), let d = display(e.scr) ?? list.first else { continue }
            previous[id] = e
            restores.append((id, Parking.fit(e.relativeFrame, into: d.visibleFrame.size)
                .offsetBy(dx: d.visibleFrame.minX, dy: d.visibleFrame.minY)))
        }
        // Also rescue windows left off screen without a parked entry (a lost park, a crash):
        // ⌃⌥⇧ 0 means "every window back", whatever the saved state says.
        let parkedIDs = Set(previous.keys)
        for w in engine.windows.values where !parkedIDs.contains(w.id) && !w.isMinimized && isOffScreen(w.frame) {
            guard let d = Geometry.display(for: w.frame, in: list) ?? list.first else { continue }
            let rel = CGRect(x: 40, y: 40, width: w.frame.width, height: w.frame.height)
            restores.append((w.id, Parking.fit(rel, into: d.visibleFrame.size)
                .offsetBy(dx: d.visibleFrame.minX, dy: d.visibleFrame.minY)))
        }
        state.hidden.removeAll()
        state.active.removeAll()
        guard let home = list.first else { save(); return }
        run(parks: [], home: home, restores: restores, previous: previous) { [weak self] in self?.save() }
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
    ///
    /// - `focusOn`: focused as soon as its own app has restored it, not after every app is done.
    /// - `previous`: parked entries of the windows being restored, put back if a restore fails.
    /// - A hung app costs at most one timeout: after an AX call that times out, the rest of
    ///   that app's windows are skipped (parks are dropped from the state, restores stay parked).
    /// - `done` runs when every app is finished or after 1 s, whichever is first, so one slow
    ///   app can't hold up the HUD, the focus or the save. Late results are applied (and saved)
    ///   when they arrive.
    private func run(parks: [CGWindowID], home: Display, restores: [(CGWindowID, CGRect)],
                     focusOn: CGWindowID? = nil, previous: [CGWindowID: ParkedWindow] = [:],
                     done: @escaping () -> Void) {
        var byApp: [pid_t: (parks: [(CGWindowID, CGSize)], restores: [(CGWindowID, CGRect)])] = [:]
        for id in parks { if let w = engine.windows[id] { byApp[w.pid, default: ([], [])].parks.append((id, w.frame.size)) } }
        for r in restores { if let w = engine.windows[r.0] { byApp[w.pid, default: ([], [])].restores.append(r) } }

        let group = DispatchGroup()
        let screens = displays.displays
        let results = ParkResults()
        let focusPID = focusOn.flatMap { engine.windows[$0]?.pid }
        let focusEarly: (@Sendable () -> Void)?
        if let id = focusOn {
            focusEarly = { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.earlyFocus(id) } }
            }
        } else {
            focusEarly = nil
        }
        for (pid, work) in byApp {
            guard let app = engine.apps[pid] else {
                for (id, _) in work.parks { results.add(id, .notMoved) }    // app gone: nothing parked
                for (id, _) in work.restores { results.restoreDone(id) }
                continue
            }
            let isFocusApp = pid == focusPID
            app.queue.async(group: group) { @Sendable in
                var hung = false
                // Restores first: they're what the user is waiting to see.
                for (id, frame) in work.restores {
                    defer { results.restoreDone(id) }
                    if hung { results.failedRestore(id); continue }
                    let t = PerformanceMonitor.now()
                    guard let win = app.element(for: id), let current = AX.frame(win) else {
                        hung = PerformanceMonitor.now() - t > Self.hungAfter
                        results.failedRestore(id)
                        continue
                    }
                    WindowMover.apply(frame, to: win, app: app.element, current: current)
                }
                if isFocusApp { focusEarly?() }
                for (id, size) in work.parks {
                    // Not moved (missing element, full screen, hung app): not parked either.
                    guard !hung, let win = app.element(for: id) else { results.add(id, .notMoved); continue }
                    let t = PerformanceMonitor.now()
                    // macOS full-screen windows live in their own Space: leave them alone.
                    if AX.bool(win, "AXFullScreen") == true { results.add(id, .notMoved); continue }
                    let outcome = Self.park(win, size: size, home: home, displays: screens)
                    if case .notMoved = outcome, PerformanceMonitor.now() - t > Self.hungAfter { hung = true }
                    results.add(id, outcome)
                }
            }
        }

        for (id, _) in byApp.values.flatMap(\.parks) { moves.parkStarted(id) }
        for (id, frame) in byApp.values.flatMap(\.restores) { moves.restoreStarted(id, to: frame) }
        var finished = false
        let finish: @MainActor (_ final: Bool) -> Void = { [weak self] final in
            guard let self else { return }
            for (id, outcome) in results.takeAll() {
                let key = String(id)
                self.moves.parkFinished(id)
                switch outcome {
                case let .at(spot): self.state.hidden[key]?.px = spot.x; self.state.hidden[key]?.py = spot.y
                case .movedUnread: break     // it did move: stays parked; the spot is learned from its next frame
                case .notMoved: self.state.hidden.removeValue(forKey: key)
                }
            }
            // The engine reads the restored frame a moment after the move (frame reads are
            // throttled to 50 ms): until then the window still looks parked to it, so its
            // destination stays known a little longer.
            let restoredNow = results.takeDoneRestores()
            if !restoredNow.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    MainActor.assumeIsolated { for id in restoredNow { self?.moves.restoreFinished(id) } }
                }
            }
            for id in results.takeFailedRestores() {
                if let e = previous[id] { self.state.hidden[String(id)] = e }  // still parked: keep it findable
            }
            if !finished { finished = true; done() }
            else if final { self.save() }                                 // late results after the deadline
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { finish(true) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.deadline) {
            MainActor.assumeIsolated { if !finished { finish(false) } }
        }
    }

    /// An AX call that took longer than this failed by timing out: the app is hung.
    nonisolated private static let hungAfter = 0.2
    /// Longest a workspace operation waits before finishing without a slow app.
    private static let deadline = 1.0
    /// The window `run` focused early, so `done` doesn't focus it again.
    private var earlyFocused: CGWindowID?
    private var earlyFocusTime: Double = 0

    private func earlyFocus(_ id: CGWindowID) {
        earlyFocused = id
        focus?(id, "12 workspace: switch → focused", earlyFocusTime)
    }

    /// Parks one window off a corner of `home`; returns where macOS actually put it.
    /// `size` comes from the engine's cache (no round trip). App queue only.
    nonisolated private static func park(_ win: AXUIElement, size: CGSize, home: Display, displays: [Display]) -> ParkOutcome {
        var outcome = ParkOutcome.notMoved
        for spot in Parking.spots(for: size, screen: home.frame) {
            guard AX.setPoint(win, spot) else { break }                    // the app refused the move
            // The move went through. If the app doesn't answer the read-back (Chrome often
            // doesn't, right after a move), the window is still parked: never forget it.
            guard let actual = AX.point(win) else {
                if case .notMoved = outcome { outcome = .movedUnread }
                break
            }
            outcome = .at(actual)
            if !Parking.overlapsOther(CGRect(origin: actual, size: size), home: home.id, displays: displays) { break }
        }
        return outcome
    }

    /// Parks and restores started but not finished (fast ⌥ N presses overlap them).
    private var moves = MovesInFlight()

    // MARK: Helpers

    private func entry(for frame: CGRect, ws: Int, display: Display, z: Int) -> ParkedWindow {
        let v = display.visibleFrame
        return ParkedWindow(ws: ws, scr: display.uuid, x: frame.minX - v.minX, y: frame.minY - v.minY,
                            w: frame.width, h: frame.height, z: z)
    }

    /// Windows leaving `display` when it changes workspace: those showing there and those still
    /// being restored there by the previous switch (see `WorkspaceSwitch.leaving`).
    private func leaving(_ display: Display) -> [CGWindowID] {
        let screens = displays.displays
        return WorkspaceSwitch.leaving(visible: visibleWindows(on: display), restoring: moves.restoring,
                                       isParked: { self.state.isParked($0) },
                                       displayOf: { Geometry.display(for: $0, in: screens)?.id }, display: display.id)
    }

    /// Windows showing on `display`, top-most first. Pass `zOrder` when asking for several
    /// displays in one operation, so the window list is fetched once.
    func visibleWindows(on display: Display, zOrder: [UInt32]? = nil) -> [CGWindowID] {
        let screens = displays.displays
        return (zOrder ?? AutoFocusManager.zOrder()).filter { id in
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
        let z = AutoFocusManager.zOrder()                        // after the moves: fetch fresh, once
        if let top = visibleWindows(on: display, zOrder: z).first { focus?(top, "12 workspace: switch → focused", eventTime); return }
        guard let f = engine.focusedID, state.isParked(f) else { return }
        for d in displays.displays where d.id != display.id {
            if let top = visibleWindows(on: d, zOrder: z).first { focus?(top, "12 workspace: switch → focused", eventTime); return }
        }
    }

    private func display(_ uuid: String) -> Display? { displays.displays.first { $0.uuid == uuid } }

    /// Almost entirely off every display (where parking puts windows).
    private func isOffScreen(_ frame: CGRect) -> Bool {
        !displays.displays.contains { FocusLogic.visibleFraction(frame, on: $0.frame) >= FocusLogic.minVisibleFraction }
    }

    private func mouseDisplay() -> Display? {
        let p = AutoFocusManager.cursor()
        return displays.displays.first { $0.frame.contains(p) } ?? displays.displays.first
    }

    nonisolated private static func existingWindowIDs() -> Set<UInt32> { WindowList.existingIDs() }
}

/// Background, coalescing writer for workspaces.json.
private final class StateWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "monarch.workspaces.save", qos: .utility)
    private let lock = NSLock()
    private var pending: Data?

    /// `written` runs on main after the newest data is on disk.
    func write(_ data: Data, to url: URL, written: @escaping @MainActor () -> Void) {
        lock.lock()
        let scheduled = pending != nil
        pending = data
        lock.unlock()
        guard !scheduled else { return }                       // a write is already queued: it takes the newest
        queue.async { [self] in
            lock.lock(); let d = pending; pending = nil; lock.unlock()
            guard let d else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: url, options: .atomic)
            DispatchQueue.main.async { MainActor.assumeIsolated { written() } }
        }
    }

    /// Blocks until queued writes are on disk.
    func flush() { queue.sync {} }
}

/// What parking one window did.
enum ParkOutcome: Sendable {
    /// Moved, and macOS reports it here.
    case at(CGPoint)
    /// Moved, but the app didn't answer where it ended up.
    case movedUnread
    /// Not moved (refused, missing, full screen, hung app).
    case notMoved
}

/// Collects park results from several app queues.
private final class ParkResults: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(CGWindowID, ParkOutcome)] = []
    private var failed: [CGWindowID] = []
    private var restored: [CGWindowID] = []
    /// A restore was attempted (moved or failed): it's no longer in flight.
    func restoreDone(_ id: CGWindowID) { lock.lock(); restored.append(id); lock.unlock() }
    func takeDoneRestores() -> [CGWindowID] { lock.lock(); defer { restored.removeAll(); lock.unlock() }; return restored }
    func add(_ id: CGWindowID, _ o: ParkOutcome) { lock.lock(); items.append((id, o)); lock.unlock() }
    func failedRestore(_ id: CGWindowID) { lock.lock(); failed.append(id); lock.unlock() }
    /// Results so far, each handed out once (the deadline and the final pass both read them).
    func takeAll() -> [(CGWindowID, ParkOutcome)] { lock.lock(); defer { items.removeAll(); lock.unlock() }; return items }
    func takeFailedRestores() -> [CGWindowID] { lock.lock(); defer { failed.removeAll(); lock.unlock() }; return failed }
}
