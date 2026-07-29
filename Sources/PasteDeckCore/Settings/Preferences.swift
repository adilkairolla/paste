import Foundation

/// User-facing settings, backed by `UserDefaults`.
///
/// Values are read through computed properties so defaults live in exactly one
/// place and any writer posts ``Preferences/didChangeNotification``.
public final class Preferences {
    public static let didChangeNotification = Notification.Name("app.pastedeck.preferencesDidChange")

    public static let shared = Preferences(defaults: .standard)

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private enum Key {
        static let maxItems = "retention.maxItems"
        static let maxAgeDays = "retention.maxAgeDays"
        static let maxMegabytes = "retention.maxMegabytes"
        static let hotKeyCode = "hotkey.keyCode"
        static let hotKeyModifiers = "hotkey.modifiers"
        static let excludedBundleIDs = "capture.excludedBundleIDs"
        static let pollInterval = "capture.pollInterval"
        static let pasteAutomatically = "paste.automatic"
        static let restoreFilterOnOpen = "ui.restoreFilter"
        static let lastFilterID = "ui.lastFilterID"
        static let deckHeight = "ui.deckHeight"
        static let launchAtLogin = "system.launchAtLogin"
        static let hasCompletedFirstRun = "system.hasCompletedFirstRun"
        static let hasSeededPrompts = "prompts.hasSeeded"
    }

    private func set(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Preferences.didChangeNotification, object: self)
    }

    private func integer(_ key: String, default fallback: Int) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }

    private func boolean(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private func number(_ key: String, default fallback: Double) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }

    // MARK: Retention

    public var maxItems: Int {
        get { integer(Key.maxItems, default: RetentionPolicy.default.maxItems) }
        set { set(newValue, Key.maxItems) }
    }

    public var maxAgeDays: Int {
        get { integer(Key.maxAgeDays, default: RetentionPolicy.default.maxAgeDays) }
        set { set(newValue, Key.maxAgeDays) }
    }

    public var maxMegabytes: Int {
        get { integer(Key.maxMegabytes, default: 2048) }
        set { set(newValue, Key.maxMegabytes) }
    }

    public var retentionPolicy: RetentionPolicy {
        RetentionPolicy(
            maxItems: maxItems,
            maxAgeDays: maxAgeDays,
            maxBytes: Int64(maxMegabytes) * 1024 * 1024
        )
    }

    // MARK: Hot key — defaults to ⌘⇧V (kVK_ANSI_V == 9, cmd|shift)

    public var hotKeyCode: Int {
        get { integer(Key.hotKeyCode, default: 9) }
        set { set(newValue, Key.hotKeyCode) }
    }

    /// Carbon modifier mask (`cmdKey | shiftKey` == 256 | 512).
    public var hotKeyModifiers: Int {
        get { integer(Key.hotKeyModifiers, default: 256 | 512) }
        set { set(newValue, Key.hotKeyModifiers) }
    }

    // MARK: Capture

    /// Bundle identifiers whose copies are never recorded.
    public var excludedBundleIDs: [String] {
        get { defaults.stringArray(forKey: Key.excludedBundleIDs) ?? [] }
        set { set(newValue, Key.excludedBundleIDs) }
    }

    public var pollInterval: Double {
        get { max(0.1, min(2.0, number(Key.pollInterval, default: 0.35))) }
        set { set(newValue, Key.pollInterval) }
    }

    // MARK: Behaviour

    /// Send ⌘V to the previous app after choosing an item (needs Accessibility).
    public var pasteAutomatically: Bool {
        get { boolean(Key.pasteAutomatically, default: true) }
        set { set(newValue, Key.pasteAutomatically) }
    }

    public var restoreFilterOnOpen: Bool {
        get { boolean(Key.restoreFilterOnOpen, default: false) }
        set { set(newValue, Key.restoreFilterOnOpen) }
    }

    public var lastFilterID: String {
        get { defaults.string(forKey: Key.lastFilterID) ?? "all" }
        set { defaults.set(newValue, forKey: Key.lastFilterID) }
    }

    public var deckHeight: Double {
        get { max(280, min(640, number(Key.deckHeight, default: 396))) }
        set { set(newValue, Key.deckHeight) }
    }

    public var launchAtLogin: Bool {
        get { boolean(Key.launchAtLogin, default: false) }
        set { set(newValue, Key.launchAtLogin) }
    }

    public var hasCompletedFirstRun: Bool {
        get { boolean(Key.hasCompletedFirstRun, default: false) }
        set { set(newValue, Key.hasCompletedFirstRun) }
    }

    /// Starter prompts are installed exactly once. Tracked here rather than by
    /// counting rows, so deleting all of them stays deleted.
    public var hasSeededPrompts: Bool {
        get { boolean(Key.hasSeededPrompts, default: false) }
        set { set(newValue, Key.hasSeededPrompts) }
    }
}

/// Standard on-disk locations.
public enum AppPaths {
    public static let supportDirectoryName = "PasteDeck"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(supportDirectoryName, isDirectory: true)
    }

    public static var appIconCacheDirectory: URL {
        supportDirectory.appendingPathComponent("appicons", isDirectory: true)
    }
}
