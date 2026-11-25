import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// What the Dock is showing, as the Dock itself reports it through Accessibility.
///
/// Verified on macOS 26.6 (25G83): the Dock posts `AXExposeShowFrontWindows` when App Exposé
/// opens, `AXExposeShowAllWindows` for Mission Control and `AXExposeExit` when either closes,
/// and while open it has a top-level AX group whose identifier is "appexpose" / "mc".
/// None of this is documented, so:
/// - state is `confirmed` only when it came from those signals; otherwise it's `unknown`;
/// - Monarch never toggles App Exposé while the state is unknown (a toggle could do the opposite);
/// - after each toggle it checks that the Dock really reacted.
/// Event-driven: no polling. The AX callback runs on the main run loop.
@MainActor
final class DockState {
    enum Mode: Equatable { case none, appExpose, missionControl }
    enum State: Equatable { case confirmed(Mode), unknown }

    private(set) var state: State = .unknown
    /// When the state last changed (PerformanceMonitor clock).
    private(set) var changedAt: Double = 0
    var onChange: ((State) -> Void)?

    private var observer: AXObserver?
    private var dockApp: AXUIElement?
    private var dockPID: pid_t = 0
    private var launchToken: NSObjectProtocol?
    private var pendingVerify: DispatchWorkItem?

    private static let notes = ["AXExposeShowFrontWindows", "AXExposeShowAllWindows", "AXExposeShowDesktop", "AXExposeExit"]

    init() {
        attach()
        // The Dock restarts now and then (killall Dock, a crash, a settings change): follow it.
        launchToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.dock" else { return }
            MainActor.assumeIsolated { self.attach() }
        }
    }

    var isAppExposeOpen: Bool { state == .confirmed(.appExpose) }
    var isMissionControlOpen: Bool { state == .confirmed(.missionControl) }
    /// macOS is showing App Exposé or Mission Control (or we can't tell).
    var isBusy: Bool { state != .confirmed(.none) }
    /// True when Dock notifications are being received.
    var isWatching: Bool { observer != nil }

    // MARK: Watching

    func attach() {
        detach()
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            set(.unknown); return
        }
        let pid = dock.processIdentifier
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, name, refcon in
            guard let refcon else { return }
            let me = Unmanaged<DockState>.fromOpaque(refcon).takeUnretainedValue()
            let n = name as String
            MainActor.assumeIsolated { me.received(n) }
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { set(.unknown); return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let me = Unmanaged.passUnretained(self).toOpaque()
        var any = false
        for n in Self.notes where AXObserverAddNotification(obs, app, n as CFString, me) == .success { any = true }
        guard any else { set(.unknown); return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs; dockApp = app; dockPID = pid
        set(scan())
    }

    private func detach() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil; dockApp = nil; dockPID = 0
    }

    /// Re-reads the state from the Dock's AX tree (after wake or when a check is due).
    func resync() {
        if observer == nil || NSRunningApplication(processIdentifier: dockPID) == nil { attach() } else { set(scan()) }
    }

    private func received(_ name: String) {
        switch name {
        case "AXExposeShowFrontWindows": set(.confirmed(.appExpose))
        case "AXExposeShowAllWindows": set(.confirmed(.missionControl))
        case "AXExposeExit": set(.confirmed(.none))
        default: set(scan())                      // show desktop and anything new: look, don't guess
        }
    }

    /// Top-level Dock groups "appexpose" / "mc" exist only while those are open.
    private func scan() -> State {
        guard let app = dockApp else { return .unknown }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &v) == .success,
              let kids = v as? [AXUIElement] else { return .unknown }
        for k in kids {
            var id: CFTypeRef?
            guard AXUIElementCopyAttributeValue(k, "AXIdentifier" as CFString, &id) == .success, let s = id as? String else { continue }
            if s == "appexpose" { return .confirmed(.appExpose) }
            if s == "mc" { return .confirmed(.missionControl) }
        }
        return .confirmed(.none)
    }

    private func set(_ s: State) {
        guard s != state else { return }
        state = s
        changedAt = PerformanceMonitor.now()
        onChange?(s)
    }

    // MARK: App Exposé

    /// Opens App Exposé for the frontmost app. Only when it's confirmed closed and Mission
    /// Control isn't showing. Returns false if nothing was sent.
    @discardableResult
    func openAppExpose(log: @escaping (String) -> Void) -> Bool {
        guard state == .confirmed(.none) else { log("App Exposé not opened: Dock state \(describe)"); return false }
        return toggleAppExpose(expect: .appExpose, log: log)
    }

    /// Closes App Exposé. Only when it's confirmed open.
    @discardableResult
    func closeAppExpose(log: @escaping (String) -> Void) -> Bool {
        guard state == .confirmed(.appExpose) else { log("App Exposé not closed: Dock state \(describe)"); return false }
        return toggleAppExpose(expect: .none, log: log)
    }

    var describe: String {
        switch state {
        case .unknown: "unknown"
        case .confirmed(.none): "idle"
        case .confirmed(.appExpose): "App Exposé"
        case .confirmed(.missionControl): "Mission Control"
        }
    }

    /// Primary path: the Dock's own notification (private, the same one Hammerspoon and other
    /// window managers use). Fallback, only if the Dock didn't react: the user's App Exposé
    /// keyboard shortcut, and only if one is enabled in System Settings.
    private func toggleAppExpose(expect: Mode, log: @escaping (String) -> Void) -> Bool {
        let sent = Dock.send("com.apple.expose.front.awake")
        if !sent && !Self.postShortcut() { log("App Exposé: no way to reach the Dock"); return false }
        pendingVerify?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resync()
            guard self.state != .confirmed(expect) else { return }
            if sent, Self.postShortcut() {
                log("Dock didn't react: used the App Exposé shortcut")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.resync() }
            } else {
                log("Dock didn't react (state \(self.describe))")
            }
        }
        pendingVerify = work
        // The Dock reports App Exposé opening within a frame or two: check after 0.25 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        return true
    }

    /// Posts the App Exposé shortcut if the user has it enabled (symbolic hotkey 33,
    /// ⌃↓ by default). Returns false if it's off or unreadable.
    private static func postShortcut() -> Bool {
        CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)
        guard let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any],
              let hk = all["33"] as? [String: Any], (hk["enabled"] as? NSNumber)?.boolValue == true,
              let p = (hk["value"] as? [String: Any])?["parameters"] as? [NSNumber], p.count == 3 else { return false }
        let key = CGKeyCode(p[1].intValue)
        let m = p[2].uint64Value
        var flags = CGEventFlags()
        if m & 0x20000 != 0 { flags.insert(.maskShift) }
        if m & 0x40000 != 0 { flags.insert(.maskControl) }
        if m & 0x80000 != 0 { flags.insert(.maskAlternate) }
        if m & 0x100000 != 0 { flags.insert(.maskCommand) }
        if m & 0x800000 != 0 { flags.insert(.maskSecondaryFn) }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else { return false }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }
}

/// Dock helpers: the private notification call and the user's own trackpad settings.
enum Dock {
    private typealias SendNote = @convention(c) (CFString, Int32) -> Void
    private struct Fn: @unchecked Sendable { let send: SendNote }
    private static let fn: Fn? = {
        let h = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT (HIServices is already loaded)
        return dlsym(h, "CoreDockSendNotification").map { Fn(send: unsafeBitCast($0, to: SendNote.self)) }
    }()

    /// Returns false if the private call isn't there.
    static func send(_ name: String) -> Bool {
        guard let fn else { return false }
        fn.send(name as CFString, 0)
        return true
    }

    /// macOS trackpad gestures that fire on the same finger movements as Monarch's.
    /// Read fresh each time; Monarch never changes them.
    static func conflicts() -> [String] {
        func value(_ key: String, _ domains: [String]) -> Int {
            for d in domains {
                CFPreferencesAppSynchronize(d as CFString)
                if let n = CFPreferencesCopyAppValue(key as CFString, d as CFString) as? NSNumber { return n.intValue }
            }
            return 0
        }
        let pads = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
        var out: [String] = []
        if value("TrackpadFourFingerHorizSwipeGesture", pads) == 2 {
            out.append("4-finger ←/→ also swipes between full-screen apps")
        }
        let threeVert = value("TrackpadThreeFingerVertSwipeGesture", pads) == 2
        let mc = value("showMissionControlGestureEnabled", ["com.apple.dock"]) != 0
        let ax = value("showAppExposeGestureEnabled", ["com.apple.dock"]) != 0
        if threeVert && mc { out.append("3-finger ↑ also opens Mission Control") }
        if threeVert && ax { out.append("3-finger ↓ also opens App Exposé") }
        return out
    }
}
