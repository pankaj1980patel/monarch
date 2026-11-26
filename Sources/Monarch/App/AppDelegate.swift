import AppKit
import ApplicationServices
import MonarchCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let perf = PerformanceMonitor()
    private let displays = DisplayManager()
    private let engine = WindowEngine()
    private let hotkeys = HotkeyManager()
    private let permissions = PermissionsManager()
    private let toast = Toast()
    private lazy var snap = SnapManager(engine: engine, displays: displays, perf: perf)
    private lazy var autoFocus = AutoFocusManager(engine: engine, displays: displays, perf: perf, toast: toast)
    private let bridge = HammerspoonBridge()
    private lazy var workspaces = WorkspaceManager(engine: engine, displays: displays, perf: perf, bridge: bridge)
    private lazy var overview = OverviewController(engine: engine, displays: displays, workspaces: workspaces,
                                                   perf: perf, bridge: bridge)
    private lazy var gestures = GestureController(config: config.gestures ?? GestureConfig(), workspaces: workspaces,
                                                  overview: overview, perf: perf)
    private let sheet = SheetPanel()
    private lazy var switcher = SwitcherController(engine: engine, displays: displays, autoFocus: autoFocus,
                                                   hotkeys: hotkeys, workspaces: workspaces, perf: perf)

    private var config = AppConfiguration()
    private var configErrors: [String] = []
    /// False while running on defaults because config.json couldn't be used: nothing may be
    /// saved over the user's file until a reload succeeds.
    private var configWritable = true
    private var bindingErrors: [String] = []
    private var statusItem: NSStatusItem?
    private var statusText: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A previous run killed while it owned ⌘Tab (SIGKILL, jetsam, force quit) couldn't give
        // it back: give macOS its ⌘Tab now. Monarch takes it again only once its own is ready.
        SystemSwitcher.setSystemEnabled(true)
        // Bound every Accessibility call this process makes: a hung app costs at most this long.
        loadConfig()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Float(config.axTimeout))
        if let first = configErrors.first {
            let more = configErrors.count > 1 ? " (+\(configErrors.count - 1) more in the menu)" : ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.toast.show("config.json: \(first)" + more, seconds: 3) }
            }
        }

        SystemSwitcher.installCrashGuard()
        hotkeys.install()
        hotkeys.handler = { [unowned self] action, time in
            guard permissions.isTrusted else { permissions.prompt(); return }
            if action.isSwitcherAction {
                if overview.isOpen { overview.close() }          // one overlay at a time
                switcher.perform(action, eventTime: time)
            }
            else if action.isWorkspaceAction { workspaces.perform(action, eventTime: time) }
            else if action == .toggleOverview { overview.toggle(eventTime: time) }
            else if action.isFocusAction { autoFocus.perform(action, eventTime: time) }
            else if action == .showHelp { showHelp() }
            else if action == .gestureStatus { showGestureStatus() }
            else if action == .reloadConfig { reload() }
            else { snap.perform(action, eventTime: time) }
        }
        autoFocus.onToggle = { [unowned self] cross, hover in
            config.crossScreenFocus = cross
            config.sameAppHover = hover
            saveSetting(["crossScreenFocus": cross, "sameAppHover": hover])
        }
        displays.onChange = { [unowned self] in
            autoFocus.displaysChanged()
            workspaces.displaysChanged()
            overview.displaysChanged()
            updateStatusTitle()
        }
        gestures.onNotice = { [unowned self] text in toast.show(text, seconds: 1.4) }
        autoFocus.parkedDisplay = { [unowned self] id in workspaces.homeDisplayID(of: id) }
        autoFocus.suspended = { [unowned self] in overview.isOpen || switcher.isOpen }
        workspaces.focus = { [unowned self] id, metric, start in
            guard let w = engine.windows[id], let app = engine.apps[w.pid] else { return }
            // Monarch is focusing it (⌥ N, swipe, overview, Dock reveal): it's the most recent
            // window now, even while it's still coming back from off screen.
            autoFocus.noteFocusing(id)
            WindowFocuser.focus(id, of: app, perf: perf, metric: metric, since: start)
        }
        workspaces.onChange = { [unowned self] in updateStatusTitle(); overview.refreshIfOpen() }
        workspaces.onOtherCommand = { [unowned self] c in
            switch c {
            case let .overview(open):
                let now = PerformanceMonitor.now()
                switch open { case true?: overview.open(eventTime: now); case false?: overview.close(); case nil: overview.toggle(eventTime: now) }
            case let .gesture(active): overview.gesture(active: active)
            default: break
            }
        }
        // Shortcuts are registered only once Accessibility is allowed, so Hammerspoon keeps
        // them until Monarch can really act on them (see announce()).
        // Granted (again): start fresh. Observers from before a revoke are dead, so the engine
        // was stopped then and is rebuilt now.
        permissions.onGranted = { [unowned self] in engine.start(); applyBindings(); prewarmOverview() }
        permissions.onRevoked = { [unowned self] in engine.stop(); applyBindings() }
        if permissions.isTrusted { engine.start(); applyBindings(); prewarmOverview() } else { permissions.prompt() }

        // Hammerspoon asks after a config reload; answer with the current state.
        queryToken = DistributedNotificationCenter.default().addObserver(
            forName: Self.queryNote, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { self.announce() } }   // delegate lives for the whole run

        // The agent-managed copy takes over from this one when it starts (see main.swift).
        handoverToken = DistributedNotificationCenter.default().addObserver(
            forName: monarchHandoverNote, object: nil, queue: .main
        ) { note in
            // Any app can post this notification. Quit only if another copy of Monarch really
            // is starting (the agent's): the posted pid must be a live process running this
            // same executable, so a stray post can't switch Monarch off. (Looking it up by
            // bundle id never found it: it isn't a registered app until this copy has quit.)
            guard let pid = (note.object as? String).flatMap({ pid_t($0) }),
                  Self.isAnotherCopy(pid) else { return }
            MainActor.assumeIsolated { self.restarting = true; NSApp.terminate(nil) }
        }
        migrateLoginItem()

        setUpStatusItem()
        // From the moment the process started (not when this object was made). Window discovery
        // carries on in the background after this, so the name says so.
        perf.stats.record("0 process start → app ready (discovery continues)", ms: Self.secondsSinceProcessStart() * 1000)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.unregisterAll()
        SystemSwitcher.setSystemEnabled(true)      // give ⌘Tab back to macOS
        announce(forceOff: true)
        workspaces.prepareForQuit(keepParked: restarting)
        engine.stop()
    }

    /// Wall-clock time since the kernel started this process.
    private static func secondsSinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let t = info.kp_proc.p_starttime
        return Date().timeIntervalSince1970 - (Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }

    /// After discovery has settled: overview panels, windows and card images ready ahead of time.
    private func prewarmOverview() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.overview.prewarm() }
    }

    // MARK: Configuration

    private func loadConfig() {
        let outcome = ConfigurationStore.read()
        let (c, err) = ConfigFile.resolve(outcome)
        // Checked like ⌃⌥⇧ R: problems are listed in the menu, and values out of range are
        // replaced by their defaults rather than applied.
        config = c.withDefaultsForOutOfRange()
        let shortcutErrors = Set(c.resolvedBindings().errors)       // listed as binding errors already
        configErrors = err.map { [$0] } ?? c.validate().filter { !shortcutErrors.contains($0) }
        configWritable = ConfigFile.mayWrite(after: outcome)
        // First time: take over the gesture tuning Hammerspoon actually uses. Never when the
        // file couldn't be used: saving would replace the user's (broken) file with defaults.
        if config.gestures == nil, ConfigFile.mayWrite(after: outcome) {
            let hs = "org.hammerspoon.Hammerspoon" as CFString
            CFPreferencesAppSynchronize(hs)
            let cfg = CFPreferencesCopyAppValue("gesture.cfg" as CFString, hs) as? [String: Any]
            config.gestures = cfg.map(GestureConfig.init(hammerspoon:)) ?? GestureConfig()
            ConfigurationStore.save(config)
        }
    }

    private func applyBindings() {
        // Order matters: take over workspaces (load + save fresh state) before telling
        // Hammerspoon "on", because Hammerspoon mirrors workspaces.json when it hears it.
        defer { syncAutoFocus(); announce() }
        guard config.snappingEnabled, permissions.isTrusted else { hotkeys.unregisterAll(); return }
        let (bindings, errors) = config.resolvedBindings()
        bindingErrors = errors
        hotkeys.register(bindings)
        // A key Hammerspoon still held at this instant can fail to register. Hammerspoon lets
        // go when it hears announce(), so retry the failures once, shortly after.
        if hotkeys.registrations.values.contains(where: { !$0.ok }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.config.snappingEnabled else { return }
                    self.hotkeys.register(bindings)
                }
            }
        }
    }

    /// Auto focus runs only while Monarch owns the shortcuts; otherwise Hammerspoon's does.
    private func syncAutoFocus() {
        let active = !hotkeys.registrations.isEmpty
        autoFocus.configure(cross: config.crossScreenFocus, hover: config.sameAppHover, active: active)
        // Each of macOS's own ⌘Tab, ⌘⇧Tab and ⌘` is off only while Monarch has that exact
        // shortcut registered.
        let registered = active ? hotkeys.registrations.values.filter(\.ok).map(\.shortcut) : []
        SystemSwitcher.setOwned(SystemShortcuts.owned(by: registered))
        _ = switcher                                // build the hidden panel now, not on first ⌘Tab
        workspaces.setActive(active)
        if !active { overview.close() }
        gestures.configure(config.gestures ?? GestureConfig(), active: active)
        updateStatusTitle()
    }

    // MARK: Hammerspoon handoff

    private static let activeNote = Notification.Name("dev.monarch.Monarch.active")
    private static let queryNote = Notification.Name("dev.monarch.Monarch.query")
    private var queryToken: NSObjectProtocol?
    private var handoverToken: NSObjectProtocol?
    /// Quitting to be started again (a newer copy taking over, or a rebuild's SIGHUP): parked
    /// windows stay parked for the next copy, which loads the saved state.
    var restarting = false
    private var agentRepairStopped = false

    /// Tells Hammerspoon whether Monarch currently owns the window shortcuts.
    /// Hammerspoon releases its copies on "on" and takes them back on "off" (or if Monarch dies).
    private func announce(forceOff: Bool = false) {
        let on = !forceOff && !hotkeys.registrations.isEmpty
        DistributedNotificationCenter.default().postNotificationName(
            Self.activeNote, object: on ? "on" : "off", userInfo: nil, deliverImmediately: true)
    }

    // MARK: Menu bar

    /// Workspace indicator next to the icon: occupied workspaces per display, active in
    /// brackets, external display first, e.g. "[1] 3  │  [2]".
    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        let order = displays.displays.sorted { !$0.isBuiltin && $1.isBuiltin }.map(\.uuid)
        let text = workspaces.isActive ? " " + workspaces.state.menuTitle(displayOrder: order) : ""
        guard text != statusText else { return }           // the menu bar redraws only on a real change
        statusText = text
        button.imagePosition = .imageLeading
        button.attributedTitle = NSAttributedString(
            string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Monarch")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusTitle()
    }

    /// Rebuilt each time the menu opens, so it costs nothing while closed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        menu.addItem(info("Monarch \(version)"))

        if permissions.isTrusted {
            menu.addItem(info("Accessibility: allowed"))
        } else {
            menu.addItem(action("Allow Accessibility…", #selector(openAccessibility)))
        }

        let regs = hotkeys.registrations.values
        let failed = regs.filter { !$0.ok }
        menu.addItem(info("Shortcuts: \(regs.count - failed.count) active" + (failed.isEmpty ? "" : ", \(failed.count) taken by another app")))
        if !failed.isEmpty {
            for r in failed { menu.addItem(info("    ✕ \(r.shortcut)")) }
        }
        for e in configErrors + bindingErrors { menu.addItem(info("Config: \(e)")) }
        menu.addItem(info("Tracking \(engine.windows.count) windows in \(engine.apps.count) apps · \(displays.displays.count) displays"))
        if autoFocus.tapFailed { menu.addItem(info("Mouse listener refused by macOS: auto focus is off")) }
        if !WindowFocuser.usesPrivateAPI { menu.addItem(info("Single-window focus unavailable: using app activation")) }
        let g = config.gestures ?? GestureConfig()
        gestures.refreshConflicts()
        let gTitle: String
        if gestures.incompatible { gTitle = "Gestures: off (touch data changed in this macOS)" }
        else if !MultitouchBridge.isAvailable { gTitle = "Gestures: unavailable" }
        else if gestures.isRunning {
            gTitle = String(format: "Gestures: %d trackpad%@ · %@ · 3f %.2f · 4f %.2f · ratio %.1f", gestures.deviceCount,
                            gestures.deviceCount == 1 ? "" : "s", g.trigger.rawValue, g.threeFinger, g.fourFinger, g.ratio)
        } else { gTitle = "Gestures: off" }
        let gItem = NSMenuItem(title: gTitle, action: nil, keyEquivalent: "")
        let gMenu = NSMenu()
        gMenu.addItem(info("Dock: " + gestures.dock.describe + (gestures.dock.isWatching ? "" : " (not watching)")))
        if !gestures.conflicts.isEmpty {
            gMenu.addItem(.separator())
            gMenu.addItem(info("macOS gestures on the same swipes (Monarch leaves these alone):"))
            for c in gestures.conflicts { gMenu.addItem(info("    ⚠︎ " + c)) }
            gMenu.addItem(action("Open Trackpad Settings…", #selector(openTrackpadSettings)))
        }
        gMenu.addItem(.separator())
        if gestures.log.isEmpty { gMenu.addItem(info("No swipes yet")) }
        for l in gestures.log.reversed() { gMenu.addItem(info(l)) }
        gItem.submenu = gMenu
        menu.addItem(gItem)
        if !gestures.conflicts.isEmpty { menu.addItem(info("    ⚠︎ \(gestures.conflicts.count) macOS gesture conflict\(gestures.conflicts.count == 1 ? "" : "s"): see Gestures")) }

        menu.addItem(.separator())
        let perfItem = NSMenuItem(title: "Performance", action: nil, keyEquivalent: "")
        let perfMenu = NSMenu()
        perfMenu.addItem(info(String(format: "Memory %.1f MB · CPU time %.2f s since launch",
                                     PerformanceMonitor.memoryMB(), PerformanceMonitor.cpuSeconds())))
        let lines = perf.report()
        if lines.isEmpty { perfMenu.addItem(info("No actions yet: try ⌃⌥ ←")) }
        for l in lines { perfMenu.addItem(info(l)) }
        perfMenu.addItem(.separator())
        perfMenu.addItem(action("Copy Report", #selector(copyReport)))
        perfItem.submenu = perfMenu
        menu.addItem(perfItem)

        menu.addItem(.separator())
        let cross = action("Cross-Screen Focus  ⌃⌥M", #selector(toggleCross))
        cross.state = config.crossScreenFocus ? .on : .off
        menu.addItem(cross)
        let hover = action("Same-App Hover Focus  ⌃⌥H", #selector(toggleHover))
        hover.state = config.sameAppHover ? .on : .off
        menu.addItem(hover)
        let toggle = action("Monarch Enabled (off = Hammerspoon handles it all)", #selector(toggleSnapping))
        toggle.state = config.snappingEnabled ? .on : .off
        menu.addItem(toggle)
        let agent = Self.loginAgent
        let login = action("Launch at Login (restarts after a crash)", #selector(toggleLogin))
        login.state = agent.status == .enabled ? .on : agent.status == .requiresApproval ? .mixed : .off
        menu.addItem(login)
        if agent.status == .requiresApproval {
            menu.addItem(action("    Allow Monarch in Login Items…", #selector(openLoginItems)))
        }
        menu.addItem(action("Open Configuration File", #selector(openConfig)))
        menu.addItem(action("Reload Configuration", #selector(reloadConfig)))
        menu.addItem(.separator())
        menu.addItem(action("Quit Monarch", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = sel == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return i
    }

    @objc private func openAccessibility() { permissions.openSettings() }

    @objc private func toggleSnapping() {
        config.snappingEnabled.toggle()
        saveSetting(["snappingEnabled": config.snappingEnabled])
        applyBindings()
    }

    /// Writes only these settings into config.json, leaving the rest of the file (including
    /// edits not reloaded yet) as it is. A file that can't be read or parsed is never written.
    private func saveSetting(_ changes: [String: Bool]) {
        guard configWritable, ConfigurationStore.update(changes) else {
            toast.show("Not saved: config.json can't be read (fix it and press ⌃⌥⇧ R)", seconds: 2.5)
            return
        }
    }

    @objc private func toggleCross() { autoFocus.perform(.toggleCrossScreenFocus, eventTime: PerformanceMonitor.now()) }
    @objc private func toggleHover() { autoFocus.perform(.toggleSameAppHover, eventTime: PerformanceMonitor.now()) }

    /// Login item + crash restart: a launch agent inside the bundle (KeepAlive on a crash only).
    private static let loginAgent = SMAppService.agent(plistName: monarchAgentLabel + ".plist")

    @objc private func toggleLogin() {
        agentRepairStopped = true                       // the user decides from here on
        do {
            if Self.loginAgent.status == .enabled || Self.loginAgent.status == .requiresApproval {
                try Self.loginAgent.unregister()
            } else {
                try Self.loginAgent.register()
                if Self.loginAgent.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change Launch at Login"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    /// True if `pid` is another live process running this app's executable.
    nonisolated static func isAnotherCopy(_ pid: pid_t) -> Bool {
        guard pid > 0, pid != getpid(), kill(pid, 0) == 0 else { return false }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0, let mine = Bundle.main.executableURL else { return false }
        let theirs = URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
        return theirs == mine.resolvingSymlinksInPath().path
    }

    @objc private func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// Keeps the login agent working:
    /// - the old plain login item becomes the agent (same intent: start at login), once;
    /// - started by hand while the agent is enabled (so the agent's copy isn't running: after
    ///   Quit, or after a rebuild, which launchd refuses to start until it's registered again):
    ///   register again. The agent's copy then starts from this bundle and takes over (main.swift),
    ///   so crash restarts are back in effect.
    private func migrateLoginItem() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
            try? Self.loginAgent.register()
            return
        }
        let fromAgent = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == monarchAgentLabel
        guard !fromAgent, Self.loginAgent.status == .enabled else { return }
        reregisterAgent(attempt: 0)
    }

    /// Right after a rebuild launchd can still refuse the new code (EX_CONFIG) for up to a
    /// minute or so. If the agent's copy hasn't taken over (this copy would have quit on its
    /// handover), try again, further apart each time. This copy keeps running meanwhile.
    private func reregisterAgent(attempt: Int) {
        let delays: [Double] = [6, 15, 30, 60, 90]
        guard attempt <= delays.count, !agentRepairStopped else { return }
        try? Self.loginAgent.unregister()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            try? Self.loginAgent.register()
        }
        guard attempt < delays.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
            self?.reregisterAgent(attempt: attempt + 1)      // still here: the agent didn't start
        }
    }

    @objc private func openConfig() { NSWorkspace.shared.open(ConfigurationStore.url) }

    @objc private func reloadConfig() { reload() }

    /// ⌃⌥⇧ R / the menu: re-reads config.json and applies it only if it's valid. A file that
    /// doesn't parse, or has a bad shortcut, an unknown action, one key bound twice or a value
    /// out of range, keeps the current settings; the problems are listed in the menu.
    private func reload() {
        let (c, err) = ConfigurationStore.load()
        let problems = err.map { [$0] } ?? c.validate()
        if !problems.isEmpty {
            configErrors = problems
            let first = problems[0]
            toast.show("config.json not applied: \(first)" + (problems.count > 1 ? " (+\(problems.count - 1) more in the menu)" : ""), seconds: 3)
            return
        }
        config = c
        configErrors = []
        configWritable = true
        if config.gestures == nil { config.gestures = GestureConfig() }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Float(config.axTimeout))
        applyBindings()
        toast.show("Config reloaded")
    }

    // MARK: Help, gesture status

    private func showHelp() {
        var bindings: [Action: Shortcut] = [:]
        for (a, r) in hotkeys.registrations where r.ok { bindings[a] = r.shortcut }
        let g = (config.gestures?.enabled ?? false) && gestures.isRunning
        let sections = HelpSheet.sections(bindings: bindings, states: .init(cross: config.crossScreenFocus, hover: config.sameAppHover), gestures: g)
        let (l, r) = HelpSheet.columns(sections)
        let n = displays.displays.count
        sheet.toggle(kind: "help", title: "Window shortcuts · \(n) screen\(n == 1 ? "" : "s")   (⌃⌥ / or click to close)", left: l, right: r)
    }

    private func showGestureStatus() {
        typealias S = HelpSheet.Section
        typealias R = HelpSheet.Row
        let g = config.gestures ?? GestureConfig()
        gestures.refreshConflicts()
        let state = gestures.incompatible ? "off: touch data changed in this macOS"
            : !MultitouchBridge.isAvailable ? "unavailable" : gestures.isRunning ? "on · \(gestures.deviceCount) trackpad(s)" : "off"
        var left = [S(title: "Gestures", rows: [
            R(keys: "State", text: state),
            R(keys: "Trigger", text: g.trigger == .swipe ? "swipe (4 fingers act mid-swipe)" : "lift (act when fingers lift)"),
            R(keys: "3 fingers", text: String(format: "%.3f of the trackpad", g.threeFinger)),
            R(keys: "4 fingers", text: String(format: "%.3f of the trackpad", g.fourFinger)),
            R(keys: "Ratio", text: String(format: "%.2f (lock needs ≥ %.1f)", g.ratio, GestureRecognizer.minimumLockRatio)),
            R(keys: "Lock", text: String(format: "%.3f", g.lockDistance)),
            R(keys: "Thumb", text: !g.thumbRejection ? "counted (thumbRejection off)"
                : g.thumbArea == .anywhere ? "resting thumb ignored anywhere"
                : "resting thumb ignored in \(g.thumbArea == .both ? "left and right" : g.thumbArea.rawValue) \(Int((g.thumbAreaWidth * 100).rounded()))%"),
            R(keys: "Scroll", text: !g.blockScroll ? "not blocked (blockScroll off)" : ScrollBlocker.isInstalled ? "blocked during swipes" : "not blocked (couldn't install the scroll tap)"),
            R(keys: "Overview", text: String(format: "full at %.2f travel", g.overviewTravel)),
            R(keys: "Click guard", text: String(format: "%.2f s", g.clickGuard)),
            R(keys: "Dock", text: gestures.dock.describe + (gestures.dock.isWatching ? "" : " (not watching)"))])]
        if !gestures.conflicts.isEmpty {
            left.append(S(title: "macOS gestures on the same swipes", rows: gestures.conflicts.map { R(keys: "⚠︎", text: $0) }))
        }
        let log = gestures.log.reversed().map { line -> R in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            return R(keys: parts.first ?? "", text: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
        }
        let right = [S(title: "Recent swipes (newest first)", rows: log.isEmpty ? [R(keys: "—", text: "No swipes yet")] : log)]
        sheet.toggle(kind: "gestures", title: "Gesture status   (⌃⌥⇧ G or click to close · edit config.json \"gestures\" to tune)", left: left, right: right)
    }

    @objc private func openTrackpadSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    @objc private func copyReport() {
        var lines = [String(format: "Monarch · memory %.1f MB · CPU %.2f s · %d windows, %d apps",
                            PerformanceMonitor.memoryMB(), PerformanceMonitor.cpuSeconds(),
                            engine.windows.count, engine.apps.count)]
        lines += perf.report()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
