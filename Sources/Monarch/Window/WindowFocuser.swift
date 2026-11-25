import AppKit
import ApplicationServices
import Synchronization

/// Focuses exactly one window, without bringing the app's other windows forward.
///
/// Uses the same private SkyLight calls as AltTab and yabai: make the process frontmost for
/// that one window, then post the two "make key window" event records, then AXRaise.
/// Activating the app the public way brings every one of its windows forward — the iTerm
/// "both screens come forward" bug from the Hammerspoon days.
///
/// The private symbols are looked up at runtime. If a macOS update removes them, focusing
/// falls back to plain activation + AXRaise instead of crashing.
enum WindowFocuser {
    private typealias GetPSN = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias PostRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32

    private struct Symbols: @unchecked Sendable {
        let getPSN: GetPSN
        let setFront: SetFront
        let post: PostRecord
    }

    private static let symbols: Symbols? = {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let h = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        guard let a = dlsym(h, "GetProcessForPID"),
              let b = dlsym(h, "_SLPSSetFrontProcessWithOptions"),
              let c = dlsym(h, "SLPSPostEventRecordTo") else { return nil }
        return Symbols(getPSN: unsafeBitCast(a, to: GetPSN.self),
                       setFront: unsafeBitCast(b, to: SetFront.self),
                       post: unsafeBitCast(c, to: PostRecord.self))
    }()

    static var usesPrivateAPI: Bool { symbols != nil }

    /// Newer requests cancel older ones still waiting on an app queue, so sweeping the mouse
    /// back and forth never leaves stale focus changes fighting each other.
    private static let generation = Atomic<UInt64>(0)

    /// The WindowServer calls don't involve the app at all, so they run here right away instead
    /// of waiting behind the app's queued window reads (a busy terminal or browser).
    private static let focusQueue = DispatchQueue(label: "monarch.focus", qos: .userInteractive)

    /// Focuses window `id` of `app`. Returns immediately.
    /// - On the focus queue: make the process frontmost for that window and make it key
    ///   (WindowServer only: needs the pid and window id, not the app's attention).
    /// - On the app's queue: AXRaise, the only part that talks to the app.
    static func focus(_ id: CGWindowID, of app: TrackedApp, perf: PerformanceMonitor, metric: String, since start: Double) {
        let gen = generation.add(1, ordering: .relaxed).newValue
        let pid = app.pid
        focusQueue.async {
            guard generation.load(ordering: .relaxed) == gen else { return }
            var raised = false
            if let s = symbols {
                var psn = ProcessSerialNumber()
                if s.getPSN(pid, &psn) == noErr {
                    _ = s.setFront(&psn, id, 0x200)          // kCPSUserGenerated
                    makeKeyWindow(&psn, id, s.post)
                    raised = true
                    perf.record(metric, since: start)
                }
            }
            if !raised { activateFallback(pid) }
            app.queue.async {
                guard generation.load(ordering: .relaxed) == gen, let win = app.element(for: id) else { return }
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                if !raised { perf.record(metric, since: start) }
            }
        }
    }

    /// The window-server event records that make `id` the key window of its process.
    private static func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ id: CGWindowID, _ post: PostRecord) {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        var wid = id
        withUnsafeBytes(of: &wid) { raw in for i in 0..<4 { bytes[0x3c + i] = raw[i] } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes.withUnsafeMutableBufferPointer { buf in
            buf[0x08] = 0x01; _ = post(&psn, buf.baseAddress!)
            buf[0x08] = 0x02; _ = post(&psn, buf.baseAddress!)
        }
    }

    private static func activateFallback(_ pid: pid_t) {
        DispatchQueue.main.async { NSRunningApplication(processIdentifier: pid)?.activate() }
    }
}
