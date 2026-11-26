import Foundation
import MonarchCore

/// Turns macOS's own ⌘Tab / ⌘⇧Tab / ⌘` shortcuts off while Monarch owns them, so the
/// combos reach Monarch's ordinary Carbon hotkeys and no keyboard event tap is needed.
///
/// Private SkyLight call (the same one AltTab uses), looked up at runtime. The change lasts
/// for the login session, so Monarch turns them back on whenever it stops owning ⌘Tab and on
/// quit. If Monarch crashes, Hammerspoon's own ⌘Tab (an event tap) takes over again.
enum SystemSwitcher {
    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32
    private typealias IsEnabled = @convention(c) (Int32) -> Bool

    /// Symbolic hotkey ids (see `SystemShortcuts`).
    private static let ids: [Int32] = SystemShortcuts.all.map(\.id)

    private struct Fns: @unchecked Sendable { let set: SetEnabled; let get: IsEnabled }
    private static let fns: Fns? = {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let h = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        guard let s = dlsym(h, "CGSSetSymbolicHotKeyEnabled"), let g = dlsym(h, "CGSIsSymbolicHotKeyEnabled") else { return nil }
        return Fns(set: unsafeBitCast(s, to: SetEnabled.self), get: unsafeBitCast(g, to: IsEnabled.self))
    }()

    static var isAvailable: Bool { fns != nil }

    /// `false` hands ⌘Tab to Monarch; `true` gives it back to macOS.
    static func setSystemEnabled(_ enabled: Bool) {
        guard let fns else { return }
        for id in ids { _ = fns.set(id, enabled) }
    }

    /// Turns off exactly the system shortcuts in `owned` (Monarch registered them), and back
    /// on every other one.
    static func setOwned(_ owned: Set<Int32>) {
        guard let fns else { return }
        for id in ids { _ = fns.set(id, !owned.contains(id)) }
    }

    /// If Monarch crashes, put macOS's own ⌘Tab back before the process dies, so the user is
    /// never left without a switcher. Best effort: the handler only calls the already-resolved
    /// function pointer, then re-raises the signal so the crash report is still written.
    ///
    /// The handler allocates nothing (no arrays): it calls the function pointer three times.
    /// It runs on its own signal stack, so a stack overflow can still run it. SIGKILL, jetsam
    /// and force-quit can't be caught at all: that's why Monarch also turns macOS's ⌘Tab back
    /// on first thing at every launch.
    static func installCrashGuard() {
        guard let fns else { return }
        crashSet = fns.set
        // Alternate stack for the handler (a stack overflow leaves no room on the normal one).
        let size = Int(SIGSTKSZ) * 4
        if let mem = malloc(size) {
            var ss = stack_t(ss_sp: mem, ss_size: size, ss_flags: 0)
            sigaltstack(&ss, nil)
        }
        for sig in [SIGTRAP, SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { s in
                // Default first: a second fault inside the SkyLight call ends the process
                // instead of re-entering here. The SkyLight call isn't async-signal-safe and can
                // block (e.g. on a lock the crashed thread held): alarm(1) ends the process
                // after a second either way, instead of hanging with macOS ⌘Tab off.
                signal(s, SIG_DFL)
                alarm(1)
                if let set = SystemSwitcher.crashSet { _ = set(1, true); _ = set(2, true); _ = set(6, true) }
                raise(s)
            }
            action.sa_flags = SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, nil)
        }
    }
    nonisolated(unsafe) private static var crashSet: SetEnabled?

    static var systemEnabled: Bool { fns.map { f in ids.allSatisfy { f.get($0) } } ?? true }
}
