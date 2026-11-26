import Foundation
import IOKit
import MonarchCore
import Synchronization

/// Raw trackpad touches from Apple's private MultitouchSupport framework.
///
/// Everything private is contained here:
/// - Symbols are looked up at runtime; any missing one means gestures are unavailable.
/// - Callback ABI: `int (*)(MTDeviceRef, MTTouch *, size_t count, double timestamp, size_t frame)`.
/// - Touch records are 96 bytes. Verified on macOS 26.6 (25G83): record frame number and
///   timestamp match the callback's, states 0…7, positions 0…1, stable ids — for record 0
///   and later records (stride). Every record of every frame is still range-checked; a frame
///   with any invalid record is dropped, and if most early frames are invalid the layout is
///   treated as changed and gestures switch off. Invalid data is never treated as a gesture.
/// - Only trackpads are read: the Touch Bar is also a multitouch device (60×2 sensor, ~29:1).
///
/// Per frame the callback validates, copies at most 10 fingers into a preallocated buffer and
/// runs the recognizer. It never blocks (configuration changes are picked up with a try-lock),
/// never allocates, and only semantic events leave the thread. Continuous progress for the
/// interactive overview is published in one atomic word that the display link reads.
final class MultitouchBridge: @unchecked Sendable {
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    // The C callback takes `int` finger count and frame number (32-bit). Declaring them as Int
    // would read the full 64-bit registers, whose upper half the caller never sets.
    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias Register = @convention(c) (UnsafeMutableRawPointer?, Callback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias Dimensions = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32

    private struct API {
        let createList: CreateList, register: Register, unregister: Register
        let start: Start, stop: Stop, surface: Dimensions?, sensor: Dimensions?
    }
    private static let api: API? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY),
              let a = dlsym(h, "MTDeviceCreateList"), let b = dlsym(h, "MTRegisterContactFrameCallback"),
              let c = dlsym(h, "MTUnregisterContactFrameCallback"), let d = dlsym(h, "MTDeviceStart"),
              let e = dlsym(h, "MTDeviceStop") else { return nil }
        return API(createList: unsafeBitCast(a, to: CreateList.self), register: unsafeBitCast(b, to: Register.self),
                   unregister: unsafeBitCast(c, to: Register.self), start: unsafeBitCast(d, to: Start.self),
                   stop: unsafeBitCast(e, to: Stop.self),
                   surface: dlsym(h, "MTDeviceGetSensorSurfaceDimensions").map { unsafeBitCast($0, to: Dimensions.self) },
                   sensor: dlsym(h, "MTDeviceGetSensorDimensions").map { unsafeBitCast($0, to: Dimensions.self) })
    }()

    // Touch record layout: 96 bytes.
    private static let stride = 96, offFrame = 0, offTime = 8, offID = 16, offState = 20, offX = 32, offY = 36

    /// The live bridge (the C callback has no context pointer).
    /// Set only while no callback can run (before register / after `active` is off and drained).
    nonisolated(unsafe) private static var current: MultitouchBridge?
    /// Gate for the callback, and the number of callbacks currently inside it: `stop()` turns the
    /// gate off and waits (microseconds) until in-flight frames are done before touching state.
    private static let active = Atomic<Bool>(false)
    private static let inFlight = Atomic<Int>(0)

    /// Semantic events (on the multitouch thread), with the frame's timestamp.
    var onOutput: (@Sendable (GestureOutput) -> Void)?
    /// Called once if the touch data doesn't look like the known layout (gestures then stop).
    var onIncompatible: (@Sendable () -> Void)?

    /// Latest locked gesture for the display link: bit 63 = active, bits 40–47 fingers,
    /// bits 32–39 axis, low 32 bits = Float displacement. 0 = no locked gesture.
    let progress = Atomic<UInt64>(0)

    // Callback-thread state (only touched by the callback, or while no device is running).
    // Each trackpad has its own buffer, recognizer and settings generation: two trackpads'
    // frames never share mutable state.
    private struct Device {
        let ref: UnsafeMutableRawPointer
        var recognizer: GestureRecognizer
        var buffer = [TouchPoint](repeating: TouchPoint(id: 0, x: 0, y: 0), count: 10)
        var configGeneration = 0
    }
    private var devices: [Device] = []
    /// Which device's gesture `progress` belongs to (index + 1; 0 = none), so a second
    /// trackpad can't overwrite or clear the live gesture of the first.
    private let progressOwner = Atomic<Int>(0)
    private var framesSeen = 0, framesInvalid = 0
    private var incompatible = false

    /// The newest settings and their generation. Every device applies them itself (they used
    /// to be taken by whichever trackpad sent the next frame, so the other kept old settings).
    private let pendingConfig = Mutex<(config: GestureConfig, generation: Int)?>(nil)
    private var configGeneration = 0
    private var config: GestureConfig
    private var deviceList: CFArray?
    private(set) var isRunning = false
    private var hotplug: HotplugWatcher?

    static var isAvailable: Bool { api != nil }
    var deviceCount: Int { devices.count }
    var isIncompatible: Bool { incompatible }

    init(config: GestureConfig) { self.config = config }

    /// New settings; the callback picks them up on its next frame without ever waiting.
    func update(config: GestureConfig) {
        self.config = config
        configGeneration += 1
        let g = configGeneration
        pendingConfig.withLock { $0 = (config, g) }
    }

    /// Restarts when a multitouch device appears or disappears (Magic Trackpad on/off).
    func watchHotplug(_ onChange: @escaping @Sendable () -> Void) {
        hotplug = HotplugWatcher(onChange: onChange)
    }

    func start() {
        guard let api = Self.api, !isRunning, !incompatible,
              let list = api.createList()?.takeRetainedValue() else { return }
        deviceList = list                                       // owns the device references
        var found: [Device] = []
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let ref = UnsafeMutableRawPointer(mutating: raw)
            var w: Int32 = 0, h: Int32 = 0
            if let surface = api.surface, surface(ref, &w, &h) == 0, w > 0, h > 0 {
                guard Double(w) / Double(h) < 6 else { continue }   // Touch Bar and other strips
            }
            var r = GestureRecognizer(config: config)
            if w > 0 && h > 0 { r.aspect = (Double(w), Double(h)) }
            found.append(Device(ref: ref, recognizer: r, configGeneration: configGeneration))
        }
        guard !found.isEmpty else { deviceList = nil; return }
        devices = found
        framesSeen = 0; framesInvalid = 0
        Self.current = self
        Self.active.store(true, ordering: .sequentiallyConsistent)
        for d in devices { api.register(d.ref, Self.callback); api.start(d.ref, 0) }
        isRunning = true
    }

    /// Stops all devices. Returns `lifted` if a gesture was in progress, so the caller can
    /// release anything held (click guard, interactive overview).
    @discardableResult
    func stop() -> GestureOutput {
        guard let api = Self.api, isRunning else { return GestureOutput() }
        // Close the gate, let frames already inside finish, then disconnect and reset.
        Self.active.store(false, ordering: .sequentiallyConsistent)
        while Self.inFlight.load(ordering: .sequentiallyConsistent) != 0 { sched_yield() }
        for d in devices { api.unregister(d.ref, Self.callback); api.stop(d.ref) }
        if Self.current === self { Self.current = nil }
        isRunning = false
        var out = GestureOutput()
        for i in devices.indices { if devices[i].recognizer.reset().lifted { out.lifted = true } }
        devices.removeAll()
        deviceList = nil
        progress.store(0, ordering: .relaxed)
        progressOwner.store(0, ordering: .relaxed)
        return out
    }

    /// After sleep or a device change: fresh device list, fresh state.
    @discardableResult
    func restart() -> GestureOutput { let out = stop(); start(); return out }

    private static let callback: Callback = { device, data, count, time, frame in
        MultitouchBridge.inFlight.add(1, ordering: .sequentiallyConsistent)
        defer { MultitouchBridge.inFlight.subtract(1, ordering: .sequentiallyConsistent) }
        guard MultitouchBridge.active.load(ordering: .sequentiallyConsistent) else { return 0 }
        // Clamped: a nonsense count must never make us read past the frame's touch data.
        MultitouchBridge.current?.frame(device, data, Int(max(0, min(count, 32))), time, Int(frame))
        return 0     // the return value is ignored as far as we can tell; macOS gestures run regardless
    }

    private func frame(_ device: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?, _ count: Int, _ time: Double, _ frame: Int) {
        guard !incompatible, let di = devices.firstIndex(where: { $0.ref == device }) else { return }
        if let p = pendingConfig.withLockIfAvailable({ $0 }) ?? nil, p.generation != devices[di].configGeneration {
            devices[di].recognizer.config = p.config
            devices[di].configGeneration = p.generation
        }

        var n = 0
        if count > 0 {
            guard let data else { return }
            var valid = true
            for i in 0..<min(count, 10) {
                let b = data + i * Self.stride
                let state = b.load(fromByteOffset: Self.offState, as: Int32.self)
                let x = b.load(fromByteOffset: Self.offX, as: Float.self)
                let y = b.load(fromByteOffset: Self.offY, as: Float.self)
                let id = b.load(fromByteOffset: Self.offID, as: Int32.self)
                guard Int(b.load(fromByteOffset: Self.offFrame, as: Int32.self)) == frame,
                      abs(b.load(fromByteOffset: Self.offTime, as: Double.self) - time) < 1,
                      (0...7).contains(state), (0...255).contains(id),
                      x > -0.05, x < 1.05, y > -0.05, y < 1.05 else { valid = false; break }
                if state == 3 || state == 4 {                   // make-touch / touching: on the glass
                    devices[di].buffer[n] = TouchPoint(id: id, x: x, y: y)
                    n += 1
                }
            }
            if framesSeen < 64 {
                framesSeen += 1
                if !valid { framesInvalid += 1 }
                if framesSeen == 64 && framesInvalid > 32 {
                    incompatible = true
                    progress.store(0, ordering: .relaxed)
                    onIncompatible?()
                    return
                }
            }
            guard valid else { return }                         // never act on a bad frame
        }

        let buf = devices[di].buffer
        let out = buf.withUnsafeBufferPointer {
            devices[di].recognizer.process(UnsafeBufferPointer(rebasing: $0[0..<n]), time: time)
        }
        let me = di + 1
        ScrollBlocker.frame(locked: devices[di].recognizer.current != nil, contacts: n)
        if let s = devices[di].recognizer.current {
            // Take the live progress only if no other trackpad has a gesture going.
            let owner = progressOwner.compareExchange(expected: 0, desired: me, ordering: .relaxed).original
            if owner == 0 || owner == me {
                let bits = UInt64(Float(s.displacement).bitPattern)
                progress.store((1 << 63) | (UInt64(s.fingers) << 40) | (UInt64(s.axis.rawValue) << 32) | bits, ordering: .relaxed)
            }
        } else if out.ended != nil || out.lifted {
            if progressOwner.compareExchange(expected: me, desired: 0, ordering: .relaxed).exchanged {
                progress.store(0, ordering: .relaxed)
            }
        }
        if !out.isEmpty { onOutput?(out) }
    }

    /// Decodes `progress`.
    static func decode(_ word: UInt64) -> (fingers: Int, axis: GestureAxis, displacement: Double)? {
        guard word & (1 << 63) != 0, let axis = GestureAxis(rawValue: UInt8((word >> 32) & 0xFF)) else { return nil }
        return (Int((word >> 40) & 0xFF), axis, Double(Float(bitPattern: UInt32(word & 0xFFFF_FFFF))))
    }
}

/// IOKit notifications for multitouch devices appearing / disappearing. Event-driven, main run loop.
private final class HotplugWatcher: @unchecked Sendable {
    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0, removed: io_iterator_t = 0
    let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOServiceMatchingCallback = { refcon, iterator in
            HotplugWatcher.drain(iterator)
            if let refcon { Unmanaged<HotplugWatcher>.fromOpaque(refcon).takeUnretainedValue().onChange() }
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("AppleMultitouchDevice"), cb, me, &added)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("AppleMultitouchDevice"), cb, me, &removed)
        // Arm the notifications (existing devices are not a change).
        Self.drain(added); Self.drain(removed)
    }

    private static func drain(_ it: io_iterator_t) {
        while case let obj = IOIteratorNext(it), obj != 0 { IOObjectRelease(obj) }
    }

    deinit {
        if added != 0 { IOObjectRelease(added) }
        if removed != 0 { IOObjectRelease(removed) }
        if let port { IONotificationPortDestroy(port) }
    }
}
