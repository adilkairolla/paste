import AppKit
import Carbon.HIToolbox
import PasteDeckCore

/// Puts a stored clipping back on the pasteboard and, if allowed, types ⌘V
/// into whichever app the user came from.
final class PasteService {
    private let store: ClipStore
    private weak var monitor: ClipboardMonitor?

    init(store: ClipStore, monitor: ClipboardMonitor?) {
        self.store = store
        self.monitor = monitor
    }

    /// Restores every representation, grouped exactly as it was copied, so the
    /// receiving app gets the richest form it understands.
    @discardableResult
    func copyToPasteboard(item: ClipItem, markAsInternal: Bool = true) -> Bool {
        guard let payloads = try? store.payloads(itemID: item.id), !payloads.isEmpty else { return false }

        var grouped: [Int: [ClipPayload]] = [:]
        for payload in payloads {
            grouped[payload.pasteboardIndex, default: []].append(payload)
        }

        var pasteboardItems: [NSPasteboardItem] = []
        for index in grouped.keys.sorted() {
            let pasteboardItem = NSPasteboardItem()
            var wroteSomething = false
            for payload in grouped[index]!.sorted(by: { $0.order < $1.order }) {
                guard let data = store.data(for: payload) else { continue }
                pasteboardItem.setData(data, forType: NSPasteboard.PasteboardType(payload.uti))
                wroteSomething = true
            }
            if wroteSomething { pasteboardItems.append(pasteboardItem) }
        }
        guard !pasteboardItems.isEmpty else { return false }

        if markAsInternal, let first = pasteboardItems.first {
            first.setData(Data([1]), forType: NSPasteboard.PasteboardType(UTI.internalMarker))
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let didWrite = pasteboard.writeObjects(pasteboardItems)
        monitor?.ignoreNextChange(changeCount: pasteboard.changeCount)

        if didWrite {
            try? store.markUsed(itemID: item.id)
        }
        return didWrite
    }

    /// Copies, returns focus to `application`, then synthesises ⌘V.
    /// Falls back to copy-only when Accessibility isn't granted.
    ///
    /// The caller must already have ordered the deck out — see
    /// `DeckWindowController.hide(immediately:)`. While a key window belongs to
    /// PasteDeck the target app can't come forward, and a ⌘V posted into that
    /// gap goes nowhere.
    func paste(item: ClipItem, into application: NSRunningApplication?, autoPaste: Bool) {
        guard copyToPasteboard(item: item) else {
            Log.error("paste aborted: nothing could be written to the pasteboard")
            return
        }
        deliver(to: application, autoPaste: autoPaste)
    }

    /// Puts freshly composed text — a filled prompt, or a stack of clippings —
    /// on the pasteboard and pastes it. There's no stored item behind this, so
    /// nothing is marked as used and no payloads are restored.
    func pasteText(_ text: String, into application: NSRunningApplication?, autoPaste: Bool) {
        copyText(text)
        deliver(to: application, autoPaste: autoPaste)
    }

    func copyText(_ text: String) {
        // Built as one NSPasteboardItem so the internal marker is declared
        // alongside the text rather than bolted on after the fact.
        let entry = NSPasteboardItem()
        entry.setData(Data(text.utf8), forType: NSPasteboard.PasteboardType(UTI.plainText))
        entry.setData(Data([1]), forType: NSPasteboard.PasteboardType(UTI.internalMarker))

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([entry])
        monitor?.ignoreNextChange(changeCount: pasteboard.changeCount)
    }

    /// Hands focus back and, when allowed, presses ⌘V.
    private func deliver(to application: NSRunningApplication?, autoPaste: Bool) {
        guard autoPaste, Permissions.isAccessibilityTrusted else {
            Log.info("copy-only paste (autoPaste=\(autoPaste), trusted=\(Permissions.isAccessibilityTrusted))")
            application?.activate()
            return
        }

        application?.activate()
        Self.whenFrontmost(application) { Self.sendPasteKeystroke() }
    }

    /// Waits for `application` to actually reach the front before running
    /// `body`. A fixed delay is a bet either way: too short and the keystroke
    /// hits the wrong window, too long and the paste feels sluggish.
    private static func whenFrontmost(
        _ application: NSRunningApplication?,
        attempt: Int = 0,
        then body: @escaping () -> Void
    ) {
        let deadlineReached = attempt >= 25            // ~0.5 s ceiling
        let ready = application == nil || application?.isActive == true

        guard ready || deadlineReached else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                whenFrontmost(application, attempt: attempt + 1, then: body)
            }
            return
        }

        if deadlineReached && !ready {
            Log.error("target app never became frontmost; sending ⌘V anyway")
        }
        // One more tick so the app has processed its own activation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: body)
    }

    static func sendPasteKeystroke() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            Log.error("could not create a CGEventSource")
            return
        }
        // Don't let a physically held-down modifier corrupt the synthetic event.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let key = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else {
            Log.error("could not build the ⌘V events")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // The HID tap sits below every per-session filter, so the event reaches
        // whichever app is frontmost the same way a real key press would.
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Log.info("sent ⌘V")
    }

    /// Plain text of an item, for "Copy as Plain Text".
    func plainText(for item: ClipItem) -> String? {
        guard let payloads = try? store.payloads(itemID: item.id) else { return nil }
        for uti in [UTI.plainText, UTI.legacyText] {
            if let payload = payloads.first(where: { $0.uti == uti }),
               let data = store.data(for: payload),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    func copyPlainText(for item: ClipItem) {
        guard let text = plainText(for: item) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        monitor?.ignoreNextChange(changeCount: pasteboard.changeCount)
        try? store.markUsed(itemID: item.id)
    }
}
