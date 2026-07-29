import AppKit
import ApplicationServices

/// Accessibility is only needed to *type* ⌘V into the previous app. Everything
/// else — recording history, the hot key, copying — works without it.
enum Permissions {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt with the "Open System Settings" button.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
