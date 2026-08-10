import Carbon.HIToolbox
import AppKit
import VoiceCore

/// Global hotkeys via Carbon `RegisterEventHotKey` — works system-wide with
/// no accessibility permission, and delivers both pressed and released
/// events, which is what makes one shortcut carry the pendant's whole
/// grammar: tap (released under the threshold) plays, hold records.
@MainActor
final class HotkeyCenter {
    struct Handlers {
        var onTap: () -> Void
        var onHoldBegan: () -> Void
        var onHoldEnded: () -> Void
    }

    /// Hold threshold: pressed longer than this is a record gesture.
    static let holdThresholdMs = 300

    private struct Registration {
        var ref: EventHotKeyRef?
        var handlers: Handlers
        var isDown = false
        var holdActive = false
        var holdTimer: Timer?
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextId: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    init() {
        installHandlerOnce()
    }

    /// Registers `binding` and returns a token for `unregister`. Returns nil
    /// when the system rejects the combo (already taken by another app).
    func register(_ binding: KeyBinding, handlers: Handlers) -> UInt32? {
        let id = nextId
        nextId += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x564C4B54) /* "VLKT" */, id: id)
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        registrations[id] = Registration(ref: ref, handlers: handlers)
        return id
    }

    func unregister(_ token: UInt32) {
        guard let registration = registrations.removeValue(forKey: token) else { return }
        registration.holdTimer?.invalidate()
        if let ref = registration.ref { UnregisterEventHotKey(ref) }
    }

    private func installHandlerOnce() {
        guard eventHandler == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let kind = GetEventKind(event)
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                center.handle(id: hotKeyID.id, kind: kind)
            }
            return noErr
        }, eventTypes.count, &eventTypes, selfPointer, &eventHandler)
    }

    private func handle(id: UInt32, kind: UInt32) {
        guard var registration = registrations[id] else { return }
        switch Int(kind) {
        case kEventHotKeyPressed:
            guard !registration.isDown else { return } // key-repeat noise
            registration.isDown = true
            registration.holdActive = false
            let timer = Timer(timeInterval: Double(Self.holdThresholdMs) / 1000,
                              repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, var current = self.registrations[id],
                          current.isDown else { return }
                    current.holdActive = true
                    self.registrations[id] = current
                    current.handlers.onHoldBegan()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            registration.holdTimer = timer
            registrations[id] = registration
        case kEventHotKeyReleased:
            guard registration.isDown else { return }
            registration.holdTimer?.invalidate()
            registration.holdTimer = nil
            registration.isDown = false
            let wasHold = registration.holdActive
            registration.holdActive = false
            registrations[id] = registration
            if wasHold {
                registration.handlers.onHoldEnded()
            } else {
                registration.handlers.onTap()
            }
        default:
            break
        }
    }

    /// "⌘⌥R"-style label for menus and Settings.
    static func describe(_ binding: KeyBinding) -> String {
        var parts = ""
        if binding.modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if binding.modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if binding.modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if binding.modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        return parts + keyName(binding.keyCode)
    }

    private static func keyName(_ keyCode: UInt32) -> String {
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "#\(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        var keysDown: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw in
            UCKeyTranslate(raw.bindMemory(to: UCKeyboardLayout.self).baseAddress,
                           UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                           UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                           &keysDown, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
