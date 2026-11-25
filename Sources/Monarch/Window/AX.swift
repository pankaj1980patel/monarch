import ApplicationServices
import CoreGraphics

/// Private but long-stable call (used by Hammerspoon, AltTab, Rectangle, AeroSpace) that maps an
/// AX window element to its WindowServer ID. One lookup per window, then cached.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// AXUIElement is an immutable CF reference that is safe to pass between threads;
/// this wrapper says so to Swift 6's checker.
struct AXRef: @unchecked Sendable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}

/// Thin, allocation-light wrappers over the AX C API. Every call here is an IPC round trip
/// to the target app, so callers must be on that app's queue, never on the main thread.
enum AX {
    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(el, &id) == .success && id != 0 ? id : nil
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let v, CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((v as! CFBoolean))
    }

    @discardableResult
    static func setBool(_ el: AXUIElement, _ attr: String, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(el, attr as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse)!) == .success
    }

    /// Immutable after creation, so sharing it across app queues is safe.
    nonisolated(unsafe) private static let frameAttributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray

    /// Position and size in one round trip.
    static func frame(_ el: AXUIElement) -> CGRect? {
        var v: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, frameAttributes, [], &v) == .success,
              let arr = v as? [AnyObject], arr.count == 2,
              let p = decodePoint(arr[0]), let s = decodeSize(arr[1]) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Several attributes in one round trip. An attribute the element doesn't have comes back
    /// as nil (the API returns an error value in its place).
    static func values(_ el: AXUIElement, _ attrs: [String]) -> [AnyObject?]? {
        var v: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, attrs as CFArray, [], &v) == .success,
              let arr = v as? [AnyObject], arr.count == attrs.count else { return nil }
        return arr.map { obj in
            if CFGetTypeID(obj) == AXValueGetTypeID(), AXValueGetType(obj as! AXValue) == .axError { return nil }
            return obj
        }
    }

    static func decodePoint(_ obj: AnyObject?) -> CGPoint? {
        guard let obj, CFGetTypeID(obj) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(obj as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func decodeSize(_ obj: AnyObject?) -> CGSize? {
        guard let obj, CFGetTypeID(obj) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(obj as! AXValue, .cgSize, &s) ? s : nil
    }

    static func decodeBool(_ obj: AnyObject?) -> Bool? {
        guard let obj, CFGetTypeID(obj) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((obj as! CFBoolean))
    }

    static func point(_ el: AXUIElement) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue((v as! AXValue), .cgPoint, &p) ? p : nil
    }

    static func size(_ el: AXUIElement) -> CGSize? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue((v as! AXValue), .cgSize, &s) ? s : nil
    }

    @discardableResult
    static func setPoint(_ el: AXUIElement, _ p: CGPoint) -> Bool {
        var p = p
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) == .success
    }

    @discardableResult
    static func setSize(_ el: AXUIElement, _ s: CGSize) -> Bool {
        var s = s
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) == .success
    }

    /// Only real document windows (not sheets, popovers, palettes or tooltips).
    static func isStandardWindow(_ el: AXUIElement) -> Bool {
        string(el, kAXRoleAttribute) == kAXWindowRole && string(el, kAXSubroleAttribute) == kAXStandardWindowSubrole
    }
}
