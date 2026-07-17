import AppKit
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Modifier / display helpers

/// Convert AppKit modifier flags to the Carbon `KeyModifiers` layout RegisterEventHotKey expects.
func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if flags.contains(.command) { m |= UInt32(cmdKey) }
    if flags.contains(.shift)   { m |= UInt32(shiftKey) }
    if flags.contains(.option)  { m |= UInt32(optionKey) }
    if flags.contains(.control) { m |= UInt32(controlKey) }
    return m
}

/// Human-readable label for a key event, e.g. "⌘⇧P".
func describeShortcut(_ event: NSEvent) -> String {
    var s = ""
    if event.modifierFlags.contains(.control) { s += "⌃" }
    if event.modifierFlags.contains(.option)  { s += "⌥" }
    if event.modifierFlags.contains(.shift)   { s += "⇧" }
    if event.modifierFlags.contains(.command) { s += "⌘" }
    s += (event.charactersIgnoringModifiers ?? "").uppercased()
    return s
}

// MARK: - Global hotkey (system-wide, works even without app focus)

final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onTrigger: (() -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), Self.callback, 1, &spec, ptr, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x50524F58) /* "PROX" */, id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
    }

    // Non-capturing C callback; reaches `self` through the userData pointer.
    private static let callback: EventHandlerUPP = { _, _, userData in
        guard let userData else { return noErr }
        let obj = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async { obj.onTrigger?() }
        return noErr
    }
}

// MARK: - Login items (launch at login)

enum LoginItemService {
    /// SMAppService.mainApp needs a real .app bundle; unavailable when run as a bare binary.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled { try service.register() } else { try service.unregister() }
    }
}
