import CryptoKit
import Foundation

/// Content-addressed file storage for payloads too big to sit in SQLite.
///
/// The key is the SHA-256 of the bytes, so two copies of the same screenshot
/// share one file on disk. Files are fanned out two levels (`ab/cd/<hash>`) to
/// keep directory listings small.
public final class BlobStore: @unchecked Sendable {
    /// Payloads at or below this size stay inline in the database row.
    public static let inlineThreshold = 64 * 1024

    public let root: URL
    private let fileManager = FileManager.default

    public init(root: URL) throws {
        self.root = root
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public static func key(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func url(forKey key: String) -> URL {
        guard key.count >= 4 else { return root.appendingPathComponent(key) }
        let first = String(key.prefix(2))
        let second = String(key.dropFirst(2).prefix(2))
        return root.appendingPathComponent(first, isDirectory: true)
            .appendingPathComponent(second, isDirectory: true)
            .appendingPathComponent(key)
    }

    /// Writes the bytes if they aren't already stored and returns the key.
    @discardableResult
    public func write(_ data: Data) throws -> String {
        let key = Self.key(for: data)
        let destination = url(forKey: key)
        if fileManager.fileExists(atPath: destination.path) { return key }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        return key
    }

    public func read(key: String) -> Data? {
        try? Data(contentsOf: url(forKey: key), options: .mappedIfSafe)
    }

    public func exists(key: String) -> Bool {
        fileManager.fileExists(atPath: url(forKey: key).path)
    }

    public func remove(key: String) {
        try? fileManager.removeItem(at: url(forKey: key))
    }

    public func byteSize(key: String) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url(forKey: key).path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Every key currently on disk, plus the space it takes.
    public func allKeys() -> [(key: String, size: Int64)] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [(String, Int64)] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            results.append((url.lastPathComponent, Int64(values?.fileSize ?? 0)))
        }
        return results
    }

    public func totalBytes() -> Int64 {
        allKeys().reduce(0) { $0 + $1.size }
    }

    /// Deletes files no payload references any more. Returns bytes reclaimed.
    @discardableResult
    public func collectGarbage(referencedKeys: Set<String>) -> Int64 {
        var reclaimed: Int64 = 0
        for (key, size) in allKeys() where !referencedKeys.contains(key) {
            remove(key: key)
            reclaimed += size
        }
        pruneEmptyDirectories()
        return reclaimed
    }

    private func pruneEmptyDirectories() {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var directories: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                directories.append(url)
            }
        }
        // Deepest first, so a parent emptied by its children also goes.
        for url in directories.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            let contents = try? fileManager.contentsOfDirectory(atPath: url.path)
            if contents?.isEmpty == true { try? fileManager.removeItem(at: url) }
        }
    }
}
