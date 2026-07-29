import AppKit
import Combine
import PasteDeckCore
import SwiftUI

/// A page floating above the deck, Quick Look style.
///
/// It gets its own window rather than being an overlay inside ``DeckPanel``:
/// the deck is a 245 pt strip along the bottom of the screen, so anything drawn
/// inside it is a letterbox no matter how it's laid out. Reading wants height.
///
/// The panel refuses the keyboard while the page is read-only. The deck keeps
/// it, so space, escape and the arrows go on working exactly as they do with
/// the preview closed, and the deck's own resign-key dismissal isn't tripped by
/// clicking the page. Editing is the one exception: a text view can't receive
/// keystrokes in a window that can't become key, so `acceptsKeyboard` is
/// flipped on for the duration and handed straight back afterwards.
final class PreviewPanel: NSPanel {
    var acceptsKeyboard = false

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Above the deck, so the page overlaps it rather than sliding behind.
        level = .floating
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

@MainActor
final class PreviewWindowController {
    private let model: DeckModel
    private var panel: PreviewPanel?
    private var observers: [AnyCancellable] = []

    /// Called when editing finishes, so the deck can take the keyboard back.
    var onKeyboardReleased: (() -> Void)?

    init(model: DeckModel) {
        self.model = model

        // Driven entirely by the model flags, so every route into the preview —
        // space, a click, the strip emptying — lands in one place.
        model.$isPreviewingLarge
            .removeDuplicates()
            .sink { [weak self] showing in
                MainActor.assumeIsolated { showing ? self?.show() : self?.hide() }
            }
            .store(in: &observers)

        model.$previewDraft
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] editing in
                MainActor.assumeIsolated { self?.setEditing(editing) }
            }
            .store(in: &observers)
    }

    /// Editing needs real keystrokes, which means real key-window status.
    ///
    /// The hand-over is deferred by one turn of the run loop on purpose. A
    /// `@Published` publisher fires in `willSet`, so at this point the model
    /// still reports the *old* value — and the deck's resign-key handler, which
    /// asks exactly that question to decide whether the user is leaving, would
    /// see "not editing" and dismiss the whole deck the moment the page took
    /// focus.
    private func setEditing(_ editing: Bool) {
        guard let panel else { return }
        panel.acceptsKeyboard = editing
        DispatchQueue.main.async { [weak self] in
            guard let self, panel.isVisible else { return }
            editing ? panel.makeKey() : self.onKeyboardReleased?()
        }
    }

    /// Picks the same screen the deck picks, and centres the page in the band
    /// between the top of the deck and the top of the screen.
    func show() {
        guard model.selectedItem != nil else { return }

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = Theme.previewSize(inScreen: visible)

        // Mirrors DeckWindowController.targetFrame — the deck always sits one
        // screen inset up from the bottom.
        let deckTop = visible.minY + Theme.screenInset + Theme.deckHeight
        let band = visible.maxY - Theme.screenInset - (deckTop + Theme.sectionGap)
        let frame = NSRect(
            x: (visible.midX - size.width / 2).rounded(),
            y: (deckTop + Theme.sectionGap + max(0, band - size.height) / 2).rounded(),
            width: size.width,
            height: size.height
        )

        let panel = existingPanel(frame: frame)
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    /// Closing the deck takes the page with it — a page with no deck behind it
    /// would have no keyboard to close it. An edit still in flight is saved
    /// rather than dropped: the text was typed on purpose, and losing it is
    /// worse than a save nobody explicitly confirmed.
    func teardown() {
        model.commitPreviewEdit()
        model.isPreviewingLarge = false
        hide()
    }

    private func existingPanel(frame: NSRect) -> PreviewPanel {
        if let panel { return panel }

        let panel = PreviewPanel(contentRect: frame)
        let hosting = NSHostingView(rootView: LargePreviewHost(model: model))
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
        return panel
    }
}

/// Follows the selection, so the arrows page through clippings without having
/// to close and reopen the preview.
private struct LargePreviewHost: View {
    @ObservedObject var model: DeckModel

    var body: some View {
        if let item = model.selectedItem {
            LargePreviewView(model: model, item: item)
        } else {
            Color.clear
        }
    }
}
