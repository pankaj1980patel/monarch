import CoreGraphics
import Foundation

/// The window server's window list, read straight from the CFArray / CFDictionary it returns:
/// only the two or three keys needed per window, nothing converted to Swift dictionaries
/// (bridging every window's info dictionary was the expensive part).
enum WindowList {
    /// On-screen normal windows (layer 0), front to back.
    static func zOrder() -> [UInt32] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) else { return [] }
        let n = CFArrayGetCount(list)
        var out: [UInt32] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let d = dict(list, i)
            guard int(d, kCGWindowLayer) == 0, let id = int(d, kCGWindowNumber) else { continue }
            out.append(UInt32(truncatingIfNeeded: id))
        }
        return out
    }

    /// On-screen normal windows with their current frames, front to back. Straight from the
    /// window server, so it's never behind: Monarch's own copy of a frame is updated only when
    /// the app's move notification has been read (and Chrome is slow to send those).
    static func onScreen() -> [(id: UInt32, frame: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) else { return [] }
        let n = CFArrayGetCount(list)
        var out: [(id: UInt32, frame: CGRect)] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let d = dict(list, i)
            guard int(d, kCGWindowLayer) == 0, let id = int(d, kCGWindowNumber), let b = value(d, kCGWindowBounds),
                  CFGetTypeID(b) == CFDictionaryGetTypeID(),
                  let r = CGRect(dictionaryRepresentation: unsafeDowncast(b, to: CFDictionary.self)) else { continue }
            out.append((UInt32(truncatingIfNeeded: id), r))
        }
        return out
    }

    /// One window's current frame from the window server (nil if it doesn't exist). Safe
    /// from any thread: used on app queues to check where a window really is.
    static func frame(of id: UInt32) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)), CFArrayGetCount(list) > 0,
              let b = value(dict(list, 0), kCGWindowBounds), CFGetTypeID(b) == CFDictionaryGetTypeID() else { return nil }
        return CGRect(dictionaryRepresentation: unsafeDowncast(b, to: CFDictionary.self))
    }

    /// The front-most normal window containing `p` (global, top-left coordinates).
    static func topWindow(at p: CGPoint) -> UInt32? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) else { return nil }
        for i in 0..<CFArrayGetCount(list) {
            let d = dict(list, i)
            guard int(d, kCGWindowLayer) == 0, let b = value(d, kCGWindowBounds),
                  CFGetTypeID(b) == CFDictionaryGetTypeID(),
                  let r = CGRect(dictionaryRepresentation: unsafeBitCast(b, to: CFDictionary.self)), r.contains(p),
                  let id = int(d, kCGWindowNumber) else { continue }
            return UInt32(truncatingIfNeeded: id)
        }
        return nil
    }

    /// Every window that exists, on screen or not.
    static func existingIDs() -> Set<UInt32> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) else { return [] }
        let n = CFArrayGetCount(list)
        var out = Set<UInt32>(minimumCapacity: n)
        for i in 0..<n { if let id = int(dict(list, i), kCGWindowNumber) { out.insert(UInt32(truncatingIfNeeded: id)) } }
        return out
    }

    private static func dict(_ list: CFArray, _ i: CFIndex) -> CFDictionary {
        unsafeBitCast(CFArrayGetValueAtIndex(list, i), to: CFDictionary.self)
    }

    private static func value(_ d: CFDictionary, _ key: CFString) -> CFTypeRef? {
        guard let v = CFDictionaryGetValue(d, Unmanaged.passUnretained(key).toOpaque()) else { return nil }
        return Unmanaged<CFTypeRef>.fromOpaque(v).takeUnretainedValue()
    }

    private static func int(_ d: CFDictionary, _ key: CFString) -> Int? {
        guard let v = value(d, key), CFGetTypeID(v) == CFNumberGetTypeID() else { return nil }
        var x = 0
        return CFNumberGetValue(unsafeBitCast(v, to: CFNumber.self), .longType, &x) ? x : nil
    }
}
