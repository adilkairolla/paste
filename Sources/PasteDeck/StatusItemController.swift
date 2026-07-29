import AppKit
import PasteDeckCore

/// The menu bar presence: click to open the deck, right-click for the menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private unowned let controller: AppController
    private let menu = NSMenu()
    private var openItem: NSMenuItem?
    private var pauseItem: NSMenuItem?

    init(controller: AppController) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "PasteDeck")
                ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "PasteDeck")
            button.image?.isTemplate = true
            button.toolTip = "PasteDeck — clipboard history"
        }

        buildMenu()
        statusItem.menu = menu
        menu.delegate = self
    }

    private func buildMenu() {
        let open = NSMenuItem(title: "Open Deck", action: #selector(openDeck), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        openItem = open

        menu.addItem(.separator())

        let pause = NSMenuItem(title: "Pause Recording", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        pauseItem = pause

        let clear = NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit PasteDeck", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        updateShortcut(controller.currentShortcut)
    }

    func updateShortcut(_ shortcut: HotKeyCenter.Shortcut) {
        openItem?.title = "Open Deck  (\(shortcut.displayString))"
    }

    func updatePauseState(_ paused: Bool) {
        pauseItem?.title = paused ? "Resume Recording" : "Pause Recording"
        statusItem.button?.appearsDisabled = paused
    }

    func menuWillOpen(_ menu: NSMenu) {
        updatePauseState(controller.isPaused)
        let count = (try? controller.store.count()) ?? 0
        openItem?.toolTip = "\(count) clippings recorded"
    }

    // MARK: Actions

    @objc private func openDeck() {
        controller.toggleDeck()
    }

    @objc private func togglePause() {
        controller.setPaused(!controller.isPaused)
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "Pinned clippings and anything filed into a category will be kept."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        _ = try? controller.store.deleteAll()
        controller.runMaintenance(force: true)
        controller.model.reload(resetSelection: true)
    }

    @objc private func openSettings() {
        controller.showSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
