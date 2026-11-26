import AppKit
import ApplicationServices
import Synchronization
import MonarchCore

/// What the window engine knows about one window. Kept on the main actor.
struct ManagedWindow: Sendable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    var title: String
    var frame: CGRect
    var isMinimized: Bool
}

/// Changes reported by an app's queue to the main-actor cache.
enum WindowEvent: Sendable {
    case discovered(pid_t, [ManagedWindow])
    case upsert(ManagedWindow)
    case removed(pid_t, CGWindowID)
    case focused(pid_t, CGWindowID?)
}

/// One running app: its AX element, its own serial queue and its AXObserver.
///
/// Every AX call for this app runs on `queue`, so a slow or hung app only ever blocks
/// its own queue — never the main thread or another app's actions. Different apps'
/// queues run in parallel, which is what makes multi-window operations fast.
final class TrackedApp: @unchecked Sendable {
    let pid: pid_t
    let name: String
    let element: AXUIElement
    let queue: DispatchQueue

    // Created once in init and never changed, so the app's queue can read it without a race.
    // Its run-loop source lives on the main run loop and is removed there in `invalidate()`;
    // `isLive` tells the queue to stop subscribing after that.
    private let observer: AXObserver?
    private let isLive = Atomic<Bool>(true)
    private let report: @Sendable (WindowEvent) -> Void

    // Queue-confined state.
    private var windows: [(ref: AXRef, id: CGWindowID)] = []
    private var pendingFrame = Set<CGWindowID>()
    private var pendingTitle = Set<CGWindowID>()
    /// Windows the engine has been told about (a first read succeeded and was reported).
    /// A window can be tracked here without being announced: its first read timed out, or it
    /// was adopted by the focus handler. Those are announced by whichever path reads them next.
    private var announcements = WindowAnnouncements()
    private var appNotificationsAdded = false
    /// The window list couldn't be read at the last discovery (all retries failed).
    private var windowsUnread = false
    /// When `ensureSubscribed` last re-ran discovery (rate limit).
    private var resubscribe = DiscoveryRetry.Limiter()

    private static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
    ]
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification,
    ]

    @MainActor
    init(pid: pid_t, name: String, report: @escaping @Sendable (WindowEvent) -> Void) {
        self.pid = pid
        self.name = name
        self.element = AXUIElementCreateApplication(pid)
        self.report = report
        // userInitiated: everything here answers something the user did (a snap, a switch, a
        // focus), but none of it draws frames; userInteractive is for the main thread's work.
        self.queue = DispatchQueue(label: "monarch.app.\(pid)", qos: .userInitiated)

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let app = Unmanaged<TrackedApp>.fromOpaque(refcon).takeUnretainedValue()
            app.receive(notification as String, AXRef(element))
        }
        if AXObserverCreate(pid, callback, &obs) == .success, let obs {
            observer = obs
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        } else {
            observer = nil
        }
    }

    /// Stops notifications. Must run on the main thread (same run loop the source is on).
    @MainActor
    func invalidate() {
        isLive.store(false, ordering: .sequentiallyConsistent)
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    // MARK: Discovery

    /// Subscribes to the app's notifications and reads its current windows. Apps that are
    /// still launching often refuse AX for a moment, so this retries a few times.
    func start(attempt: Int = 0) {
        queue.async { [self] in
            guard let observer, isLive.load(ordering: .sequentiallyConsistent) else { return }
            if !appNotificationsAdded {
                var ok = true
                for n in Self.appNotifications {
                    let err = AXObserverAddNotification(observer, element, n as CFString, refcon)
                    if err != .success && err != .notificationAlreadyRegistered { ok = false }
                }
                appNotificationsAdded = ok
                if !ok && attempt < 4 {
                    let delay = 0.25 * pow(2, Double(attempt))
                    queue.asyncAfter(deadline: .now() + delay) { self.start(attempt: attempt + 1) }
                    return
                }
            }
            // An app that's still launching (or busy) may not answer: retry, like the
            // notifications above, instead of taking "no answer" for "no windows".
            guard let els = AX.elementsIfReadable(element, kAXWindowsAttribute) else {
                if let delay = DiscoveryRetry.delay(after: attempt) {
                    queue.asyncAfter(deadline: .now() + delay) { self.start(attempt: attempt + 1) }
                } else {
                    windowsUnread = true          // ensureSubscribed tries again when it's used
                }
                return
            }
            windowsUnread = false
            var found: [ManagedWindow] = []
            for el in els {
                if let w = track(el) { found.append(w) }
            }
            for w in found { announcements.announced(w.id) }
            report(.discovered(pid, found))
            report(.focused(pid, AX.element(element, kAXFocusedWindowAttribute).flatMap(AX.windowID)))
        }
    }

    /// Re-runs discovery if the app refused its notifications or its window list at launch
    /// (all retries failed), so its windows are seen once it's in use. At most once every 10 s:
    /// an app that keeps refusing isn't set up again on every activation. Cheap no-op otherwise.
    func ensureSubscribed() {
        queue.async { [self] in
            guard !appNotificationsAdded || windowsUnread, isLive.load(ordering: .sequentiallyConsistent) else { return }
            guard resubscribe.allow(now: ProcessInfo.processInfo.systemUptime) else { return }
            start()
        }
    }

    /// Starts tracking one window element; returns nil for non-standard windows or when its
    /// first read fails (it stays tracked, unannounced). Queue only.
    private func track(_ el: AXUIElement) -> ManagedWindow? {
        guard let id = adopt(el) else { return nil }
        return snapshot(el, id)
    }

    /// Adds a standard window to the tracked list and subscribes to it; returns its id.
    private func adopt(_ el: AXUIElement) -> CGWindowID? {
        guard AX.isStandardWindow(el), let id = AX.windowID(el) else { return nil }
        if !windows.contains(where: { $0.id == id }) {
            windows.append((AXRef(el), id))
            if let observer, isLive.load(ordering: .sequentiallyConsistent) {
                for n in Self.windowNotifications {
                    AXObserverAddNotification(observer, el, n as CFString, refcon)
                }
            }
        }
        return id
    }

    /// Reports a window's current state to the engine (an add if it wasn't announced yet).
    @discardableResult
    private func upsert(_ el: AXUIElement, _ id: CGWindowID) -> Bool {
        guard let w = snapshot(el, id) else { return false }
        announcements.announced(id)
        report(.upsert(w))
        return true
    }

    /// Announces a tracked window the engine hasn't heard of yet. No-op if already announced.
    private func announceIfNeeded(_ el: AXUIElement, _ id: CGWindowID) {
        if announcements.needsAnnouncing(id) { upsert(el, id) }
    }

    private static let snapshotAttributes = [kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute, kAXMinimizedAttribute]

    /// Frame, title and minimized state in one round trip to the app.
    private func snapshot(_ el: AXUIElement, _ id: CGWindowID) -> ManagedWindow? {
        guard let v = AX.values(el, Self.snapshotAttributes),
              let p = AX.decodePoint(v[0]), let s = AX.decodeSize(v[1]) else { return nil }
        return ManagedWindow(id: id, pid: pid, title: (v[2] as? String) ?? "",
                             frame: CGRect(origin: p, size: s), isMinimized: AX.decodeBool(v[3]) ?? false)
    }

    /// The AX element of a tracked window. Queue only.
    func element(for id: CGWindowID) -> AXUIElement? {
        windows.first(where: { $0.id == id })?.ref.element
    }

    private func knownID(_ el: AXUIElement) -> CGWindowID? {
        windows.first(where: { CFEqual($0.ref.element, el) })?.id
    }

    // MARK: Notifications

    /// Called on the main run loop by the observer. Does no AX work here: hands off to the queue.
    private func receive(_ notification: String, _ ref: AXRef) {
        queue.async { [self] in handle(notification, ref.element) }
    }

    private func handle(_ n: String, _ el: AXUIElement) {
        switch n {
        case kAXWindowCreatedNotification:
            if let id = adopt(el), upsert(el, id) { return }
            // Some apps set the role / subrole a moment after creating the window, and a first
            // read can time out: look once more. Whatever read it first (this retry, the focus
            // handler, a move) announces it; this only fills in if nothing did.
            let ref = AXRef(el)
            queue.asyncAfter(deadline: .now() + 0.15) { [self] in
                if let id = knownID(ref.element) ?? adopt(ref.element) { announceIfNeeded(ref.element, id) }
            }

        case kAXUIElementDestroyedNotification:
            // The element is already dead, so match it against what we stored.
            if let i = windows.firstIndex(where: { CFEqual($0.ref.element, el) }) {
                let id = windows.remove(at: i).id
                if announcements.destroyed(id) { report(.removed(pid, id)) }
            }

        case kAXFocusedWindowChangedNotification:
            let id = knownID(el) ?? adopt(el)
            if let id { announceIfNeeded(el, id) }          // before .focused, so the engine knows it
            report(.focused(pid, id))

        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            // Dragging fires these dozens of times a second: read the frame at most every 50 ms.
            guard let id = knownID(el), pendingFrame.insert(id).inserted else { return }
            let ref = AXRef(el)
            queue.asyncAfter(deadline: .now() + 0.05) { [self] in
                pendingFrame.remove(id)
                upsert(ref.element, id)
            }

        case kAXTitleChangedNotification:
            // Terminals and browsers retitle constantly; titles are only shown in the switcher and
            // overview, so read at most every 0.5 s per window.
            guard let id = knownID(el), pendingTitle.insert(id).inserted else { return }
            let ref = AXRef(el)
            queue.asyncAfter(deadline: .now() + 0.5) { [self] in
                pendingTitle.remove(id)
                upsert(ref.element, id)
            }

        default:   // minimized, deminimized
            if let id = knownID(el) { upsert(el, id) }
        }
    }
}
