import AppKit
import PasteDeckCore

/// Watches `NSPasteboard.general` and hands new content to the store.
///
/// There is no notification for pasteboard changes on macOS, so this polls
/// `changeCount` — an integer read, cheap enough to do a few times a second.
final class ClipboardMonitor {
    /// Posted on the main queue after a clipping is recorded.
    static let didCaptureNotification = Notification.Name("app.pastedeck.didCapture")

    private let store: ClipStore
    private let preferences: Preferences
    private let classifier = ClipClassifier()
    private let processingQueue = DispatchQueue(label: "app.pastedeck.capture", qos: .utility)

    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int
    /// Change counts produced by our own writes, which must not be re-recorded.
    private var selfInflictedChangeCounts: Set<Int> = []

    private(set) var isPaused = false

    init(store: ClipStore, preferences: Preferences = .shared) {
        self.store = store
        self.preferences = preferences
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    // MARK: Lifecycle

    func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + preferences.pollInterval, repeating: preferences.pollInterval, leeway: .milliseconds(80))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        // Skip whatever landed while paused rather than capturing it on resume.
        if !paused { lastChangeCount = NSPasteboard.general.changeCount }
    }

    /// Called by ``PasteService`` right after it writes, so the round trip
    /// doesn't come back in as a new clipping.
    func ignoreNextChange(changeCount: Int) {
        selfInflictedChangeCounts.insert(changeCount)
        if selfInflictedChangeCounts.count > 8 {
            selfInflictedChangeCounts.removeFirst()
        }
    }

    // MARK: Polling

    private func tick() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        guard !isPaused else { return }
        if selfInflictedChangeCounts.remove(changeCount) != nil { return }

        let source = AppSourceResolver.shared.currentSource()
        if let bundleID = source.bundleID, preferences.excludedBundleIDs.contains(bundleID) { return }

        guard let snapshot = readSnapshot(pasteboard, source: source) else { return }
        guard !snapshot.shouldBeIgnored else { return }

        processingQueue.async { [weak self] in
            guard let self, let clip = self.classifier.classify(snapshot) else { return }
            do {
                let outcome = try self.store.insert(clip)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: ClipboardMonitor.didCaptureNotification,
                        object: outcome
                    )
                }
            } catch {
                Log.error("capture failed: \(error)")
            }
        }
    }

    /// Copies every representation off the pasteboard. Reading happens on the
    /// main thread because the pasteboard can be rewritten underneath us;
    /// classification and hashing happen off it.
    private func readSnapshot(_ pasteboard: NSPasteboard, source: AppSourceResolver.Source) -> PasteboardSnapshot? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }

        var snapshotItems: [PasteboardSnapshot.Item] = []
        snapshotItems.reserveCapacity(items.count)

        for item in items {
            var representations: [PasteboardSnapshot.Representation] = []
            for type in item.types {
                let identifier = type.rawValue
                if UTI.skipped.contains(identifier) { continue }
                // Keep concealed markers: the classifier uses them to bail out.
                guard let data = item.data(forType: type), !data.isEmpty else { continue }
                representations.append(.init(uti: identifier, data: data))
            }
            if !representations.isEmpty {
                snapshotItems.append(.init(representations: representations))
            }
        }

        guard !snapshotItems.isEmpty else { return nil }
        return PasteboardSnapshot(
            items: snapshotItems,
            sourceBundleID: source.bundleID,
            sourceAppName: source.name,
            capturedAt: Date()
        )
    }
}
