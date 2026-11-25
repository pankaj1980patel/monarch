import AppKit
import MonarchCore
import QuartzCore

/// What swipes do (each gesture does at most one thing):
/// - four fingers ← / →: next / previous workspace on the screen under the mouse
///   (`swipe` trigger: as soon as the distance is reached; `lift`: when the fingers come up)
/// - three fingers ↑: the overview follows the fingers open, or closed if it's already open
///   (the same gesture dismisses it); closes App Exposé if the Dock reports it open
/// - three fingers ↓: the overview follows the fingers closed if it's open; closes App Exposé
///   if it's open (the same gesture dismisses it); otherwise opens App Exposé on lift
///
/// Ownership: whatever macOS already did wins. If the Dock reports App Exposé or Mission
/// Control open (or can't tell), Monarch doesn't open the overview; if macOS opens one of them
/// during a swipe, the overview gives way. Monarch never changes System Settings: conflicting
/// native gestures are listed in the menu instead.
///
/// Threads: the multitouch thread sends only semantic events here (main). The live finger
/// position for the interactive overview is read from one atomic word on each display frame.
@MainActor
final class GestureController {
    private let bridge: MultitouchBridge
    private let workspaces: WorkspaceManager
    private let overview: OverviewController
    private let perf: PerformanceMonitor
    let dock = DockState()
    private var config: GestureConfig
    private var wantRunning = false

    /// The current three-finger interaction with the overview.
    /// `sign`: +1 when swiping up moves toward "open" (↑ opens, ↓ closes), -1 when the same
    /// swipe that opened it closes it again (↑ closes the overview, ↓ closes App Exposé).
    private enum Interactive { case none, overview(opening: Bool, sign: Double), appExposeOpen, appExposeClose(sign: Double), ignored }
    private var interactive = Interactive.none
    private var ticker: FrameTicker?

    private(set) var log: [String] = []
    private(set) var incompatible = false
    private(set) var conflicts: [String] = []
    private var tokens: [NSObjectProtocol] = []
    private var hotplugWork: DispatchWorkItem?

    init(config: GestureConfig, workspaces: WorkspaceManager, overview: OverviewController, perf: PerformanceMonitor) {
        self.config = config
        self.workspaces = workspaces
        self.overview = overview
        self.perf = perf
        bridge = MultitouchBridge(config: config)
        bridge.onOutput = { [unowned self] out in
            let t = PerformanceMonitor.now()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(out, at: t) } }
        }
        bridge.onIncompatible = { [unowned self] in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.incompatible = true
                self.note("touch data doesn't match the known layout: gestures off")
                self.handle(self.bridge.stop(), at: PerformanceMonitor.now())
            } }
        }
        dock.onChange = { [unowned self] s in
            // macOS opened App Exposé / Mission Control itself: it owns this gesture now.
            if s != .confirmed(.none), case .overview = interactive {
                note("macOS took the swipe (\(dock.describe)): overview gives way")
                finishOverview(open: false, velocity: 0)
                interactive = .ignored
            }
        }
        let nc = NSWorkspace.shared.notificationCenter
        // Touches stop arriving across sleep, and a gesture can be cut off mid-way: start clean.
        tokens.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.reset(stop: true, reason: "sleep") }
        })
        tokens.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.dock.resync(); self.reset(stop: false, reason: "wake") }
        })
        tokens.append(nc.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.reset(stop: false, reason: "session switch") }
        })
        bridge.watchHotplug { [unowned self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.devicesChanged() } }
        }
    }

    var isRunning: Bool { bridge.isRunning }
    var deviceCount: Int { bridge.deviceCount }

    func configure(_ c: GestureConfig, active: Bool) {
        config = c
        bridge.update(config: c)
        wantRunning = active && c.enabled && !incompatible
        conflicts = Dock.conflicts()
        if wantRunning { bridge.start() } else { handle(bridge.stop(), at: PerformanceMonitor.now()) }
    }

    /// Re-read native gesture settings (the menu opens; the user may have changed them).
    func refreshConflicts() { conflicts = Dock.conflicts() }

    // MARK: Lifecycle

    private func reset(stop: Bool, reason: String) {
        let out = bridge.isRunning ? (stop ? bridge.stop() : bridge.restart()) : GestureOutput()
        if !stop && !bridge.isRunning && wantRunning { bridge.start() }
        cancelInteraction()
        if out.lifted { overview.gesture(active: false, guardSeconds: config.clickGuard) }
        note("reset (\(reason))")
    }

    /// A trackpad appeared or went away: restart once things settle (a reconnect sends several).
    private func devicesChanged() {
        hotplugWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantRunning else { return }
            self.reset(stop: false, reason: "trackpad change")
            self.note("\(self.bridge.deviceCount) trackpad(s)")
        }
        hotplugWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: Events

    private func handle(_ out: GestureOutput, at t: Double) {
        if out.began { overview.gesture(active: true, guardSeconds: config.clickGuard) }
        if let s = out.locked { locked(s, at: t) }
        if let s = out.crossed { crossed(s, at: t) }
        if let s = out.ended { ended(s, at: t) }
        if out.lifted {
            if case let .overview(opening, _) = interactive { finishOverview(open: !opening, velocity: 0) }   // never left hanging: undo
            interactive = .none
            stopTicker()
            overview.gesture(active: false, guardSeconds: config.clickGuard)
        }
    }

    private func locked(_ s: SwipeSample, at t: Double) {
        interactive = .none
        guard s.fingers == 3, s.axis == .vertical else { return }
        let up = s.displacement > 0
        if dock.isAppExposeOpen {
            interactive = .appExposeClose(sign: up ? 1 : -1)          // ↑, or ↓ again, dismisses it
        } else if dock.isBusy {
            interactive = .ignored
            note("3-finger \(up ? "↑" : "↓") ignored: Dock state \(dock.describe)")
        } else if overview.isOpen {
            // ↓ closes it; ↑ again (the gesture that opened it) closes it too.
            interactive = .overview(opening: overview.beginInteractive(), sign: up ? -1 : 1)
            startTicker()
        } else if up {
            interactive = .overview(opening: overview.beginInteractive(), sign: 1)
            startTicker()
            perf.record("15 gesture: lock → overview follows", since: t)
        } else {
            interactive = .appExposeOpen
        }
    }

    private func crossed(_ s: SwipeSample, at t: Double) {
        guard s.fingers == 4, s.axis == .horizontal, config.trigger == .swipe else { return }
        stepWorkspace(s, at: t)
    }

    private func ended(_ s: SwipeSample, at t: Double) {
        note(String(format: "%d-finger %@ %.3f (%.2f/s)", s.fingers, s.direction.rawValue, s.distance, s.velocity))
        if s.fingers == 4, s.axis == .horizontal {
            if config.trigger == .lift && s.distance >= config.fourFinger { stepWorkspace(s, at: t) }
            return
        }
        guard s.fingers == 3, s.axis == .vertical else { return }
        switch interactive {
        case let .overview(opening, sign):
            let v = sign * s.velocity / max(config.overviewTravel, 0.01)   // visibility per second
            let vis = visibility(s.displacement, opening: opening, sign: sign)
            let open = opening ? InteractiveDecision.complete(progress: vis, velocity: v)
                               : !InteractiveDecision.complete(progress: 1 - vis, velocity: -v)
            overview.setInteractive(visibility: vis)            // exactly where the fingers left it
            finishOverview(open: open, velocity: v)
            note(open == opening ? (opening ? "→ overview opened" : "→ overview closed")
                                 : (opening ? "→ overview cancelled" : "→ overview stays"))
        case .appExposeOpen:
            guard -s.displacement >= config.threeFinger else { note("→ too short"); break }
            if dock.openAppExpose(log: { [weak self] in self?.note($0) }) { note("→ App Exposé") }
        case let .appExposeClose(sign):
            guard sign * s.displacement >= config.threeFinger else { note("→ too short"); break }
            if dock.closeAppExpose(log: { [weak self] in self?.note($0) }) { note("→ close App Exposé") }
        case .none, .ignored:
            break
        }
        interactive = .none
        stopTicker()
        perf.record("15 gesture: lift → action started", since: t)
    }

    private func stepWorkspace(_ s: SwipeSample, at t: Double) {
        workspaces.step(s.direction == .left ? 1 : -1, eventTime: t)          // swipe left = next, like Spaces
        note(s.direction == .left ? "→ next workspace" : "→ previous workspace")
        perf.record("15 gesture: swipe → action started", since: t)
    }

    // MARK: Interactive overview

    private func visibility(_ displacement: Double, opening: Bool, sign: Double) -> Double {
        let p = sign * displacement / max(config.overviewTravel, 0.01)
        return min(max((opening ? 0 : 1) + p, 0), 1)
    }

    /// Display-synchronised: reads the latest finger position (one atomic load), no queueing.
    private func startTicker() {
        guard ticker == nil else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        ticker = FrameTicker(screen: screen) { [weak self] in self?.tick() }
    }

    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    private func tick() {
        guard case let .overview(opening, sign) = interactive,
              let p = MultitouchBridge.decode(bridge.progress.load(ordering: .relaxed)),
              p.fingers == 3, p.axis == .vertical else { return }
        overview.setInteractive(visibility: visibility(p.displacement, opening: opening, sign: sign))
    }

    private func finishOverview(open: Bool, velocity: Double) {
        stopTicker()
        guard overview.isInteracting else { return }
        overview.endInteractive(open: open, velocity: velocity)
    }

    /// Cut off (sleep, session switch): back to how it was before the swipe.
    private func cancelInteraction() {
        if case let .overview(opening, _) = interactive { finishOverview(open: !opening, velocity: 0) }
        interactive = .none
        stopTicker()
    }

    private func note(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(s)")
        if log.count > 16 { log.removeFirst(log.count - 16) }
    }
}

/// A display link that runs only while a gesture drives the overview.
@MainActor
private final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private let onFrame: () -> Void

    init(screen: NSScreen?, onFrame: @escaping () -> Void) {
        self.onFrame = onFrame
        super.init()
        guard let screen else { return }
        let l = screen.displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func step(_ l: CADisplayLink) { onFrame() }

    func invalidate() { link?.invalidate(); link = nil }
}
