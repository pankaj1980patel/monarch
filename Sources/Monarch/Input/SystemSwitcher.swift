import Foundation

/// Turns macOS's own ⌘Tab / ⌘⇧Tab / ⌘` shortcuts off while Monarch owns them, so the
/// combos reach Monarch's ordinary Carbon hotkeys and no keyboard event tap is needed.
///
/// Private SkyLight call (the same one AltTab uses), looked up at runtime. The change lasts
/// for the login session, so Monarch turns them back on whenever it stops owning ⌘Tab and on
/// quit. If Monarch crashes, Hammerspoon's own ⌘Tab (an event tap) takes over again.
enum SystemSwitcher {
    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32
    private typealias IsEnabled = @convention(c) (Int32) -> Bool

    /// Symbolic hotkey ids: 1 = ⌘Tab, 2 = ⌘⇧Tab, 6 = ⌘` (the key above Tab).
    private static let ids: [Int32] = [1, 2, 6]

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

    /// If Monarch crashes, put macOS's own ⌘Tab back before the process dies, so the user is
    /// never left without a switcher. Best effort: the handler only calls the already-resolved
    /// function pointer, then re-raises the signal so the crash report is still written.
    static func installCrashGuard() {
        guard let fns else { return }
        crashSet = fns.set
        for sig in [SIGTRAP, SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(sig) { s in
                if let set = SystemSwitcher.crashSet { for id in [Int32(1), 2, 6] { _ = set(id, true) } }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }
    nonisolated(unsafe) private static var crashSet: SetEnabled?

    static var systemEnabled: Bool { fns.map { f in ids.allSatisfy { f.get($0) } } ?? true }
}
