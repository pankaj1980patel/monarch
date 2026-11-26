import AppKit
import MonarchCore

/// ⌘Tab / ⌘` window switcher.
///
/// - ⌘Tab: every window on both screens and all workspaces, most recently used first.
///   A quick tap toggles between the last two windows without showing the panel.
/// - ⌘`: only the current workspace of the screen under the mouse.
/// - While ⌘ is held: Tab / ⇧Tab and ← / → move (holding Tab keeps moving), ↩ picks,
///   ⎋ cancels, hover selects, click picks, click outside cancels. Releasing ⌘ picks.
/// - Only the picked window comes forward. A window on a hidden workspace first has its
///   workspace revealed (by Hammerspoon until step 6).
///
/// No keyboard tap: ⌘Tab etc. are Carbon hotkeys, the in-panel keys are temporary Carbon
/// hotkeys that exist only while the panel is open, and ⌘ release is seen by a flags monitor
/// that also exists only while open.
@MainActor
final class SwitcherController {
    static let showDelay = 0.12

    private let engine: WindowEngine
    private let displays: DisplayManager
    private let autoFocus: AutoFocusManager
    private let hotkeys: HotkeyManager
    private let workspaceManager: WorkspaceManager
    private let perf: PerformanceMonitor
    private let panel = SwitcherPanel()          // built once, kept hidden

    private var list: [CGWindowID]?
    private var index = 0
    private var workspaces = WorkspaceState()
    private var showWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private var openedAt: Double = 0
    private var repeatWork: DispatchWorkItem?
    /// Watches ⌘ while the panel is open. The flags monitor misses its release during Secure
    /// Input (a password field has the keyboard): the panel then stayed open and swallowed ⌘-keys.
    private var commandWatch: Timer?

    init(engine: WindowEngine, displays: DisplayManager, autoFocus: AutoFocusManager,
         hotkeys: HotkeyManager, workspaces: WorkspaceManager, perf: PerformanceMonitor) {
        self.engine = engine
        self.displays = displays
        self.autoFocus = autoFocus
        self.hotkeys = hotkeys
        self.workspaceManager = workspaces
        self.perf = perf
        panel.prewarm()
        panel.onHover = { [unowned self] i in index = i; panel.select(i) }
        panel.onClick = { [unowned self] i in index = i; finish(commit: true) }
    }

    var isOpen: Bool { list != nil }

    func perform(_ action: Action, eventTime: Double) {
        let step = (action == .switcherPrevious || action == .switcherWorkspacePrevious) ? -1 : 1
        let workspaceOnly = action == .switcherWorkspaceNext || action == .switcherWorkspacePrevious

        // ⌘ was released but we missed it: pick, then treat this press as a fresh open.
        if list != nil && !Self.commandDown() { finish(commit: true) }
        if let list {
            index = SwitcherLogic.move(index, by: step, count: list.count)
            panel.select(index)
            startRepeat(action, step: step)
            return
        }
        open(step: step, workspaceOnly: workspaceOnly, eventTime: eventTime)
    }

    // MARK: Open / close

    private func open(step: Int, workspaceOnly: Bool, eventTime: Double) {
        openedAt = eventTime
        let screens = displays.displays
        let cursor = AutoFocusManager.cursor()
        let mouseDisplay = screens.first { $0.frame.contains(cursor) } ?? screens.first
        workspaces = workspaceManager.state
        let ws = workspaces

        func usable(_ id: CGWindowID) -> Bool {
            guard let w = engine.windows[id] else { return false }
            return !w.isMinimized && !engine.hiddenPIDs.contains(w.pid)
        }
        func include(_ id: CGWindowID) -> Bool {
            guard usable(id) else { return false }
            guard workspaceOnly else { return true }
            guard !ws.isParked(id), let w = engine.windows[id], let m = mouseDisplay else { return false }
            return Geometry.display(for: w.frame, in: screens)?.id == m.id
        }

        let focused = engine.focusedID.flatMap { f in (include(f) && !ws.isParked(f)) ? f : nil }
        let ids = SwitcherLogic.order(focused: focused, mru: autoFocus.mru, zOrder: { AutoFocusManager.zOrder() },
                                      others: Array(engine.windows.keys), include: include)
        guard let first = SwitcherLogic.initialIndex(count: ids.count, focusedFirst: focused != nil && ids.first == focused,
                                                     step: step) else { return }

        // Quick tap (⌘ already up): no tiles, no panel layout, no temporary hotkeys, no
        // monitors. One list ordering and one focus call.
        if !Self.commandDown() {
            perf.record("10 ⌘Tab: key → list ready", since: eventTime)
            pick(ids[first], since: eventTime)
            return
        }
        list = ids
        index = first

        // Panel goes on the focused window's screen for ⌘Tab, the mouse's screen for ⌘`.
        let focusedDisplay = engine.focusedID.flatMap { engine.windows[$0] }.flatMap { Geometry.display(for: $0.frame, in: screens) }
        let target = workspaceOnly ? mouseDisplay : (focusedDisplay ?? mouseDisplay)
        let screenFrame = Self.cocoaScreen(for: target?.id)?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.load(ids.map { item(for: $0, screens: screens) }, selected: index, screenFrame: screenFrame,
                   twoScreens: screens.count > 1)
        // Draw now, during the show delay, so the panel appears already drawn.
        DispatchQueue.main.async { [weak self] in if self?.list != nil { self?.panel.drawNow() } }

        let (cmdLeft, cmdRight, cmdReturn, cmdEscape) = Self.panelKeys
        hotkeys.registerTemporary([
            (cmdLeft, { [unowned self] in perform(.switcherPrevious, eventTime: PerformanceMonitor.now()) }),
            (cmdRight, { [unowned self] in perform(.switcherNext, eventTime: PerformanceMonitor.now()) }),
            (cmdReturn, { [unowned self] in finish(commit: true) }),
            (cmdEscape, { [unowned self] in finish(commit: false) }),
        ])
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [unowned self] e in
            if !e.modifierFlags.contains(.command) { MainActor.assumeIsolated { finish(commit: true) } }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [unowned self] _ in
            // Clicks on the panel itself go to its view, so any click seen here is outside it.
            MainActor.assumeIsolated { finish(commit: false) }
        }) { monitors.append(m) }

        perf.record("10 ⌘Tab: key → list ready", since: eventTime)
        let watch = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.list != nil, !Self.commandDown() { self?.finish(commit: true) } }
        }
        watch.tolerance = 0.02
        RunLoop.main.add(watch, forMode: .common)
        commandWatch = watch
        // Ghost windows (closed without a notification) are dropped for next time.
        DispatchQueue.main.async { [weak self] in self?.engine.pruneDeadWindows() }

        // ⌘ already up (very quick tap): switch straight away, never flash the panel.
        if !Self.commandDown() { finish(commit: true); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.list != nil else { return }
            self.panel.show()
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: work)
        startRepeat(workspaceOnly ? (step > 0 ? .switcherWorkspaceNext : .switcherWorkspacePrevious)
                                  : (step > 0 ? .switcherNext : .switcherPrevious), step: step)
    }

    /// Holding the key: keep moving while it and ⌘ stay down (Carbon hotkeys fire once per
    /// press). Checks the key's live state each time, so letting go stops it at once.
    private func startRepeat(_ action: Action, step: Int) {
        repeatWork?.cancel()
        guard let key = hotkeys.registrations[action]?.shortcut.keyCode else { return }
        let t = SwitcherRepeat.timing(systemDelay: NSEvent.keyRepeatDelay, systemInterval: NSEvent.keyRepeatInterval)
        func schedule(after delay: Double) {
            let work = DispatchWorkItem { [weak self] in
                guard let self, let list = self.list, Self.commandDown(),
                      CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key)) else { return }
                self.index = SwitcherLogic.move(self.index, by: step, count: list.count)
                self.panel.select(self.index)
                schedule(after: t.interval)
            }
            repeatWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        schedule(after: t.delay)
    }

    private func finish(commit: Bool) {
        guard let list else { return }
        let picked = commit && index < list.count ? list[index] : nil
        self.list = nil
        showWork?.cancel()
        showWork = nil
        repeatWork?.cancel()
        repeatWork = nil
        commandWatch?.invalidate()
        commandWatch = nil
        panel.hide()
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        hotkeys.unregisterTemporary()
        guard let picked else { return }
        pick(picked, since: openedAt)
    }

    /// Focuses the chosen window, revealing its workspace if it's parked. It counts as focused
    /// and most recent at once, so a second quick ⌘Tab toggles back instead of picking it again.
    private func pick(_ id: CGWindowID, since start: Double) {
        autoFocus.noteFocusing(id)
        // Parked (or stranded off screen with no workspace): bring it back first.
        if workspaceManager.state.isParked(id) || workspaceManager.isStranded(id) { workspaceManager.reveal(id, eventTime: start); return }
        guard let w = engine.windows[id], let app = engine.apps[w.pid] else { return }
        WindowFocuser.focus(id, of: app, perf: perf, metric: "11 ⌘Tab: key → window focused", since: start)
    }

    // MARK: Helpers

    private func item(for id: CGWindowID, screens: [Display]) -> SwitcherItem {
        let w = engine.windows[id]
        let pid = w?.pid ?? 0
        let home: Display? = {
            if let h = workspaces.parked(id) { return screens.first { $0.uuid == h.scr } }
            return w.flatMap { Geometry.display(for: $0.frame, in: screens) }
        }()
        let (n, shown) = workspaces.workspace(of: id, displayUUID: home?.uuid ?? "")
        return SwitcherItem(id: id, appName: appName(pid), title: w?.title ?? "", icon: icon(pid),
                            onBuiltin: home?.isBuiltin ?? false, workspace: n, workspaceShown: shown)
    }

    /// Icons at the largest size the switcher draws them (shared, small bitmaps).
    private func icon(_ pid: pid_t) -> NSImage? { AppIcons.icon(pid, points: SwitcherPanel.G.icon, shadow: true) }

    /// The name stored when the app was tracked (no system lookup).
    private func appName(_ pid: pid_t) -> String {
        engine.apps[pid]?.name ?? NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
    }

    static func commandDown() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
    }

    /// ⌘← ⌘→ ⌘↩ ⌘⎋ while the panel is open (parsed once).
    private static let panelKeys = (Shortcut("cmd+left")!, Shortcut("cmd+right")!,
                                    Shortcut("cmd+return")!, Shortcut("cmd+escape")!)

    static func cocoaScreen(for displayID: UInt32?) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }
}
