import AppKit
import MonarchCore

/// ⌘Tab / ⌘` window switcher.
///
/// - ⌘Tab: every window on both screens and all workspaces, most recently used first.
///   A quick tap toggles between the last two windows without showing the panel.
/// - ⌘`: only the current workspace of the screen under the mouse.
/// - While ⌘ is held: Tab / ⇧Tab and ← / → move, ↩ picks, ⎋ cancels, hover selects,
///   click picks, click outside cancels. Releasing ⌘ picks.
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
    private var iconCache: [pid_t: NSImage] = [:]
    private var nameCache: [pid_t: String] = [:]

    init(engine: WindowEngine, displays: DisplayManager, autoFocus: AutoFocusManager,
         hotkeys: HotkeyManager, workspaces: WorkspaceManager, perf: PerformanceMonitor) {
        self.engine = engine
        self.displays = displays
        self.autoFocus = autoFocus
        self.hotkeys = hotkeys
        self.workspaceManager = workspaces
        self.perf = perf
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
            return
        }
        open(step: step, workspaceOnly: workspaceOnly, eventTime: eventTime)
    }

    // MARK: Open / close

    private func open(step: Int, workspaceOnly: Bool, eventTime: Double) {
        openedAt = eventTime
        // Forget icons/names of apps that quit (a reused pid must not show the old icon).
        if iconCache.count > engine.apps.count {
            iconCache = iconCache.filter { engine.apps[$0.key] != nil }
            nameCache = nameCache.filter { engine.apps[$0.key] != nil }
        }
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
        let ids = SwitcherLogic.order(focused: focused, mru: autoFocus.mru, zOrder: AutoFocusManager.zOrder(),
                                      others: Array(engine.windows.keys), include: include)
        guard let first = SwitcherLogic.initialIndex(count: ids.count, focusedFirst: focused != nil && ids.first == focused,
                                                     step: step) else { return }
        list = ids
        index = first

        // Panel goes on the focused window's screen for ⌘Tab, the mouse's screen for ⌘`.
        let focusedDisplay = engine.focusedID.flatMap { engine.windows[$0] }.flatMap { Geometry.display(for: $0.frame, in: screens) }
        let target = workspaceOnly ? mouseDisplay : (focusedDisplay ?? mouseDisplay)
        let screenFrame = Self.cocoaScreen(for: target?.id)?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.load(ids.map { item(for: $0, screens: screens) }, selected: index, screenFrame: screenFrame,
                   twoScreens: screens.count > 1)

        let cmdLeft = Shortcut("cmd+left")!, cmdRight = Shortcut("cmd+right")!
        let cmdReturn = Shortcut("cmd+return")!, cmdEscape = Shortcut("cmd+escape")!
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

        // ⌘ already up (very quick tap): switch straight away, never flash the panel.
        if !Self.commandDown() { finish(commit: true); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.list != nil else { return }
            self.panel.show()
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: work)
    }

    private func finish(commit: Bool) {
        guard let list else { return }
        let picked = commit && index < list.count ? list[index] : nil
        self.list = nil
        showWork?.cancel()
        showWork = nil
        panel.hide()
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        hotkeys.unregisterTemporary()
        guard let picked else { return }

        let start = openedAt
        let focus = { [weak self] in
            guard let self, let w = self.engine.windows[picked], let app = self.engine.apps[w.pid] else { return }
            WindowFocuser.focus(picked, of: app, perf: self.perf, metric: "11 ⌘Tab: key → window focused", since: start)
        }
        if workspaces.isParked(picked) { workspaceManager.reveal(picked, eventTime: start) } else { focus() }
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

    private func icon(_ pid: pid_t) -> NSImage? {
        if let i = iconCache[pid] { return i }
        let i = NSRunningApplication(processIdentifier: pid)?.icon
        iconCache[pid] = i
        return i
    }

    private func appName(_ pid: pid_t) -> String {
        if let n = nameCache[pid] { return n }
        let n = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        nameCache[pid] = n
        return n
    }

    static func commandDown() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
    }

    static func cocoaScreen(for displayID: UInt32?) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }
}
