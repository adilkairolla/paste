import AppKit
import PasteDeckCore

/// Menu bar agent entry point. SwiftPM executables can't use `@main`, so the
/// application is assembled by hand here.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let store = try ClipStore(directory: AppPaths.supportDirectory)
            let controller = AppController(store: store)
            AppController.shared = controller
            self.controller = controller
            controller.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "PasteDeck couldn't open its database"
            alert.informativeText = "\(error)\n\n\(AppPaths.supportDirectory.path)"
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.store.database.checkpoint()
        HotKeyCenter.shared.unregisterAll()
    }

    /// Clicking the app in Finder while it's already running opens the deck.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        controller?.toggleDeck()
        return true
    }
}

let application = NSApplication.shared

// Offscreen render of the deck, for design iteration and the README shot.
if let flag = CommandLine.arguments.firstIndex(of: "--render-preview"),
   CommandLine.arguments.count > flag + 1 {
    application.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        PreviewRenderer.render(to: CommandLine.arguments[flag + 1])
    }
}

let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
