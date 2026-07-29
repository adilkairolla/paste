import AppKit
import PasteDeckCore

/// Answers "which app was this copied from?" and caches that app's icon.
///
/// The frontmost application at the moment the pasteboard changes is the right
/// answer in practice — copying is a foreground action.
final class AppSourceResolver {
    static let shared = AppSourceResolver()

    struct Source: Equatable {
        var bundleID: String?
        var name: String
    }

    private var iconCache: [String: NSImage] = [:]
    private let cacheDirectory = AppPaths.appIconCacheDirectory
    private let ownBundleID = Bundle.main.bundleIdentifier

    private init() {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func currentSource() -> Source {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return Source(bundleID: nil, name: "Unknown")
        }
        // Copies made from our own panel keep the app they came from.
        if let ownBundleID, app.bundleIdentifier == ownBundleID {
            return Source(bundleID: nil, name: "PasteDeck")
        }
        let name = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        cacheIconIfNeeded(for: app)
        return Source(bundleID: app.bundleIdentifier, name: name)
    }

    /// Icon for a bundle id: memory cache → running app → Launch Services → the
    /// PNG we cached on disk when we first saw it (apps get uninstalled).
    func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = iconCache[bundleID] { return cached }

        var image: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else if let data = try? Data(contentsOf: iconURL(for: bundleID)) {
            image = NSImage(data: data)
        }

        if let image {
            image.size = NSSize(width: 32, height: 32)
            iconCache[bundleID] = image
        }
        return image
    }

    private func iconURL(for bundleID: String) -> URL {
        cacheDirectory.appendingPathComponent("\(bundleID).png")
    }

    private func cacheIconIfNeeded(for app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        let destination = iconURL(for: bundleID)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        guard let icon = app.icon else { return }

        let size = NSSize(width: 64, height: 64)
        guard let representation = icon.bestRepresentation(for: NSRect(origin: .zero, size: size), context: nil, hints: nil)
        else { return }

        let image = NSImage(size: size)
        image.addRepresentation(representation)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: destination, options: .atomic)
    }
}
