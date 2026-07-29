import Foundation

/// What happened when a clipping was offered to the store.
public enum InsertOutcome: Equatable, Sendable {
    /// Brand new content.
    case inserted(ClipItem)
    /// Identical content already existed and was moved back to the top.
    case promoted(ClipItem)
}

public struct ClipQuery: Equatable, Sendable {
    public var filter: ClipFilter
    public var search: String
    public var limit: Int
    public var offset: Int

    public init(filter: ClipFilter = .all, search: String = "", limit: Int = 150, offset: Int = 0) {
        self.filter = filter
        self.search = search
        self.limit = limit
        self.offset = offset
    }
}

/// All reads and writes of clipping history go through here.
/// Safe to hand between queues: every database call is serialised inside
/// ``Database`` and the blob store is content-addressed.
public final class ClipStore: @unchecked Sendable {
    public let database: Database
    public let blobs: BlobStore

    public init(database: Database, blobs: BlobStore) throws {
        self.database = database
        self.blobs = blobs
        try database.write { try Schema.migrate($0) }
    }

    /// Opens (or creates) the store in a support directory.
    public convenience init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try Database(path: directory.appendingPathComponent("history.sqlite").path)
        let blobs = try BlobStore(root: directory.appendingPathComponent("blobs", isDirectory: true))
        try self.init(database: database, blobs: blobs)
    }

    // MARK: - Writing

    @discardableResult
    public func insert(_ clip: NewClip) throws -> InsertOutcome {
        // Blob files are written before the transaction: they're content
        // addressed, so a crash in between only leaves collectable garbage.
        var stored: [(pbIndex: Int, order: Int, uti: String, size: Int, inline: Data?, key: String?)] = []
        for (order, payload) in clip.payloads.enumerated() {
            if payload.data.count <= BlobStore.inlineThreshold {
                stored.append((payload.pasteboardIndex, order, payload.uti, payload.data.count, payload.data, nil))
            } else {
                let key = try blobs.write(payload.data)
                stored.append((payload.pasteboardIndex, order, payload.uti, payload.data.count, nil, key))
            }
        }

        return try database.transaction { connection in
            if let existing = try Self.loadItem(connection, hash: clip.contentHash) {
                try connection.run(
                    """
                    UPDATE items
                       SET updated_at = ?, source_bundle_id = ?, source_app_name = ?
                     WHERE id = ?
                    """,
                    [
                        SQLValue(clip.capturedAt),
                        SQLValue(clip.sourceBundleID),
                        SQLValue(clip.sourceAppName),
                        SQLValue(existing.id),
                    ]
                )
                var promoted = existing
                promoted.updatedAt = clip.capturedAt
                promoted.sourceBundleID = clip.sourceBundleID
                promoted.sourceAppName = clip.sourceAppName
                return .promoted(promoted)
            }

            try connection.run(
                """
                INSERT INTO items
                    (kind, created_at, updated_at, use_count, pinned, title, preview,
                     search_text, content_hash, byte_size, source_bundle_id, source_app_name,
                     meta_json, thumbnail)
                VALUES (?, ?, ?, 0, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    SQLValue(clip.kind.rawValue),
                    SQLValue(clip.capturedAt),
                    SQLValue(clip.capturedAt),
                    SQLValue(clip.title),
                    SQLValue(clip.preview),
                    SQLValue(clip.searchText),
                    SQLValue(clip.contentHash),
                    SQLValue(clip.storedBytes),
                    SQLValue(clip.sourceBundleID),
                    SQLValue(clip.sourceAppName),
                    SQLValue(clip.metadata.encodedJSON()),
                    SQLValue(clip.thumbnail),
                ]
            )
            let id = connection.lastInsertRowID

            for entry in stored {
                try connection.run(
                    """
                    INSERT INTO payloads (item_id, pb_index, ord, uti, byte_size, inline_data, blob_key)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        SQLValue(id),
                        SQLValue(entry.pbIndex),
                        SQLValue(entry.order),
                        SQLValue(entry.uti),
                        SQLValue(entry.size),
                        SQLValue(entry.inline),
                        SQLValue(entry.key),
                    ]
                )
            }

            guard let item = try Self.loadItem(connection, id: id) else {
                throw SQLiteError(code: -1, message: "item vanished after insert", sql: nil)
            }
            return .inserted(item)
        }
    }

    public func setPinned(_ pinned: Bool, itemID: Int64) throws {
        try database.write {
            try $0.run("UPDATE items SET pinned = ? WHERE id = ?", [SQLValue(pinned), SQLValue(itemID)])
        }
    }

    /// Records a paste. `updated_at` moves too: pasting something is a stronger
    /// signal of relevance than copying it was, so it returns to the front of
    /// the deck — and stops being a pruning candidate.
    public func markUsed(itemID: Int64, at date: Date = Date()) throws {
        try database.write {
            try $0.run(
                """
                UPDATE items
                   SET use_count = use_count + 1, last_used_at = ?, updated_at = ?
                 WHERE id = ?
                """,
                [SQLValue(date), SQLValue(date), SQLValue(itemID)]
            )
        }
    }

    public func delete(itemIDs: [Int64]) throws {
        guard !itemIDs.isEmpty else { return }
        try database.transaction { connection in
            let placeholders = Array(repeating: "?", count: itemIDs.count).joined(separator: ",")
            try connection.run(
                "DELETE FROM items WHERE id IN (\(placeholders))",
                itemIDs.map { SQLValue($0) }
            )
        }
    }

    /// Clears history. Pinned and filed items survive unless `everything` is set.
    @discardableResult
    public func deleteAll(everything: Bool = false) throws -> Int {
        try database.transaction { connection in
            if everything {
                return try connection.run("DELETE FROM items")
            }
            return try connection.run(
                """
                DELETE FROM items
                 WHERE pinned = 0
                   AND id NOT IN (SELECT item_id FROM item_categories)
                """
            )
        }
    }

    // MARK: - Reading

    public func items(_ query: ClipQuery = ClipQuery()) throws -> [ClipItem] {
        try database.read { connection in
            var joins = ""
            var conditions: [String] = []
            var parameters: [SQLValue] = []

            switch query.filter {
            case .all:
                conditions.append(Self.notLibrary)
            case .pinned:
                conditions.append("i.pinned = 1")
                conditions.append(Self.notLibrary)
            case .prompts:
                conditions.append("i.kind = '\(ClipKind.prompt.rawValue)'")
            case .kinds(let kinds) where !kinds.isEmpty:
                let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ",")
                conditions.append("i.kind IN (\(placeholders))")
                parameters.append(contentsOf: kinds.map { SQLValue($0.rawValue) })
            case .kinds:
                break
            case .category(let categoryID):
                joins += " JOIN item_categories ic ON ic.item_id = i.id AND ic.category_id = ?"
                parameters.append(SQLValue(categoryID))
            }

            if let match = Self.ftsQuery(from: query.search) {
                joins += " JOIN items_fts fts ON fts.rowid = i.id"
                conditions.append("items_fts MATCH ?")
                parameters.append(SQLValue(match))
            }

            let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
            // Thumbnails are deliberately left out: a page of 150 rows would
            // copy megabytes of PNG on every keystroke. The UI fetches them
            // lazily per visible card.
            let sql = """
            SELECT \(Self.listColumns) FROM items i\(joins)\(whereClause)
            ORDER BY i.updated_at DESC
            LIMIT ? OFFSET ?
            """
            parameters.append(SQLValue(query.limit))
            parameters.append(SQLValue(query.offset))

            var items = try connection.query(sql, parameters).map(Self.decodeItem)
            try Self.attachCategories(connection, to: &items)
            return items
        }
    }

    public func item(id: Int64) throws -> ClipItem? {
        try database.read { connection in
            guard var item = try Self.loadItem(connection, id: id) else { return nil }
            var wrapper = [item]
            try Self.attachCategories(connection, to: &wrapper)
            item = wrapper[0]
            return item
        }
    }

    public func count(_ filter: ClipFilter = .all) throws -> Int {
        try database.read { connection in
            switch filter {
            case .all:
                return Int(try connection.scalar(
                    "SELECT COUNT(*) FROM items i WHERE \(Self.notLibrary)"
                ).flatMap(Self.asInt) ?? 0)
            case .pinned:
                return Int(try connection.scalar(
                    "SELECT COUNT(*) FROM items i WHERE i.pinned = 1 AND \(Self.notLibrary)"
                ).flatMap(Self.asInt) ?? 0)
            case .prompts:
                return Int(try connection.scalar(
                    "SELECT COUNT(*) FROM items WHERE kind = '\(ClipKind.prompt.rawValue)'"
                ).flatMap(Self.asInt) ?? 0)
            case .kinds(let kinds):
                guard !kinds.isEmpty else { return 0 }
                let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ",")
                let value = try connection.scalar(
                    "SELECT COUNT(*) FROM items WHERE kind IN (\(placeholders))",
                    kinds.map { SQLValue($0.rawValue) }
                )
                return Int(value.flatMap(Self.asInt) ?? 0)
            case .category(let categoryID):
                let value = try connection.scalar(
                    "SELECT COUNT(*) FROM item_categories WHERE category_id = ?",
                    [SQLValue(categoryID)]
                )
                return Int(value.flatMap(Self.asInt) ?? 0)
            }
        }
    }

    /// Payloads for an item, in pasteboard order, with blobs resolved.
    public func payloads(itemID: Int64) throws -> [ClipPayload] {
        let rows = try database.read {
            try $0.query(
                "SELECT * FROM payloads WHERE item_id = ? ORDER BY pb_index ASC, ord ASC",
                [SQLValue(itemID)]
            )
        }
        return rows.map { row in
            let storage: ClipPayload.Storage
            if let key = row.string("blob_key"), !key.isEmpty {
                storage = .blob(key: key)
            } else {
                storage = .inline(row.data("inline_data") ?? Data())
            }
            return ClipPayload(
                pasteboardIndex: Int(row.int("pb_index") ?? 0),
                order: Int(row.int("ord") ?? 0),
                uti: row.string("uti") ?? "public.data",
                byteSize: Int(row.int("byte_size") ?? 0),
                storage: storage
            )
        }
    }

    /// Cached preview image for a card, loaded on demand.
    public func thumbnail(itemID: Int64) throws -> Data? {
        try database.read {
            try $0.query("SELECT thumbnail FROM items WHERE id = ?", [SQLValue(itemID)]).first?.data("thumbnail")
        }
    }

    public func data(for payload: ClipPayload) -> Data? {
        switch payload.storage {
        case .inline(let data): return data
        case .blob(let key): return blobs.read(key: key)
        }
    }

    /// Convenience for previews: the bytes of the first payload matching a UTI.
    public func data(itemID: Int64, uti: String) throws -> Data? {
        guard let payload = try payloads(itemID: itemID).first(where: { $0.uti == uti }) else { return nil }
        return data(for: payload)
    }

    public func totalBytes() throws -> Int64 {
        try database.read {
            try $0.scalar("SELECT COALESCE(SUM(byte_size), 0) FROM items").flatMap(Self.asInt) ?? 0
        }
    }

    public func referencedBlobKeys() throws -> Set<String> {
        let rows = try database.read {
            try $0.query("SELECT DISTINCT blob_key FROM payloads WHERE blob_key IS NOT NULL")
        }
        return Set(rows.compactMap { $0.string("blob_key") })
    }

    // MARK: - Categories

    public func categories() throws -> [ClipCategory] {
        let rows = try database.read {
            try $0.query(
                """
                SELECT c.*, (SELECT COUNT(*) FROM item_categories ic WHERE ic.category_id = c.id) AS item_count
                  FROM categories c
                 ORDER BY c.sort_order ASC, c.created_at ASC
                """
            )
        }
        return rows.map { row in
            ClipCategory(
                id: row.int("id") ?? 0,
                name: row.string("name") ?? "",
                symbolName: row.string("symbol") ?? "folder",
                colorName: row.string("color") ?? "blue",
                sortOrder: Int(row.int("sort_order") ?? 0),
                createdAt: row.date("created_at") ?? Date(),
                itemCount: Int(row.int("item_count") ?? 0)
            )
        }
    }

    @discardableResult
    public func createCategory(name: String, symbolName: String = "folder", colorName: String = "blue") throws -> ClipCategory {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        return try database.transaction { connection in
            let nextOrder = try connection.scalar("SELECT COALESCE(MAX(sort_order), -1) + 1 FROM categories")
                .flatMap(Self.asInt) ?? 0
            try connection.run(
                "INSERT INTO categories (name, symbol, color, sort_order, created_at) VALUES (?, ?, ?, ?, ?)",
                [
                    SQLValue(trimmed),
                    SQLValue(symbolName),
                    SQLValue(colorName),
                    SQLValue(nextOrder),
                    SQLValue(now),
                ]
            )
            return ClipCategory(
                id: connection.lastInsertRowID,
                name: trimmed,
                symbolName: symbolName,
                colorName: colorName,
                sortOrder: Int(nextOrder),
                createdAt: now
            )
        }
    }

    public func updateCategory(id: Int64, name: String? = nil, symbolName: String? = nil, colorName: String? = nil) throws {
        var assignments: [String] = []
        var parameters: [SQLValue] = []
        if let name {
            assignments.append("name = ?")
            parameters.append(SQLValue(name.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if let symbolName {
            assignments.append("symbol = ?")
            parameters.append(SQLValue(symbolName))
        }
        if let colorName {
            assignments.append("color = ?")
            parameters.append(SQLValue(colorName))
        }
        guard !assignments.isEmpty else { return }
        parameters.append(SQLValue(id))
        try database.write {
            try $0.run("UPDATE categories SET \(assignments.joined(separator: ", ")) WHERE id = ?", parameters)
        }
    }

    public func deleteCategory(id: Int64) throws {
        try database.write { try $0.run("DELETE FROM categories WHERE id = ?", [SQLValue(id)]) }
    }

    public func reorderCategories(ids: [Int64]) throws {
        try database.transaction { connection in
            for (index, id) in ids.enumerated() {
                try connection.run(
                    "UPDATE categories SET sort_order = ? WHERE id = ?",
                    [SQLValue(index), SQLValue(id)]
                )
            }
        }
    }

    public func addItem(_ itemID: Int64, toCategory categoryID: Int64) throws {
        try database.write {
            try $0.run(
                "INSERT OR IGNORE INTO item_categories (item_id, category_id, added_at) VALUES (?, ?, ?)",
                [SQLValue(itemID), SQLValue(categoryID), SQLValue(Date())]
            )
        }
    }

    public func removeItem(_ itemID: Int64, fromCategory categoryID: Int64) throws {
        try database.write {
            try $0.run(
                "DELETE FROM item_categories WHERE item_id = ? AND category_id = ?",
                [SQLValue(itemID), SQLValue(categoryID)]
            )
        }
    }

    // MARK: - Row decoding

    /// Keeps authored items (prompts) out of the history views. They are their
    /// own tab; mixing a template library into "everything you copied" buries
    /// the history under things the user never copied at all.
    static let notLibrary = "i.kind <> '\(ClipKind.prompt.rawValue)'"

    /// Every column except `thumbnail`, which is fetched separately.
    private static let listColumns = """
    i.id, i.kind, i.created_at, i.updated_at, i.last_used_at, i.use_count, i.pinned, \
    i.title, i.preview, i.content_hash, i.byte_size, i.source_bundle_id, i.source_app_name, i.meta_json
    """

    private static func asInt(_ value: SQLValue) -> Int64? {
        if case .integer(let number) = value { return number }
        if case .real(let number) = value { return Int64(number) }
        return nil
    }

    static func decodeItem(_ row: Row) -> ClipItem {
        ClipItem(
            id: row.int("id") ?? 0,
            kind: ClipKind(rawValue: row.string("kind") ?? "") ?? .other,
            createdAt: row.date("created_at") ?? Date(),
            updatedAt: row.date("updated_at") ?? Date(),
            lastUsedAt: row.date("last_used_at"),
            useCount: Int(row.int("use_count") ?? 0),
            isPinned: row.bool("pinned"),
            title: row.string("title") ?? "",
            preview: row.string("preview") ?? "",
            contentHash: row.string("content_hash") ?? "",
            byteSize: row.int("byte_size") ?? 0,
            sourceBundleID: row.string("source_bundle_id"),
            sourceAppName: row.string("source_app_name") ?? "",
            metadata: ClipMetadata.decode(json: row.string("meta_json")),
            thumbnail: row.data("thumbnail")
        )
    }

    private static func loadItem(_ connection: SQLiteConnection, id: Int64) throws -> ClipItem? {
        try connection.query("SELECT * FROM items WHERE id = ?", [SQLValue(id)]).first.map(decodeItem)
    }

    private static func loadItem(_ connection: SQLiteConnection, hash: String) throws -> ClipItem? {
        try connection.query("SELECT * FROM items WHERE content_hash = ?", [SQLValue(hash)]).first.map(decodeItem)
    }

    private static func attachCategories(_ connection: SQLiteConnection, to items: inout [ClipItem]) throws {
        guard !items.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: items.count).joined(separator: ",")
        let rows = try connection.query(
            "SELECT item_id, category_id FROM item_categories WHERE item_id IN (\(placeholders))",
            items.map { SQLValue($0.id) }
        )
        guard !rows.isEmpty else { return }

        var byItem: [Int64: [Int64]] = [:]
        for row in rows {
            guard let itemID = row.int("item_id"), let categoryID = row.int("category_id") else { continue }
            byItem[itemID, default: []].append(categoryID)
        }
        for index in items.indices {
            items[index].categoryIDs = byItem[items[index].id] ?? []
        }
    }

    // MARK: - Search

    /// Turns free text into an FTS5 MATCH expression: every word becomes a
    /// quoted prefix term, all ANDed together. Returns nil for empty input.
    static func ftsQuery(from search: String) -> String? {
        let separators = CharacterSet.alphanumerics.inverted
        let tokens = search
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
            .joined(separator: " AND ")
    }
}
