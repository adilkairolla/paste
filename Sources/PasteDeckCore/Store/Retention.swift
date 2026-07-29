import Foundation

/// Bounds on how much history is kept. `0` means "no limit" for every field.
///
/// Pinned items and anything filed into a user category are *never* pruned —
/// that's the guarantee behind persistent categories.
public struct RetentionPolicy: Equatable, Codable, Sendable {
    public var maxItems: Int
    public var maxAgeDays: Int
    public var maxBytes: Int64

    public init(maxItems: Int = 2000, maxAgeDays: Int = 30, maxBytes: Int64 = 2 * 1024 * 1024 * 1024) {
        self.maxItems = maxItems
        self.maxAgeDays = maxAgeDays
        self.maxBytes = maxBytes
    }

    public static let `default` = RetentionPolicy()
    public static let unlimited = RetentionPolicy(maxItems: 0, maxAgeDays: 0, maxBytes: 0)
}

public struct PruneReport: Equatable, Sendable {
    public var deletedByAge = 0
    public var deletedByCount = 0
    public var deletedBySize = 0
    public var blobBytesReclaimed: Int64 = 0

    public var totalDeleted: Int { deletedByAge + deletedByCount + deletedBySize }
    public var didChangeAnything: Bool { totalDeleted > 0 || blobBytesReclaimed > 0 }
}

/// Applies a ``RetentionPolicy`` and reclaims orphaned blobs.
public struct Retention {
    /// Items exempt from pruning: pinned, filed into a user category, or
    /// authored rather than captured. A prompt the user wrote is not history
    /// and expiring it after thirty days would be data loss, not tidying.
    private static let protectedClause = """
    (pinned = 1 \
    OR kind = '\(ClipKind.prompt.rawValue)' \
    OR id IN (SELECT item_id FROM item_categories))
    """

    public static func prune(
        store: ClipStore,
        policy: RetentionPolicy,
        now: Date = Date(),
        collectBlobs: Bool = true
    ) throws -> PruneReport {
        var report = PruneReport()

        if policy.maxAgeDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(policy.maxAgeDays) * 86_400)
            report.deletedByAge = try store.database.write { connection in
                try connection.run(
                    "DELETE FROM items WHERE NOT \(protectedClause) AND updated_at < ?",
                    [SQLValue(cutoff)]
                )
            }
        }

        if policy.maxItems > 0 {
            report.deletedByCount = try store.database.write { connection in
                try connection.run(
                    """
                    DELETE FROM items WHERE id IN (
                        SELECT id FROM items
                         WHERE NOT \(protectedClause)
                         ORDER BY updated_at DESC
                         LIMIT -1 OFFSET ?
                    )
                    """,
                    [SQLValue(policy.maxItems)]
                )
            }
        }

        if policy.maxBytes > 0 {
            report.deletedBySize = try pruneBySize(store: store, budget: policy.maxBytes)
        }

        if collectBlobs {
            let referenced = try store.referencedBlobKeys()
            report.blobBytesReclaimed = store.blobs.collectGarbage(referencedKeys: referenced)
        }

        return report
    }

    /// Drops the oldest prunable items until the history fits the byte budget.
    /// Protected items are charged against the budget but never deleted, so a
    /// budget smaller than the protected set simply clears everything else.
    private static func pruneBySize(store: ClipStore, budget: Int64) throws -> Int {
        try store.database.write { connection in
            let protectedBytes = try connection.scalar(
                "SELECT COALESCE(SUM(byte_size), 0) FROM items WHERE \(protectedClause)"
            ).flatMap { value -> Int64? in
                if case .integer(let number) = value { return number }
                if case .real(let number) = value { return Int64(number) }
                return nil
            } ?? 0

            let remaining = budget - protectedBytes
            let rows = try connection.query(
                """
                SELECT id, byte_size FROM items
                 WHERE NOT \(protectedClause)
                 ORDER BY updated_at DESC
                """
            )

            var running: Int64 = 0
            var doomed: [Int64] = []
            for row in rows {
                let size = row.int("byte_size") ?? 0
                running += size
                if running > remaining, let id = row.int("id") {
                    doomed.append(id)
                }
            }
            guard !doomed.isEmpty else { return 0 }

            var deleted = 0
            for chunk in stride(from: 0, to: doomed.count, by: 400) {
                let slice = Array(doomed[chunk..<min(chunk + 400, doomed.count)])
                let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
                deleted += try connection.run(
                    "DELETE FROM items WHERE id IN (\(placeholders))",
                    slice.map { SQLValue($0) }
                )
            }
            return deleted
        }
    }

    /// Storage figures for the Settings screen.
    public static func usage(store: ClipStore) throws -> (items: Int, protectedItems: Int, bytes: Int64, blobBytes: Int64) {
        try store.database.read { connection in
            func number(_ sql: String) throws -> Int64 {
                try connection.scalar(sql).flatMap { value -> Int64? in
                    if case .integer(let n) = value { return n }
                    if case .real(let n) = value { return Int64(n) }
                    return nil
                } ?? 0
            }
            return (
                items: Int(try number("SELECT COUNT(*) FROM items")),
                protectedItems: Int(try number("SELECT COUNT(*) FROM items WHERE \(protectedClause)")),
                bytes: try number("SELECT COALESCE(SUM(byte_size), 0) FROM items"),
                blobBytes: store.blobs.totalBytes()
            )
        }
    }
}
