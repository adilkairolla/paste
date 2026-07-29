import AppKit
import Carbon.HIToolbox

/// Global hot keys via Carbon's `RegisterEventHotKey`.
///
/// Deliberately not a `CGEventTap`: a tap would require Accessibility
/// permission just to open the deck, and the app should be usable the moment
/// it launches.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    struct Shortcut: Equatable {
        /// Virtual key code (`kVK_*`).
        var keyCode: UInt32
        /// Carbon modifier mask (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
        var modifiers: UInt32

        static let defaultDeck = Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
    }

    private var handlerRef: EventHandlerRef?
    private var registrations: [UInt32: (ref: EventHotKeyRef?, action: () -> Void)] = [:]
    private var nextID: UInt32 = 1

    private init() {}

    /// Replaces any previously registered shortcut for `name`.
    @discardableResult
    func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x50_44_43_4B), id: id) // 'PDCK'
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &reference
        )
        guard status == noErr else { return false }

        registrations[id] = (reference, action)
        return true
    }

    func unregisterAll() {
        for (_, registration) in registrations {
            if let reference = registration.ref { UnregisterEventHotKey(reference) }
        }
        registrations.removeAll()
    }

    fileprivate func handle(id: UInt32) {
        registrations[id]?.action()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyEventHandler, 1, &eventType, nil, &handlerRef)
    }
}

/// C callback — Carbon can't take a Swift closure.
private let hotKeyEventHandler: EventHandlerUPP = { _, event, _ in
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    DispatchQueue.main.async { HotKeyCenter.shared.handle(id: hotKeyID.id) }
    return noErr
}

// MARK: - Display helpers

extension HotKeyCenter.Shortcut {
    /// "⌘⇧V" — for menus and the settings recorder.
    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        text += KeyCodeNames.name(for: keyCode)
        return text
    }

    /// The AppKit modifier flags matching this Carbon mask.
    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    /// Builds a shortcut from a recorded AppKit event.
    static func from(event: NSEvent) -> HotKeyCenter.Shortcut {
        var mask: UInt32 = 0
        if event.modifierFlags.contains(.command) { mask |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift) { mask |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option) { mask |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mask |= UInt32(controlKey) }
        return HotKeyCenter.Shortcut(keyCode: UInt32(event.keyCode), modifiers: mask)
    }
}

enum KeyCodeNames {
    private static let named: [UInt32: String] = [
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "↩",
        UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Escape): "⎋",
        UInt32(kVK_Delete): "⌫",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]

    /// Resolves the printed character for a key code using the active layout,
    /// so the recorder shows the right glyph on non-US keyboards.
    static func name(for keyCode: UInt32) -> String {
        if let name = named[keyCode] { return name }

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "Key \(keyCode)" }

        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}
