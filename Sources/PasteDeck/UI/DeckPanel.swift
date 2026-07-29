import AppKit
import PasteDeckCore
import SwiftUI

/// Borderless floating panel that can take keyboard focus without the app
/// owning the menu bar.
final class DeckPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    /// Escape and ⌘W should close the deck, not beep.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// Shows, positions and dismisses the deck, and owns its key handling.
@MainActor
final class DeckWindowController: NSObject, NSWindowDelegate {
    private let model: DeckModel
    private var panel: DeckPanel?
    private var keyMonitor: Any?
    private var resignObserver: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    init(model: DeckModel) {
        self.model = model
        super.init()
        model.onDismiss = { [weak self] immediately in self?.hide(immediately: immediately) }
    }

    // MARK: - Presentation

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let previousApp = NSWorkspace.shared.frontmostApplication
        let isSelf = previousApp?.bundleIdentifier == Bundle.main.bundleIdentifier
        model.prepareForDisplay(target: isSelf ? model.targetApplication : previousApp)

        let panel = existingPanel()
        panel.setFrame(targetFrame(height: Theme.deckHeight), display: false)
        panel.alphaValue = 0

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        animateIn(panel)
        installKeyMonitor()
    }

    /// `immediately` orders the panel out on this turn of the run loop rather
    /// than fading it. A paste needs that: while the panel is still on screen
    /// it owns the key window, and the app we're pasting into can't take focus.
    func hide(immediately: Bool = false) {
        guard let panel, panel.isVisible else { return }
        removeKeyMonitor()

        if immediately {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.11
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
            panel?.alphaValue = 1
        }
    }

    private func existingPanel() -> DeckPanel {
        if let panel { return panel }

        let frame = targetFrame(height: Theme.deckHeight)
        let panel = DeckPanel(contentRect: frame)
        panel.delegate = self

        let hosting = NSHostingView(rootView: DeckView(model: model))
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
        return panel
    }

    /// A strip along the bottom of whichever screen has the pointer, inset from
    /// the edges so it reads as a floating overlay rather than a second Dock.
    private func targetFrame(height: CGFloat) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let inset = Theme.screenInset
        return NSRect(
            x: visible.minX + inset,
            y: visible.minY + inset,
            width: visible.width - inset * 2,
            height: height
        )
    }

    private func animateIn(_ panel: DeckPanel) {
        let destination = panel.frame
        var start = destination
        start.origin.y -= 18
        panel.setFrame(start, display: false)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(destination, display: true)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking away dismisses, like Spotlight.
        hide()
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)

        // Let the inline "new category" field have the keyboard to itself.
        if model.isCreatingCategory, !command {
            if event.keyCode == 53 { // esc
                model.isCreatingCategory = false
                return true
            }
            return false
        }

        // Same for the prompt sheet: while it's up the deck's own keys would
        // fight the text fields for ⏎, ⇥ and space.
        if model.promptFill != nil, !command {
            switch event.keyCode {
            case 53: // escape
                model.cancelPromptFill()
                return true
            case 36, 76: // return — ⇧⏎ inserts a newline instead of pasting
                if shift { return false }
                model.commitPromptFill()
                return true
            case 48: // tab
                model.stepPromptField(by: shift ? -1 : 1)
                return true
            default:
                return false
            }
        }

        // Space opens the large preview, but only when the user isn't typing a
        // search — otherwise they could never search for two words.
        if event.keyCode == 49, model.searchText.isEmpty, !command {
            withAnimation(.easeOut(duration: 0.12)) {
                model.isPreviewingLarge.toggle()
            }
            return true
        }

        switch event.keyCode {
        case 53: // escape
            // Unwind one layer at a time, innermost first, so escape never
            // closes the deck while there's still something to back out of.
            if model.isPreviewingLarge {
                model.isPreviewingLarge = false
            } else if !model.stack.isEmpty {
                model.clearStack()
            } else if !model.searchText.isEmpty {
                model.searchText = ""
            } else {
                hide()
            }
            return true

        case 36, 76: // return, keypad enter
            // ⇧⏎ gathers instead of pasting: the stack is built by pressing it
            // once per clipping, then ⏎ once to send them all.
            if shift {
                model.toggleStackSelected()
            } else {
                model.pasteSelected()
            }
            return true

        case 123: // left — step backwards inside the focused zone
            if command, model.focusZone == .items {
                model.selectFirst()
            } else if model.focusZone == .search {
                return false // let the caret move
            } else {
                model.step(by: -1)
            }
            return true

        case 124: // right
            if command, model.focusZone == .items {
                model.selectLast()
            } else if model.focusZone == .search {
                return false
            } else {
                model.step(by: 1)
            }
            return true

        case 125: // down — search → categories → items
            model.moveFocus(by: 1)
            return true

        case 126: // up
            model.moveFocus(by: -1)
            return true

        case 48: // tab — same as →, ⇧⇥ same as ←
            if model.focusZone == .search { model.focusZone = .items }
            model.step(by: shift ? -1 : 1)
            return true

        case 51 where command: // ⌘⌫
            model.deleteSelected()
            return true

        default:
            break
        }

        guard command else { return false }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            model.copySelected()
            return true
        case "p":
            model.togglePinSelected()
            return true
        case "n":
            if shift {
                hide()
                PromptEditorWindowController.shared.show(model: model, editing: nil)
            } else {
                model.isCreatingCategory = true
            }
            return true

        case "e":
            // Edit a prompt, or promote anything else into one — both are the
            // same intent: "I want to reuse this, with slots".
            guard let item = model.selectedItem else { return true }
            if item.kind == .prompt {
                hide()
                PromptEditorWindowController.shared.show(model: model, editing: item)
            } else {
                model.savePromptFromItem(item)
            }
            return true
        case "f":
            return true // search already has focus
        case "w":
            hide()
            return true
        case ",":
            hide()
            SettingsWindowController.shared.show(model: model)
            return true
        case let digit? where digit.count == 1 && ("1"..."9").contains(digit):
            if let number = Int(digit) {
                model.pasteItem(at: number - 1)
                return true
            }
            return false
        default:
            return false
        }
    }
}
