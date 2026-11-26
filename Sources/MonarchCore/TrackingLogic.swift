import CoreGraphics

// Decisions behind past bugs, kept here (not in the app target) so MonarchChecks can pin
// them down. The app calls these; the checks replay the situations that once went wrong.

extension FocusLogic {
    /// The display a focused window is recorded on in the recent-windows list (⌘Tab order),
    /// or nil to leave it out.
    ///
    /// - Visible on a display: that display.
    /// - Off screen (parked on a hidden workspace): left out, because macOS focuses such
    ///   windows in passing during workspace switches; unless Monarch is picking it itself
    ///   (`picked`), then it counts on its home display. Leaving a picked window out made the
    ///   next quick ⌘Tab go to the wrong window after any ⌘Tab across workspaces.
    public static func mruDisplay(frame: CGRect, displays: [Display], picked: Bool, parkedHome: UInt32?) -> UInt32? {
        if let d = Geometry.display(for: frame, in: displays), visibleFraction(frame, on: d.frame) >= minVisibleFraction {
            return d.id
        }
        guard picked, let home = parkedHome, displays.contains(where: { $0.id == home }) else { return nil }
        return home
    }
}

/// Which tracked windows the engine has been told about.
///
/// A window can be tracked by its app (subscribed to) before the engine knows it: its first
/// read timed out, or the focus handler adopted it before the window-created retry. Such a
/// window must be announced by whichever read succeeds next, or it stays missing from ⌘Tab
/// and the overview.
public struct WindowAnnouncements: Sendable {
    public private(set) var announced = Set<UInt32>()
    public init() {}

    public func needsAnnouncing(_ id: UInt32) -> Bool { !announced.contains(id) }
    public mutating func announced(_ id: UInt32) { announced.insert(id) }
    /// The window was destroyed. True if the engine knew it (so it must hear of the removal).
    public mutating func destroyed(_ id: UInt32) -> Bool { announced.remove(id) != nil }
}

/// Each app's focused window, as the engine keeps it.
public struct FocusedWindows: Sendable {
    public private(set) var byPID: [Int32: UInt32] = [:]
    public init() {}

    public subscript(pid: Int32) -> UInt32? { byPID[pid] }
    public mutating func set(_ pid: Int32, _ id: UInt32?) { byPID[pid] = id }
    public mutating func appQuit(_ pid: Int32) { byPID.removeValue(forKey: pid) }
    /// A closed window is no longer its app's focused window (it may have been the last one:
    /// keeping it made actions on "the focused window" target a window that doesn't exist).
    public mutating func windowClosed(_ id: UInt32, of pid: Int32) {
        if byPID[pid] == id { byPID.removeValue(forKey: pid) }
    }
    public mutating func removeAll() { byPID.removeAll() }
}

/// ⌃⌘F: fill the screen, press again to restore.
public enum FillToggle {
    public enum Step: Equatable, Sendable {
        /// Go back to this frame.
        case restore(CGRect)
        /// Fill the area, after saving the current frame to come back to.
        case fill
        /// Already filling it and nothing saved: nothing to do (saving the full frame now
        /// would make the toggle never restore).
        case nothing
    }

    public static func step(current: CGRect, area: CGRect, saved: CGRect?) -> Step {
        guard Geometry.nearlyEqual(current, area, tolerance: 4) else { return .fill }
        return saved.map { .restore($0) } ?? .nothing
    }
}

/// How App Exposé is triggered: the Dock's own notification, or, once that has been seen
/// not to work and the user's keyboard shortcut did, the shortcut directly.
public struct AppExposeTrigger: Sendable {
    public enum Route: Equatable, Sendable { case dock, shortcut }
    /// How long to wait before checking the Dock reacted. Shorter checks fired the fallback
    /// while a slow Dock was still opening App Exposé, which closed it again.
    public static let verifyDelay = 0.5

    public private(set) var route = Route.dock
    public init() {}

    /// The Dock didn't react and the shortcut fallback did: use the shortcut from now on.
    public mutating func fallbackWorked() { route = .shortcut }
    /// The shortcut, sent directly, didn't work either: go back to trying the Dock first.
    public mutating func shortcutFailed() { route = .dock }

    /// The Dock's AX tree is read on the main thread at swipe start only when its state isn't
    /// known: its notifications keep a known state current, and a busy Dock stalls the read.
    public static func needsDockRead(stateKnown: Bool, watching: Bool) -> Bool { !stateKnown || !watching }
}

/// Retries for apps that don't answer while launching.
public enum DiscoveryRetry {
    public static let maxAttempts = 4
    /// Delay before retry number `attempt + 1`, or nil when out of retries.
    public static func delay(after attempt: Int) -> Double? {
        attempt < maxAttempts ? 0.25 * Double(1 << attempt) : nil
    }

    /// Re-setting up an app that refused at launch, at most once per `interval` seconds
    /// (it used to rerun on every activation).
    public struct Limiter: Sendable {
        public static let interval = 10.0
        private var last = -Double.infinity
        public init() {}
        public mutating func allow(now: Double) -> Bool {
            guard now - last >= Self.interval else { return false }
            last = now
            return true
        }
    }
}

extension OverviewModel {
    /// Height of what a card draws (header, rows, "+N more"), at most the card. Card bitmaps
    /// are this tall, not the whole card, so tall cards don't cost tall bitmaps.
    public static func contentHeight(rows: Int, more: Int, cardHeight: CGFloat, layout: Layout) -> CGFloat {
        let h = layout.rowsTop + CGFloat(rows) * layout.rowHeight + (more > 0 ? 40 : 4)
        return min(cardHeight, max(layout.rowsTop, h).rounded(.up))
    }
}

/// Window moves a workspace operation has started but not finished (they run on the apps'
/// queues). Fast ⌥ N presses start a new switch while the previous one is still moving windows.
///
/// - Parks are counted, not a set: one window can be parked, restored and parked again by
///   three quick switches. A set forgot it was still parking as soon as the first park
///   finished, and the window's frame from the restore in between then looked like "moved
///   back by hand", so it was dropped from its workspace.
/// - Restores remember where the window is going until it's seen there. Until then, Monarch's
///   copy of its frame is still the parked one, so it's neither parked nor visible. A fixed
///   timer isn't enough: a busy app (Chrome) can take longer to move than any short delay.
///   `restoreExpired` is only a safety net, for a window that never shows up.
public struct MovesInFlight: Sendable {
    /// How long after its move a restore that was never seen arriving is given up on.
    public static let restoreSafetyNet = 3.0

    private var parks: [UInt32: Int] = [:]
    private var restores: [UInt32: (seq: Int, target: CGRect)] = [:]
    public init() {}

    public mutating func parkStarted(_ id: UInt32) { parks[id, default: 0] += 1 }
    public mutating func parkFinished(_ id: UInt32) {
        guard let n = parks[id] else { return }
        parks[id] = n > 1 ? n - 1 : nil
    }
    public func isParking(_ id: UInt32) -> Bool { parks[id] != nil }

    /// A restore toward `target`, started by operation `seq` (the newest one wins).
    public mutating func restoreStarted(_ id: UInt32, to target: CGRect, seq: Int) { restores[id] = (seq, target) }
    /// The window was seen on the target's display: no longer on its way.
    public mutating func restoreArrived(_ id: UInt32) { restores.removeValue(forKey: id) }
    /// The safety net for operation `seq`'s restore; ignored if a newer restore replaced it.
    public mutating func restoreExpired(_ id: UInt32, seq: Int) {
        if restores[id]?.seq == seq { restores.removeValue(forKey: id) }
    }
    /// Where a window being restored is going (nil when no restore is in flight).
    public func restoreTarget(_ id: UInt32) -> CGRect? { restores[id]?.target }
    public var restoring: [UInt32: CGRect] { restores.mapValues(\.target) }
}

/// Numbers workspace operations, so results and focus changes of an older operation can't
/// undo a newer one. Fast ⌥ N presses overlap: the first switch can finish after the second.
///
/// - Per display: only the newest operation on a display may focus a window there. An older
///   switch finishing late used to focus its own top window, which the newer switch had just
///   parked: typing went into a window you couldn't see.
/// - Per window: only the newest operation that moved a window may record what happened to
///   it. A late "not moved" from an older park used to delete the newer switch's entry.
public struct OperationSequence: Sendable {
    private var last = 0
    private var byDisplay: [String: Int] = [:]
    private var byWindow: [UInt32: Int] = [:]
    public init() {}

    /// Starts an operation on `displays` that moves `windows`; returns its number.
    public mutating func begin(displays: [String], windows: [UInt32]) -> Int {
        last += 1
        for d in displays { byDisplay[d] = last }
        for w in windows { byWindow[w] = last }
        return last
    }
    /// True if no newer operation has started on `display`.
    public func isLatest(_ seq: Int, on display: String) -> Bool { (byDisplay[display] ?? seq) <= seq }
    /// True if no newer operation has moved `window`.
    public func isLatest(_ seq: Int, for window: UInt32) -> Bool { (byWindow[window] ?? seq) <= seq }
    public mutating func forget(window: UInt32) { byWindow.removeValue(forKey: window) }
}

public enum WorkspaceSwitch {
    /// The windows leaving a display when it switches workspace, top-most first: the windows
    /// showing there, plus those still on their way there from the previous switch (their
    /// restore hasn't been read back yet). Without the latter, a quick second ⌥ N left them
    /// out, and they landed on the new workspace when their restore finished.
    ///
    /// - `visible`: windows the engine sees on the display, top-most first.
    /// - `restoring`: windows being restored and their target frames.
    /// - `displayOf`: which display a frame is on.
    public static func leaving(visible: [UInt32], restoring: [UInt32: CGRect], isParked: (UInt32) -> Bool,
                               displayOf: (CGRect) -> UInt32?, display: UInt32) -> [UInt32] {
        let shown = Set(visible)
        // Restored last = top-most, so they go first; id order keeps it deterministic.
        let incoming = restoring.filter { id, target in
            !shown.contains(id) && !isParked(id) && displayOf(target) == display
        }.keys.sorted()
        return incoming + visible
    }
}

extension Parking {
    /// What a frame update means for a parked window.
    public enum Update: Equatable, Sendable {
        /// Still where it was parked.
        case keep
        /// Still off screen, somewhere else: record the new spot. macOS nudges parked windows
        /// itself (the same window sits at y 759 or 768 depending on its size), and taking that
        /// for "moved back by hand" dropped the window from its workspace while it stayed off
        /// screen: ⌘Tab then showed it on the current workspace and couldn't bring it up.
        case relearn(CGPoint)
        /// Back on screen: the user (or the app) brought it back; it's no longer parked.
        case unparked
    }

    public static func update(for frame: CGRect, entry e: ParkedWindow, offScreen: Bool) -> Update {
        if offScreen {
            if let px = e.px, let py = e.py, abs(frame.minX - px) < 6, abs(frame.minY - py) < 6 { return .keep }
            return .relearn(frame.origin)
        }
        return .unparked
    }
}

extension WorkspaceSwitch {
    /// A window stuck off screen that no workspace knows about: not parked, not being parked
    /// or restored, and (almost) entirely off every display. Picking it must bring it back
    /// onto the current workspace instead of focusing it where nobody can see it.
    public static func isStranded(parked: Bool, moving: Bool, minimized: Bool, frame: CGRect, displays: [Display]) -> Bool {
        guard !parked, !moving, !minimized else { return false }
        return !displays.contains { FocusLogic.visibleFraction(frame, on: $0.frame) >= FocusLogic.minVisibleFraction }
    }
}

extension MovesInFlight {
    /// A window closed: nothing of it is in flight any more.
    public mutating func forget(_ id: UInt32) {
        restoreArrived(id)
        while isParking(id) { parkFinished(id) }
    }
}

extension Parking {
    /// True if `frame` sits where Monarch parks windows: at one of a display's parking spots
    /// (x exact within a few points; y within the band macOS pulls parked windows up into,
    /// e.g. 759 or 768 for a spot at 799). Used at launch to find windows a crash or a lost
    /// entry left parked, without touching windows an app put off screen on purpose.
    public static func looksParked(_ frame: CGRect, displays: [Display]) -> Bool {
        displays.contains { d in
            spots(for: frame.size, screen: d.frame).contains { p in
                abs(frame.minX - p.x) <= 12 && abs(frame.minY - p.y) <= 60
            }
        }
    }
}

/// Whether a display change means bringing every window back. The workspaces belong to the
/// arrangement they were made on (`settled`). A monitor that blinks off and on (A → B → A)
/// changes nothing: it used to bring every window back and reset every display to workspace 1.
public struct DisplayArrangement: Sendable, Equatable {
    public enum Step: Equatable, Sendable {
        /// Back to the arrangement the workspaces belong to: drop any pending restore.
        case cancelPending
        /// Different: restore once it has settled (call `settle` then).
        case scheduleRestore
    }
    public private(set) var settled: Set<String>
    public init(_ settled: Set<String>) { self.settled = settled }

    public func changed(to now: Set<String>) -> Step { now == settled ? .cancelPending : .scheduleRestore }

    /// The arrangement has stayed `now` for a while. True if it really differs (restore).
    public mutating func settle(_ now: Set<String>) -> Bool {
        guard now != settled else { return false }
        settled = now
        return true
    }
    /// Not managing workspaces: the new arrangement is simply the current one.
    public mutating func accept(_ now: Set<String>) { settled = now }
}
