import AppKit
import MonarchCore

/// The central state engine: which apps are running, which windows they have, which one is
/// focused. Fed only by notifications (NSWorkspace + AXObserver) — it never scans on a timer.
/// Features read from here instead of enumerating windows themselves.
@MainActor
final class WindowEngine {
    private(set) var apps: [pid_t: TrackedApp] = [:]
    private(set) var windows: [CGWindowID: ManagedWindow] = [:]
    private(set) var focusedWindow: [pid_t: CGWindowID] = [:]
    private(set) var isRunning = false
    /// The frontmost app, and apps that are hidden (⌘H): both from NSWorkspace notifications.
    private(set) var frontmostPID: pid_t = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    private(set) var hiddenPIDs = Set<pid_t>()

    /// The focused window across all apps, as far as notifications have told us — or, for half
    /// a second after Monarch focuses a window itself, that window (the notifications take a few
    /// round trips; a second quick ⌘Tab must already see the first one's pick).
    var focusedID: CGWindowID? { pendingFocusID ?? focusedWindow[frontmostPID] }
    private var pendingFocus: (id: CGWindowID, time: Double)?

    /// The window Monarch is focusing, until macOS confirms it (at most 1.5 s: revealing a
    /// parked window waits for its workspace switch).
    var pendingFocusID: CGWindowID? {
        guard let p = pendingFocus, PerformanceMonitor.now() - p.time < 1.5 else { return nil }
        return p.id
    }

    /// Monarch just focused `id`: treat it as focused until macOS confirms.
    func noteFocusing(_ id: CGWindowID) { pendingFocus = (id, PerformanceMonitor.now()) }

    /// Listeners: the globally focused window changed (app switch, click, ⌘Tab, anything),
    /// a window closed, a window's frame/title/minimized state changed.
    private var focusListeners: [(CGWindowID) -> Void] = []
    private var removeListeners: [(CGWindowID) -> Void] = []
    private var updateListeners: [(ManagedWindow) -> Void] = []
    func onFocus(_ f: @escaping (CGWindowID) -> Void) { focusListeners.append(f) }
    func onRemove(_ f: @escaping (CGWindowID) -> Void) { removeListeners.append(f) }
    func onUpdate(_ f: @escaping (ManagedWindow) -> Void) { updateListeners.append(f) }
    private var tokens: [NSObjectProtocol] = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let nc = NSWorkspace.shared.notificationCenter
        tokens.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier, regular = app.activationPolicy == .regular, name = app.localizedName ?? "?"
            MainActor.assumeIsolated { if regular { self.track(pid: pid, name: name) } }
        })
        tokens.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self.untrack(pid: pid) }
        })
        tokens.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                self.frontmostPID = pid
                self.apps[pid]?.ensureSubscribed()        // it refused at launch: try again now it's in use
                if let id = self.focusedWindow[pid] { self.focusListeners.forEach { $0(id) } }
            }
        })
        for (name, hidden) in [(NSWorkspace.didHideApplicationNotification, true), (NSWorkspace.didUnhideApplicationNotification, false)] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                MainActor.assumeIsolated {
                    if hidden { self.hiddenPIDs.insert(pid) } else { self.hiddenPIDs.remove(pid) }
                }
            })
        }
        // Frontmost app first (it's the one shortcuts act on); the rest a moment later instead
        // of every app being queried at once at launch.
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for app in running where app.isHidden { hiddenPIDs.insert(app.processIdentifier) }
        if let front = running.first(where: { $0.processIdentifier == frontmostPID }) {
            track(pid: front.processIdentifier, name: front.localizedName ?? "?")
        }
        let rest = running.filter { $0.processIdentifier != frontmostPID }
        for app in rest { track(pid: app.processIdentifier, name: app.localizedName ?? "?", startNow: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isRunning else { return }
            for (i, app) in rest.enumerated() {
                let pid = app.processIdentifier
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.02) { [weak self] in
                    guard let self, pid != self.ownPID, let a = self.apps[pid] else { return }
                    a.start()
                }
            }
        }
    }

    /// The tracked app for `pid`, creating it on demand (e.g. an accessory app with a window).
    func app(for pid: pid_t, name: String = "?") -> TrackedApp {
        if let a = apps[pid] { return a }
        return track(pid: pid, name: name)
    }

    @discardableResult
    private func track(pid: pid_t, name: String, startNow: Bool = true) -> TrackedApp {
        if let a = apps[pid] { return a }
        let app = TrackedApp(pid: pid, name: name) { event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(event) } }
        }
        apps[pid] = app
        if startNow, pid != ownPID, isRunning { app.start() }
        if pid != ownPID {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                if self?.apps[pid] != nil { AppIcons.prewarm(pid) }
            }
        }
        return app
    }

    private func untrack(pid: pid_t) {
        guard let app = apps.removeValue(forKey: pid) else { return }
        app.invalidate()
        AppIcons.forget(pid)
        // The app quit: its windows are gone. Tell listeners, so parked entries, focus
        // history and undo frames of those windows are dropped too.
        let gone = windows.values.filter { $0.pid == pid }.map(\.id)
        for id in gone { windows.removeValue(forKey: id) }
        focusedWindow.removeValue(forKey: pid)
        hiddenPIDs.remove(pid)
        for id in gone { removeListeners.forEach { $0(id) } }
    }

    private func apply(_ event: WindowEvent) {
        switch event {
        case let .discovered(pid, list):
            guard apps[pid] != nil else { return }        // app quit meanwhile
            for w in list { windows[w.id] = w }
        case let .upsert(w):
            guard apps[w.pid] != nil else { return }
            windows[w.id] = w
            updateListeners.forEach { $0(w) }
        case let .removed(_, id):
            windows.removeValue(forKey: id)
            removeListeners.forEach { $0(id) }
        case let .focused(pid, id):
            guard apps[pid] != nil else { return }
            focusedWindow[pid] = id
            if let p = pendingFocus, p.id == id { pendingFocus = nil }      // confirmed
            if pid == frontmostPID, let id { focusListeners.forEach { $0(id) } }
        }
    }

    func stop() {
        for t in tokens { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        tokens.removeAll()
        for app in apps.values { app.invalidate() }
        apps.removeAll()
        windows.removeAll()
        isRunning = false
    }
}
