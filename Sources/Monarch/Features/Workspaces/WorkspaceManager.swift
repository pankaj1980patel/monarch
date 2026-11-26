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
    /// Each display's UUID and frame: a change in either (plugged, unplugged, rearranged)
    /// puts every window back.
    private var arrangement = DisplayArrangement([])
    /// Workspace operations still moving windows, and when the last one finished: focus events
    /// that arrive meanwhile (or just after) are the operation's own, not a Dock click.
    private var opsInFlight = 0
    private var lastOpEnd: Double = 0
    private var restoreWork: DispatchWorkItem?

    static var fileURL: URL {
        ConfigurationStore.url.deletingLastPathComponent().appendingPathComponent("workspaces.json")
    }

    init(engine: WindowEngine, displays: DisplayManager, perf: PerformanceMonitor, bridge: HammerspoonBridge) {
        self.engine = engine
        self.displays = displays
        self.perf = perf
        self.bridge = bridge
        arrangement = DisplayArrangement(Self.signature(displays.displays))

        engine.onRemove { [unowned self] id in
            ops.forget(window: id)
            moves.forget(id)
            if isActive, state.hidden.removeValue(forKey: String(id)) != nil { save() }
        }
        // Moved out of its parking spot by the user or an app (e.g. a layout): no longer parked.
        engine.onUpdate { [unowned self] w in
            // A window on its way back has arrived once it's seen on its target's display.
            // Checked against the window server's live frame: a read that was already old when
            // it arrived must not count as arriving.
            if let target = moves.restoreTarget(w.id), arrived(WindowList.frame(of: w.id) ?? w.frame, at: target) {
                moves.restoreArrived(w.id)
            }
            guard isActive, let e = state.parked(w.id), !moves.isParking(w.id) else { return }
            // Displays changing: macOS moves parked windows around by itself. Not "brought back
            // by hand": the entry stays (a blink back re-parks them; a real change restores all).
            guard restoreWork == nil else { return }
            // Still off screen (where it was parked, or nudged by macOS): stays parked, with its
            // spot updated. Back on screen: brought back by hand, no longer parked.
            switch Parking.update(for: w.frame, entry: e, offScreen: isOffScreen(w.frame)) {
            case .keep: return
            case let .relearn(p): state.hidden[String(w.id)]?.px = p.x; state.hidden[String(w.id)]?.py = p.y
            case .unparked: state.hidden.removeValue(forKey: String(w.id))
            }
            save()
        }
        // A parked window got focus (Dock click, notification, app switch): show its workspace.
        engine.onFocus { [unowned self] id in
            // Not while an operation is moving windows (or just after): those focus changes are
            // its own, however slow the app is to report them.
            guard isActive, opsInFlight == 0, PerformanceMonitor.now() - max(lastSwitch, lastOpEnd) > 0.3,
                  state.isParked(id) || isStranded(id) else { return }
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
        if active {
            load()
            // After apps have been discovered: bring back windows a crash or a lost entry left
            // parked with no workspace that knows them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.rescueParkedOrphans() }
        } else {
            restoreWork?.cancel()                  // inactive: Hammerspoon owns the state now
            restoreWork = nil
            // Without Hammerspoon nobody manages workspaces any more: windows left parked would
            // look lost. Bring them back.
            // Asynchronous: Monarch keeps running, and a hung app mustn't freeze the UI.
            if !Self.hammerspoonRunning, !state.hidden.isEmpty { restoreAll() }
        }
    }

    /// This boot's session id (kern.bootsessionuuid).
    static let bootSession: String? = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }()

    static var hammerspoonRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "org.hammerspoon.Hammerspoon").isEmpty
    }

    /// Monarch is quitting. Hammerspoon, if it runs, takes the parked windows over (it mirrors
    /// workspaces.json); otherwise they're brought back, or they'd stay off screen with nothing
    /// to bring them back. `keepParked`: a restart (rebuild, handover to a newer copy), whose
    /// next copy loads the saved state.
    func prepareForQuit(keepParked: Bool) {
        // Moves still queued (a switch just before quitting) finish first: cut off, a restore
        // left its window off screen with no entry, and a park left an entry for a window on
        // screen.
        if isActive, opsInFlight > 0 || !moves.restoring.isEmpty {
            Log.info(.workspaces, "quit during a switch: waiting for moves in progress")
            drainAppQueues(timeout: 1.5)
        }
        if isActive, keepParked {
            dropEntriesShownOnScreen()
            // Restores that didn't finish: still off screen, and their entries were removed when
            // they started. Keep them on their workspace's display (now showing) for the next copy.
            for (id, target) in moves.restoring where isOffScreen(WindowList.frame(of: id) ?? target) {
                restoreLater(id, to: target)
            }
            save()
        }
        if isActive, !keepParked, !Self.hammerspoonRunning, !state.hidden.isEmpty || !moves.restoring.isEmpty { restoreAllNow(timeout: 2) }
        flushSave()
    }

    /// Waits (at most `timeout`) until every app queue has finished the work queued so far.
    private func drainAppQueues(timeout: Double) {
        let group = DispatchGroup()
        for app in engine.apps.values { app.queue.async(group: group) { @Sendable in } }
        _ = group.wait(timeout: .now() + timeout)
    }

    /// A restore that didn't finish before a restart: an entry on the now-showing workspace of
    /// its target display, so the next copy's launch rescue or a switch can find it.
    private func restoreLater(_ id: CGWindowID, to target: CGRect) {
        guard let d = Geometry.display(for: target, in: displays.displays) ?? displays.displays.first else { return }
        state.hidden[String(id)] = entry(for: target, ws: state.activeWorkspace(d.uuid), display: d, z: 1)
    }

    /// Entries whose window is actually on a display (a park that was cut off, an app that
    /// refused the move): the window shows, so it isn't parked.
    private func dropEntriesShownOnScreen() {
        state.dropShown(shows: { [self] id in WindowList.frame(of: id).map { !isOffScreen($0) } ?? false },
                        moving: { [self] id in moves.isParking(id) })
    }

    /// Every parked window back where it was on its display, waiting (at most `timeout`
    /// seconds) until the apps have moved them: for quitting, when nothing runs afterwards.
    private func restoreAllNow(timeout: Double) {
        let list = displays.displays
        var byApp: [pid_t: [(CGWindowID, CGRect)]] = [:]
        for (k, e) in state.hidden {
            guard let id = UInt32(k), let w = engine.windows[id], let d = display(e.scr) ?? list.first else { continue }
            let target = Parking.fit(e.relativeFrame, into: d.visibleFrame.size)
                .offsetBy(dx: d.visibleFrame.minX, dy: d.visibleFrame.minY)
            byApp[w.pid, default: []].append((id, target))
        }
        // Restores a switch started that haven't arrived (their entries are already gone).
        for (id, target) in moves.restoring where state.hidden[String(id)] == nil {
            if let w = engine.windows[id], isOffScreen(WindowList.frame(of: id) ?? w.frame) { byApp[w.pid, default: []].append((id, target)) }
        }
        let group = DispatchGroup()
        for (pid, restores) in byApp {
            guard let app = engine.apps[pid] else { continue }
            app.queue.async(group: group) { @Sendable in
                for (id, frame) in restores {
                    guard let win = app.element(for: id), let current = AX.frame(win) else { continue }
                    _ = WindowMover.apply(frame, to: win, app: app.element, current: current)
                }
            }
        }
        if group.wait(timeout: .now() + timeout) == .timedOut { Log.error(.workspaces, "quit: some apps didn't move their windows back in time") }
        // Forget only windows now really on screen: one that couldn't be moved (no permission,
        // a hung app) stays parked and known, for the next launch or Hammerspoon.
        for k in Array(state.hidden.keys) {
            guard let id = UInt32(k), let f = WindowList.frame(of: id) else { state.hidden.removeValue(forKey: k); continue }
            if list.contains(where: { FocusLogic.visibleFraction(f, on: $0.frame) >= FocusLogic.minVisibleFraction }) {
                state.hidden.removeValue(forKey: k)
            }
        }
        if state.hidden.isEmpty { state.active.removeAll() }
        Log.notice(.workspaces, "parked windows brought back" + (state.hidden.isEmpty ? "" : "; \(state.hidden.count) couldn't be moved and stay parked"))
        save()
        flushSave()
    }

    // MARK: Persistence

    private func load() {
        if Self.hammerspoonRunning, let imported = HammerspoonBridge.importHammerspoonState() {
            state = imported
        } else if let data = try? Data(contentsOf: Self.fileURL) {
            if let s = try? JSONDecoder().decode(WorkspaceState.self, from: data) {
                state = s
            } else {
                // Unreadable: keep it aside (it may help) rather than overwrite it silently. The
                // windows it knew about are found again by `rescueParkedOrphans`.
                let bad = Self.fileURL.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: bad)
                try? FileManager.default.moveItem(at: Self.fileURL, to: bad)
                Log.error(.workspaces, "workspaces.json unreadable: moved aside to workspaces.json.corrupt")
                hud.toast("workspaces.json was unreadable: windows brought back", on: mouseDisplay())
            }
        }
        // Saved during an earlier boot: its window ids mean other windows now. (Windows left
        // off screen are found again by `rescueParkedOrphans`.)
        let savedBoot = state.boot
        Self.bootSession.map { state.adopt(boot: $0) }
        let oldBoot = state.boot != savedBoot                    // changed (or first recorded): save it
        // Forget windows that closed while Monarch wasn't running. The window server knows
        // every window that exists, so this is exact and needs no waiting for app discovery.
        let alive = Self.existingWindowIDs()
        let before = oldBoot ? -1 : state.hidden.count
        state.hidden = state.hidden.filter { UInt32($0.key).map(alive.contains) ?? false }
        let shown = state.dropShown(shows: { [self] id in WindowList.frame(of: id).map { !isOffScreen($0) } ?? false })
        Log.info(.workspaces, "loaded \(state.hidden.count) parked window(s)"
                 + (state.boot != savedBoot && savedBoot != nil ? " (entries from an earlier boot dropped)" : "")
                 + (shown.isEmpty ? "" : ", \(shown.count) dropped: on screen"))
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
        else if let n = action.gatherAppWorkspace { gatherApp(to: n, eventTime: eventTime) }
        else if action.isRestoreAll { restoreAll(); hud.toast("All windows back", on: mouseDisplay()) }
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

        let live = Live(WindowList.onScreen())
        var parks: [CGWindowID] = []
        for (z, id) in leaving(display, live).enumerated() {
            guard let f = currentFrame(id, live) else { continue }
            state.hidden[String(id)] = entry(for: f, ws: cur, display: display, z: z + 1)
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
        let seq = ops.begin(displays: [uuid], windows: parks + restores.map(\.0))
        Log.info(.workspaces, "#\(seq) switch \(cur) → \(n) on \(display.name): park \(parks.count), restore \(restores.count)")

        run(seq: seq, parks: parks, home: display, restores: restores, focusOn: top, focusSince: eventTime, previous: previous) { [weak self] in
            guard let self else { return }
            self.save()
            let early = self.earlyFocused.removeValue(forKey: seq)
            // A newer operation on this display owns its focus now (this one finished late).
            guard self.ops.isLatest(seq, on: uuid) else { return }
            if let top { if early != top { self.focus?(top, "12 workspace: switch → focused", eventTime) } }
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
        let seq = ops.begin(displays: [d.uuid], windows: [id])
        run(seq: seq, parks: [id], home: d, restores: []) { [weak self] in
            guard let self else { return }
            self.save()
            if self.ops.isLatest(seq, on: d.uuid) { self.focusTopOrNothing(on: d, eventTime: eventTime) }
        }
        hud.flash(on: d, state: state, from: nil, target: n)
    }

    /// ⌃⌥⇧ N: sends every window showing on `display` to its workspace `n`, keeping their
    /// stacking order, on top of the windows already there. The screen stays where it is.
    func sendAll(to n: Int, from display: Display, eventTime: Double) {
        let cur = state.activeWorkspace(display.uuid)
        let live = Live(WindowList.onScreen())
        let ids = leaving(display, live).filter { currentFrame($0, live) != nil }
        guard n != cur, !ids.isEmpty else { hud.flash(on: display, state: state, from: nil, target: nil); return }
        lastSwitch = PerformanceMonitor.now()
        state.makeRoom(ids.count, onTopOf: n, on: display.uuid)
        for (z, id) in ids.enumerated() {
            guard let f = currentFrame(id, live) else { continue }
            state.hidden[String(id)] = entry(for: f, ws: n, display: display, z: z + 1)
        }
        let seq = ops.begin(displays: [display.uuid], windows: ids)
        Log.info(.workspaces, "#\(seq) send all \(ids.count) window(s) on \(display.name) from \(cur) to \(n)")
        run(seq: seq, parks: ids, home: display, restores: []) { [weak self] in
            guard let self else { return }
            self.save()
            if self.ops.isLatest(seq, on: display.uuid) { self.focusTopOrNothing(on: display, eventTime: eventTime) }
            self.perf.record("13 workspace: send all total", since: eventTime)
        }
        hud.flash(on: display, state: state, from: nil, target: n)
    }

    /// ⌃⇧ N: every window of the focused app (on any workspace or display) to workspace `n`
    /// of the focused window's display. If `n` is showing there they all appear there;
    /// otherwise they're all parked on `n` (the screen stays, like ⌥⇧ N).
    func gatherApp(to n: Int, eventTime: Double) {
        guard let fid = engine.focusedID, let fw = engine.windows[fid] else { return }
        let list = displays.displays
        let live = Live(WindowList.onScreen())
        let target: Display
        if let e = state.parked(fid), let d = display(e.scr) { target = d }
        else if let d = currentFrame(fid, live).flatMap({ Geometry.display(for: $0, in: list) }) ?? mouseDisplay() { target = d }
        else { return }
        let active = state.activeWorkspace(target.uuid)

        // The app's windows, top-most first: showing ones in window-server order, then parked
        // ones by their stack position. Minimized windows stay where they are.
        let appWindows = engine.windows.values.filter { $0.pid == fw.pid && !$0.isMinimized && !moves.isParking($0.id) }
        let rank = Dictionary(live.order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var located: [(id: UInt32, location: AppGather.Location, key: Int)] = []
        for w in appWindows {
            if let e = state.parked(w.id) {
                located.append((w.id, .parked(e), 100_000 + e.z))
            } else if let f = currentFrame(w.id, live), !isOffScreen(f), let d = Geometry.display(for: f, in: list) {
                located.append((w.id, .shown(on: d, frame: f), rank[w.id] ?? 50_000))
            }
        }
        located.sort { $0.key < $1.key }
        let plan = AppGather.plan(windows: located.map { ($0.id, $0.location) }, focused: fid,
                                  target: target, workspace: n, active: active)
        let app = engine.apps[fw.pid]?.name ?? "?"
        guard !plan.isEmpty else { hud.flash(on: target, state: state, from: nil, target: n == active ? nil : n); return }
        lastSwitch = PerformanceMonitor.now()
        if plan.parkedOnN > 0 { state.makeRoom(plan.parkedOnN, onTopOf: n, on: target.uuid) }
        for (id, e) in plan.relabel { state.hidden[String(id)] = e }
        for (id, e) in plan.park { state.hidden[String(id)] = e }
        var previous: [CGWindowID: ParkedWindow] = [:]
        for (id, _) in plan.restore { if let e = state.hidden.removeValue(forKey: String(id)) { previous[id] = e } }
        let moved = plan.park.map(\.id) + plan.relabel.map(\.id) + plan.restore.map(\.id)
        let seq = ops.begin(displays: [target.uuid], windows: moved)
        Log.info(.workspaces, "#\(seq) gather \(moved.count) \(app) window(s) on workspace \(n) of \(target.name)"
                 + (n == active ? " (showing)" : " (parked)"))
        run(seq: seq, parks: plan.park.map(\.id), home: target, restores: plan.restore.map { ($0.id, $0.frame) },
            focusOn: n == active ? fid : nil, focusSince: eventTime, previous: previous) { [weak self] in
            guard let self else { return }
            self.save()
            guard self.ops.isLatest(seq, on: target.uuid) else { return }
            if n == active { self.focus?(fid, "12 workspace: gather → focused", eventTime) }
            else { self.focusTopOrNothing(on: target, eventTime: eventTime) }
        }
        if plan.restore.isEmpty && plan.park.isEmpty { save() }          // only relabelled: nothing moves
        hud.flash(on: target, state: state, from: nil, target: n == active ? nil : n)
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
        let seq = ops.begin(displays: [target.uuid], windows: [id])
        if n == state.activeWorkspace(target.uuid) {
            state.hidden.removeValue(forKey: String(id))
            run(seq: seq, parks: [], home: target, restores: [(id, fitted.offsetBy(dx: target.visibleFrame.minX, dy: target.visibleFrame.minY))]) {
                [weak self] in self?.save()
            }
        } else {
            state.hidden[String(id)] = ParkedWindow(ws: n, scr: target.uuid, x: fitted.minX, y: fitted.minY,
                                                    w: fitted.width, h: fitted.height, z: 99)
            run(seq: seq, parks: [id], home: target, restores: []) { [weak self] in self?.save() }
        }
    }

    /// Shows the workspace holding window `id` and focuses it.
    func reveal(_ id: CGWindowID, eventTime: Double = PerformanceMonitor.now()) {
        guard let e = state.parked(id) else {
            if isStranded(id) { rescue(id, eventTime: eventTime) } else { focus?(id, "12 workspace: reveal → focused", eventTime) }
            return
        }
        let live = WindowList.frame(of: id) ?? engine.windows[id]?.frame
        // Back on screen by hand: just forget it. (Not while its park is still on the way: it
        // hasn't left the screen yet.)
        if let f = live, !isOffScreen(f), !moves.isParking(id) {
            state.hidden.removeValue(forKey: String(id))
            save()
            focus?(id, "12 workspace: reveal → focused", eventTime)
            return
        }
        if let d = display(e.scr), e.ws == state.activeWorkspace(e.scr), !moves.isParking(id) {
            // Its workspace is already showing (a restore that failed, an entry left behind):
            // switching would do nothing and focus a window nobody can see. Bring it back.
            state.hidden.removeValue(forKey: String(id))
            let seq = ops.begin(displays: [d.uuid], windows: [id])
            run(seq: seq, parks: [], home: d, restores: [(id, Parking.fit(e.relativeFrame, into: d.visibleFrame.size)
                .offsetBy(dx: d.visibleFrame.minX, dy: d.visibleFrame.minY))], previous: [id: e]) { [weak self] in
                self?.save()
                self?.focus?(id, "12 workspace: reveal → focused", eventTime)
            }
        } else if let d = display(e.scr) {
            switchTo(e.ws, on: d, focusID: id, eventTime: eventTime)
        } else if let d = displays.displays.first {            // its display is gone: bring it here
            state.hidden.removeValue(forKey: String(id))
            let seq = ops.begin(displays: [d.uuid], windows: [id])
            run(seq: seq, parks: [], home: d, restores: [(id, Parking.fit(e.relativeFrame, into: d.visibleFrame.size)
                .offsetBy(dx: d.visibleFrame.minX, dy: d.visibleFrame.minY))]) { [weak self] in
                self?.save()
                self?.focus?(id, "12 workspace: reveal → focused", eventTime)
            }
        }
    }

    /// The display a window belongs to while it's off screen: its parked entry's, or the one
    /// a restore in flight is taking it to.
    func homeDisplayID(of id: CGWindowID) -> UInt32? {
        let screens = displays.displays
        if let e = state.parked(id) { return screens.first { $0.uuid == e.scr }?.id }
        if let t = moves.restoreTarget(id) { return Geometry.display(for: t, in: screens)?.id }
        return nil
    }

    /// Off screen with no workspace that knows it (an entry lost to a bug or a crash).
    func isStranded(_ id: CGWindowID) -> Bool {
        guard let w = engine.windows[id] else { return false }
        return WorkspaceSwitch.isStranded(parked: state.isParked(id), moving: moves.isParking(id) || moves.restoreTarget(id) != nil,
                                          minimized: w.isMinimized, frame: WindowList.frame(of: id) ?? w.frame,
                                          displays: displays.displays)
    }

    /// Brings a stranded window onto the current workspace of the display under the mouse
    /// (near its top-left, at its own size) and focuses it.
    private func rescue(_ id: CGWindowID, eventTime: Double) {
        Log.notice(.workspaces, "picked \(who(id)), stranded off screen with no workspace: brought back")
        guard let w = engine.windows[id], let d = mouseDisplay() else { return }
        let rel = CGRect(x: 40, y: 40, width: w.frame.width, height: w.frame.height)
        let frame = Parking.fit(rel, into: d.visibleFrame.size).offsetBy(dx: d.visibleFrame.minX, dy: d.visibleFrame.minY)
        lastSwitch = PerformanceMonitor.now()
        let seq = ops.begin(displays: [d.uuid], windows: [id])
        run(seq: seq, parks: [], home: d, restores: [(id, frame)], focusOn: id, focusSince: eventTime) { [weak self] in
            guard let self else { return }
            self.save()
            if self.earlyFocused.removeValue(forKey: seq) != id { self.focus?(id, "12 workspace: reveal → focused", eventTime) }
        }
    }

    /// A restore onto the showing workspace failed (a busy app): one more try after a second.
    private func retryRestore(_ id: CGWindowID, entry e: ParkedWindow) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.isStranded(id), let d = self.display(e.scr) ?? self.displays.displays.first else { return }
            let frame = Parking.fit(e.relativeFrame, into: d.visibleFrame.size).offsetBy(dx: d.visibleFrame.minX, dy: d.visibleFrame.minY)
            let seq = self.ops.begin(displays: [], windows: [id])
            self.run(seq: seq, parks: [], home: d, restores: [(id, frame)]) { [weak self] in self?.save() }
        }
    }

    /// Windows stuck where Monarch parks windows, with no entry (a crash between moving and
    /// saving, a lost entry, an unreadable workspaces.json): back onto the showing workspace.
    func rescueParkedOrphans() {
        guard isActive else { return }
        let list = displays.displays
        var restores: [(CGWindowID, CGRect)] = []
        for w in engine.windows.values where isStranded(w.id) {
            let f = WindowList.frame(of: w.id) ?? w.frame
            guard Parking.looksParked(f, displays: list), let d = mouseDisplay() else { continue }
            let rel = CGRect(x: 40, y: 40, width: f.width, height: f.height)
            restores.append((w.id, Parking.fit(rel, into: d.visibleFrame.size).offsetBy(dx: d.visibleFrame.minX, dy: d.visibleFrame.minY)))
        }
        // Entries on the workspace that is showing (a restore cut off by a quit or restart):
        // parked where nobody can switch to them. Back to their own place.
        var previous: [CGWindowID: ParkedWindow] = [:]
        let stuck = state.takeOnShowingWorkspace { [self] id in
            engine.windows[id] != nil && !moves.isParking(id) && state.parked(id).flatMap { display($0.scr) } != nil
        }
        for (id, e) in stuck {
            guard let d = display(e.scr) else { continue }
            previous[id] = e
            restores.append((id, Parking.fit(e.relativeFrame, into: d.visibleFrame.size).offsetBy(dx: d.visibleFrame.minX, dy: d.visibleFrame.minY)))
        }
        guard !restores.isEmpty, let home = list.first else { return }
        Log.notice(.workspaces, "launch rescue: \(restores.count - stuck.count) window(s) stranded off screen, \(stuck.count) parked on the showing workspace: brought back")
        let seq = ops.begin(displays: [], windows: restores.map(\.0))
        run(seq: seq, parks: [], home: home, restores: restores, previous: previous) { [weak self] in self?.save() }
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
        for w in engine.windows.values where !parkedIDs.contains(w.id) && isStranded(w.id) {      // skips windows being moved
            guard let d = Geometry.display(for: w.frame, in: list) ?? list.first else { continue }
            let rel = CGRect(x: 40, y: 40, width: w.frame.width, height: w.frame.height)
            restores.append((w.id, Parking.fit(rel, into: d.visibleFrame.size)
                .offsetBy(dx: d.visibleFrame.minX, dy: d.visibleFrame.minY)))
        }
        Log.notice(.workspaces, "restore all: \(restores.count) window(s) back, every display on workspace 1")
        state.hidden.removeAll()
        state.active.removeAll()
        guard let home = list.first else { save(); return }
        let seq = ops.begin(displays: list.map(\.uuid), windows: restores.map(\.0))
        run(seq: seq, parks: [], home: home, restores: restores, previous: previous) { [weak self] in self?.save() }
        if restores.isEmpty { save() }
    }

    /// Display plugged in or out: bring everything back (like the Hammerspoon setup did),
    /// after the arrangement has settled.
    func displaysChanged() {
        let now = Self.signature(displays.displays)
        guard isActive else { arrangement.accept(now); return }    // Hammerspoon owns the state while inactive
        let wasPending = restoreWork != nil
        restoreWork?.cancel()
        restoreWork = nil
        guard arrangement.changed(to: now) == .scheduleRestore else {
            // Blinked back: nothing changed. Windows macOS pulled on screen meanwhile go back.
            if wasPending { Log.notice(.displays, "displays back as before: workspaces kept"); reparkShownLater() }
            return
        }
        Log.notice(.displays, "displays changed (\(displays.displays.count) now): restoring windows in 2 s unless they come back")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            self.restoreWork = nil
            guard self.arrangement.settle(Self.signature(self.displays.displays)), !self.state.hidden.isEmpty else { return }
            Log.notice(.displays, "display change settled: bringing every window back")
            self.restoreAll()
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// After a display blink: parked windows macOS moved onto a display are parked again,
    /// once it has finished moving things (1 s).
    private func reparkShownLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.isActive, self.restoreWork == nil else { return }
            var byDisplay: [String: [CGWindowID]] = [:]
            for (k, e) in self.state.hidden {
                guard let id = UInt32(k), self.engine.windows[id] != nil, !self.moves.isParking(id),
                      let f = WindowList.frame(of: id), !self.isOffScreen(f) else { continue }
                byDisplay[e.scr, default: []].append(id)
            }
            for (uuid, ids) in byDisplay {
                guard let d = self.display(uuid) else { continue }
                let seq = self.ops.begin(displays: [], windows: ids)
                self.run(seq: seq, parks: ids, home: d, restores: []) { [weak self] in self?.save() }
            }
        }
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
    ///
    /// `seq` is the operation's number (`ops.begin`): results for a window that a newer
    /// operation has moved since are dropped, and the early focus happens only if no newer
    /// operation has started on `home`.
    private func run(seq: Int, parks: [CGWindowID], home: Display, restores: [(CGWindowID, CGRect)],
                     focusOn: CGWindowID? = nil, focusSince: Double = 0, previous: [CGWindowID: ParkedWindow] = [:],
                     done: @escaping () -> Void) {
        // Saved before anything moves: a crash mid-operation then still knows every parked
        // window (writes are coalesced and off the main thread, so this costs nothing extra).
        save()
        opsInFlight += 1
        var byApp: [pid_t: (parks: [(CGWindowID, CGSize)], restores: [(CGWindowID, CGRect)])] = [:]
        for id in parks { if let w = engine.windows[id] { byApp[w.pid, default: ([], [])].parks.append((id, w.frame.size)) } }
        for r in restores { if let w = engine.windows[r.0] { byApp[w.pid, default: ([], [])].restores.append(r) } }

        let group = DispatchGroup()
        let screens = displays.displays
        let results = ParkResults()
        let focusPID = focusOn.flatMap { engine.windows[$0]?.pid }
        let focusEarly: (@Sendable () -> Void)?
        if let id = focusOn {
            let uuid = home.uuid
            focusEarly = { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.earlyFocus(id, seq: seq, on: uuid, since: focusSince) } }
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
                    let outcome = Self.park(win, id: id, size: size, home: home, displays: screens)
                    if case .notMoved = outcome, PerformanceMonitor.now() - t > Self.hungAfter { hung = true }
                    results.add(id, outcome)
                }
            }
        }

        for (id, _) in byApp.values.flatMap(\.parks) { moves.parkStarted(id) }
        for (id, frame) in byApp.values.flatMap(\.restores) { moves.restoreStarted(id, to: frame, seq: seq) }
        var finished = false
        let finish: @MainActor (_ final: Bool) -> Void = { [weak self] final in
            guard let self else { return }
            for (id, outcome) in results.takeAll() {
                let key = String(id)
                self.moves.parkFinished(id)
                // A newer operation moved this window since: its entry is that operation's.
                guard self.ops.isLatest(seq, for: id) else { continue }
                switch outcome {
                case let .at(spot): self.state.hidden[key]?.px = spot.x; self.state.hidden[key]?.py = spot.y
                case .movedUnread: break     // it did move: stays parked; the spot is learned from its next frame
                case .notMoved:
                    if self.state.hidden.removeValue(forKey: key) != nil {
                        Log.error(.workspaces, "#\(seq) couldn't park \(self.who(id)): stays on screen")
                    }
                }
            }
            // A restored window stays "on its way" until it's seen on screen (onUpdate, or the
            // live window list in `leaving`). This is only the safety net for one never seen.
            let restoredNow = results.takeDoneRestores()
            if !restoredNow.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + MovesInFlight.restoreSafetyNet) { [weak self] in
                    MainActor.assumeIsolated { for id in restoredNow { self?.moves.restoreExpired(id, seq: seq) } }
                }
            }
            for id in results.takeFailedRestores() {
                Log.error(.workspaces, "#\(seq) couldn't restore \(self.who(id)) (app busy, hung or window gone)")
                self.moves.restoreExpired(id, seq: seq)                      // it didn't move: not on its way
                guard self.ops.isLatest(seq, for: id) else { continue }       // a newer operation decided since
                guard let e = previous[id] else { continue }
                if e.ws == self.state.activeWorkspace(e.scr) {
                    // Its workspace is the one showing: parked there, no switch would ever bring
                    // it back. Try once more shortly; if that fails too it's stranded, and
                    // picking it (⌘Tab, Dock) brings it back.
                    self.retryRestore(id, entry: e)
                } else {
                    self.state.hidden[String(id)] = e                          // still parked: keep it findable
                }
            }
            if final { self.opsInFlight -= 1; self.lastOpEnd = PerformanceMonitor.now() }
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
    /// The window each operation focused early (by operation number), so its `done` doesn't
    /// focus it again.
    private var earlyFocused: [Int: CGWindowID] = [:]
    private var ops = OperationSequence()

    /// Focuses an operation's top window as soon as it's back, unless a newer operation has
    /// started on that display since (it would focus a window the newer one just parked).
    private func earlyFocus(_ id: CGWindowID, seq: Int, on uuid: String, since: Double) {
        guard ops.isLatest(seq, on: uuid) else { return }
        earlyFocused[seq] = id
        focus?(id, "12 workspace: switch → focused", since)
    }

    /// Parks one window off a corner of `home`; returns where macOS actually put it.
    /// `size` comes from the engine's cache (no round trip). App queue only.
    nonisolated private static func park(_ win: AXUIElement, id: CGWindowID, size: CGSize, home: Display, displays: [Display]) -> ParkOutcome {
        var outcome = ParkOutcome.notMoved
        for spot in Parking.spots(for: size, screen: home.frame) {
            guard AX.setPoint(win, spot) else {
                // Refused, or a busy app answered too late (a timeout reads as a failure though
                // the move happened). Ask the window server where the window really is.
                if case .notMoved = outcome, let f = WindowList.frame(of: id),
                   !displays.contains(where: { FocusLogic.visibleFraction(f, on: $0.frame) >= FocusLogic.minVisibleFraction }) {
                    outcome = .at(f.origin)
                }
                break
            }
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

    /// The window server's on-screen windows and frames, front to back (fetched once per
    /// operation and shared by every display it looks at).
    struct Live {
        let order: [UInt32]
        let frames: [UInt32: CGRect]
        init(_ list: [(id: UInt32, frame: CGRect)]) {
            order = list.map(\.id)
            frames = Dictionary(list.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// A window's frame right now: where a restore in flight is taking it, else where the window
    /// server has it, else Monarch's own (possibly lagging) copy.
    private func currentFrame(_ id: CGWindowID, _ live: Live) -> CGRect? {
        guard let w = engine.windows[id] else { return nil }
        return moves.restoreTarget(id) ?? live.frames[id] ?? w.frame
    }

    /// Seen on the display its restore was taking it to.
    private func arrived(_ frame: CGRect, at target: CGRect) -> Bool {
        let screens = displays.displays
        guard let d = Geometry.display(for: target, in: screens) else { return true }
        return Geometry.display(for: frame, in: screens)?.id == d.id
            && FocusLogic.visibleFraction(frame, on: d.frame) >= FocusLogic.minVisibleFraction
    }

    /// Windows on `display` for a workspace operation or the overview: those showing there and
    /// those still being restored there (see `WorkspaceSwitch.leaving`). Restores the window
    /// server already shows on screen are marked arrived.
    private func leaving(_ display: Display, _ live: Live) -> [CGWindowID] {
        for (id, target) in moves.restoring {
            if let f = live.frames[id], arrived(f, at: target) { moves.restoreArrived(id) }
        }
        let screens = displays.displays
        return WorkspaceSwitch.leaving(visible: visibleWindows(on: display, live: live), restoring: moves.restoring,
                                       isParked: { self.state.isParked($0) },
                                       displayOf: { Geometry.display(for: $0, in: screens)?.id }, display: display.id)
    }

    /// Every window on `display` right now, top-most first, including windows still on their
    /// way back from a switch that just happened (the overview shows them where they're going).
    func shownWindows(on display: Display, live: Live) -> [CGWindowID] { leaving(display, live) }

    /// Windows showing on `display`, top-most first, from the window server's live frames.
    func visibleWindows(on display: Display, live: Live? = nil) -> [CGWindowID] {
        let live = live ?? Live(WindowList.onScreen())
        let screens = displays.displays
        return live.order.filter { id in
            guard let w = engine.windows[id], !w.isMinimized, !engine.hiddenPIDs.contains(w.pid), !state.isParked(id)
            else { return false }
            let f = live.frames[id] ?? w.frame
            return Geometry.display(for: f, in: screens)?.id == display.id
                && FocusLogic.visibleFraction(f, on: display.frame) >= FocusLogic.minVisibleFraction
        }
    }

    /// After a switch or send: focus the top window left on that display. If there is none and
    /// focus is still on a now-parked window, move focus to the top window elsewhere so keys
    /// don't go to something hidden.
    private func focusTopOrNothing(on display: Display, eventTime: Double) {
        let live = Live(WindowList.onScreen())                 // after the moves: fetch fresh, once
        if let top = visibleWindows(on: display, live: live).first { focus?(top, "12 workspace: switch → focused", eventTime); return }
        guard let f = engine.focusedID, state.isParked(f) else { return }
        for d in displays.displays where d.id != display.id {
            if let top = visibleWindows(on: d, live: live).first { focus?(top, "12 workspace: switch → focused", eventTime); return }
        }
    }

    /// "1234 (Safari)" for logs: window id and app name, never the title.
    private func who(_ id: CGWindowID) -> String {
        "\(id) (\(engine.windows[id].flatMap { engine.apps[$0.pid]?.name } ?? "?"))"
    }

    private func display(_ uuid: String) -> Display? { displays.displays.first { $0.uuid == uuid } }

    private static func signature(_ list: [Display]) -> Set<String> {
        Set(list.map { "\($0.uuid)@\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width)),\(Int($0.frame.height))" })
    }

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
