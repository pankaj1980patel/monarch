import Carbon.HIToolbox
import MonarchCore

/// Global shortcuts through Carbon's RegisterEventHotKey. The system matches the key combo and
/// wakes us only for our own shortcuts, so no keystroke ever passes through this app otherwise:
/// no event tap and no Input Monitoring permission.
@MainActor
final class HotkeyManager {
    struct Registration { let shortcut: Shortcut; let ok: Bool }

    /// Called with the action and the key event's timestamp (seconds since boot).
    var handler: ((Action, Double) -> Void)?
    private(set) var registrations: [Action: Registration] = [:]

    private var refs: [EventHotKeyRef] = []
    // Short-lived keys (the switcher's ⌘← ⌘→ ⌘↩ ⌘⎋ while it is open), ids from 1000.
    private var tempRefs: [EventHotKeyRef] = []
    private var tempHandlers: [UInt32: () -> Void] = [:]
    private var actions: [UInt32: Action] = [:]
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x4D4E_5243   // 'MNRC'

    func install() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard err == noErr, hk.signature == HotkeyManager.signature else { return OSStatus(eventNotHandledErr) }
            let time = GetEventTime(event)
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { mgr.fire(hk.id, time) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    func register(_ bindings: [(Action, Shortcut)]) {
        unregisterAll()
        for (i, (action, shortcut)) in bindings.enumerated() {
            let id = UInt32(i + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                             EventHotKeyID(signature: Self.signature, id: id),
                                             GetEventDispatcherTarget(), 0, &ref)
            let ok = status == noErr && ref != nil
            if ok, let ref { refs.append(ref); actions[id] = action }
            registrations[action] = Registration(shortcut: shortcut, ok: ok)
        }
    }

    func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        actions.removeAll()
        registrations.removeAll()
    }

    /// Registers keys that exist only for a moment (while a panel is open). Replaces any previous set.
    func registerTemporary(_ keys: [(Shortcut, () -> Void)]) {
        unregisterTemporary()
        for (i, (shortcut, action)) in keys.enumerated() {
            let id = UInt32(1000 + i)
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                   GetEventDispatcherTarget(), 0, &ref) == noErr, let ref {
                tempRefs.append(ref)
                tempHandlers[id] = action
            }
        }
    }

    func unregisterTemporary() {
        for r in tempRefs { UnregisterEventHotKey(r) }
        tempRefs.removeAll()
        tempHandlers.removeAll()
    }

    private func fire(_ id: UInt32, _ time: Double) {
        if let temp = tempHandlers[id] { temp(); return }
        guard let action = actions[id] else { return }
        handler?(action, time)
    }
}
