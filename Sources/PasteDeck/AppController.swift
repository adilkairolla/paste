import AppKit
import PasteDeckCore

/// Wires the pieces together and owns everything that lives for the whole
/// session: the store, the monitor, the hot key, the menu bar item and the deck.
@MainActor
final class AppController {
    static var shared: AppController?

    let store: ClipStore
    let preferences: Preferences
    let monitor: ClipboardMonitor
    let pasteService: PasteService
    let model: DeckModel
    let deck: DeckWindowController
    private var statusItem: StatusItemController?
    private var maintenanceTimer: Timer?
    private var lastMaintenance = Date.distantPast

    init(store: ClipStore, preferences: Preferences = .shared) {
        self.store = store
        self.preferences = preferences
        self.monitor = ClipboardMonitor(store: store, preferences: preferences)
        self.pasteService = PasteService(store: store, monitor: monitor)
        self.model = DeckModel(store: store, pasteService: pasteService, preferences: preferences)
        self.deck = DeckWindowController(model: model)
    }

    func start() {
        monitor.start()
        reloadHotKey()
        statusItem = StatusItemController(controller: self)
        // Before the first reload, so the Prompts tab has something in it the
        // very first time anyone opens the deck.
        store.seedStarterPrompts(preferences: preferences)
        model.reload(resetSelection: true)
        scheduleMaintenance()
        runMaintenance()

        if !preferences.hasCompletedFirstRun {
            preferences.hasCompletedFirstRun = true
            showWelcome()
        }
    }

    // MARK: Hot key

    func reloadHotKey() {
        HotKeyCenter.shared.unregisterAll()
        let shortcut = HotKeyCenter.Shortcut(
            keyCode: UInt32(preferences.hotKeyCode),
            modifiers: UInt32(preferences.hotKeyModifiers)
        )
        let registered = HotKeyCenter.shared.register(shortcut) { [weak self] in
            self?.deck.toggle()
        }
        if !registered {
            Log.error("could not register \(shortcut.displayString) — another app may own it")
        }
        statusItem?.updateShortcut(shortcut)
    }

    var currentShortcut: HotKeyCenter.Shortcut {
        HotKeyCenter.Shortcut(
            keyCode: UInt32(preferences.hotKeyCode),
            modifiers: UInt32(preferences.hotKeyModifiers)
        )
    }

    // MARK: Actions

    func toggleDeck() { deck.toggle() }

    func showSettings() {
        deck.hide()
        SettingsWindowController.shared.show(model: model)
    }

    func setPaused(_ paused: Bool) {
        monitor.setPaused(paused)
        statusItem?.updatePauseState(paused)
    }

    var isPaused: Bool { monitor.isPaused }

    // MARK: Maintenance

    private func scheduleMaintenance() {
        maintenanceTimer?.invalidate()
        let timer = Timer(timeInterval: 1800, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runMaintenance() }
        }
        RunLoop.main.add(timer, forMode: .common)
        maintenanceTimer = timer
    }

    /// Prunes history and reclaims disk. Cheap enough to run hourly; the guard
    /// keeps repeated triggers from thrashing.
    func runMaintenance(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastMaintenance) > 300 else { return }
        lastMaintenance = Date()

        let store = store
        let policy = preferences.retentionPolicy
        DispatchQueue.global(qos: .utility).async {
            do {
                let report = try Retention.prune(store: store, policy: policy)
                if report.didChangeAnything {
                    Log.info("pruned \(report.totalDeleted) items, reclaimed \(ByteFormat.string(report.blobBytesReclaimed))")
                    store.database.checkpoint()
                    DispatchQueue.main.async { [weak self] in
                        self?.model.reload(preserveSelection: true)
                    }
                }
            } catch {
                Log.error("maintenance failed: \(error)")
            }
        }
    }

    // MARK: First run

    private func showWelcome() {
        let alert = NSAlert()
        alert.messageText = "PasteDeck is running"
        alert.informativeText = """
        Press \(currentShortcut.displayString) any time to open your clipboard history.

        It lives in the menu bar — everything you copy is recorded locally from now on.

        To have PasteDeck press ⌘V for you after you pick something, grant Accessibility access.
        """
        alert.addButton(withTitle: "Grant Accessibility Access")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
        }
    }
}
