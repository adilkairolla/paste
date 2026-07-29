import Foundation

/// Versioned, forward-only migrations. `user_version` tracks where we are.
enum Schema {
    static let latestVersion = 1

    static func migrate(_ connection: SQLiteConnection) throws {
        let current = Int(try connection.scalar("PRAGMA user_version").flatMap { value -> Int64? in
            if case .integer(let number) = value { return number }
            return nil
        } ?? 0)

        guard current < latestVersion else { return }

        if current < 1 {
            try connection.execute(v1)
        }

        try connection.execute("PRAGMA user_version = \(latestVersion)")
    }

    // Columns indexed by FTS are NOT NULL with defaults: an external-content FTS
    // table has to see exactly the same values the triggers wrote, and NULL vs ''
    // would desynchronise the index.
    private static let v1 = """
    CREATE TABLE items (
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        kind              TEXT    NOT NULL,
        created_at        REAL    NOT NULL,
        updated_at        REAL    NOT NULL,
        last_used_at      REAL,
        use_count         INTEGER NOT NULL DEFAULT 0,
        pinned            INTEGER NOT NULL DEFAULT 0,
        title             TEXT    NOT NULL DEFAULT '',
        preview           TEXT    NOT NULL DEFAULT '',
        search_text       TEXT    NOT NULL DEFAULT '',
        content_hash      TEXT    NOT NULL,
        byte_size         INTEGER NOT NULL DEFAULT 0,
        source_bundle_id  TEXT,
        source_app_name   TEXT    NOT NULL DEFAULT '',
        meta_json         TEXT,
        thumbnail         BLOB
    );

    CREATE UNIQUE INDEX idx_items_hash    ON items(content_hash);
    CREATE INDEX        idx_items_updated ON items(updated_at DESC);
    CREATE INDEX        idx_items_kind    ON items(kind, updated_at DESC);
    CREATE INDEX        idx_items_pinned  ON items(pinned, updated_at DESC);

    CREATE TABLE payloads (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        item_id      INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        pb_index     INTEGER NOT NULL DEFAULT 0,
        ord          INTEGER NOT NULL DEFAULT 0,
        uti          TEXT    NOT NULL,
        byte_size    INTEGER NOT NULL DEFAULT 0,
        inline_data  BLOB,
        blob_key     TEXT
    );

    CREATE INDEX idx_payloads_item ON payloads(item_id, pb_index, ord);
    CREATE INDEX idx_payloads_blob ON payloads(blob_key);

    CREATE TABLE categories (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        name       TEXT    NOT NULL UNIQUE,
        symbol     TEXT    NOT NULL DEFAULT 'folder',
        color      TEXT    NOT NULL DEFAULT 'blue',
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at REAL    NOT NULL
    );

    CREATE TABLE item_categories (
        item_id     INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
        added_at    REAL    NOT NULL,
        PRIMARY KEY (item_id, category_id)
    );

    CREATE INDEX idx_item_categories_cat  ON item_categories(category_id, added_at DESC);
    CREATE INDEX idx_item_categories_item ON item_categories(item_id);

    CREATE VIRTUAL TABLE items_fts USING fts5(
        search_text,
        title,
        source_app_name,
        content='items',
        content_rowid='id',
        tokenize="unicode61 remove_diacritics 2"
    );

    CREATE TRIGGER items_fts_insert AFTER INSERT ON items BEGIN
        INSERT INTO items_fts(rowid, search_text, title, source_app_name)
        VALUES (new.id, new.search_text, new.title, new.source_app_name);
    END;

    CREATE TRIGGER items_fts_delete AFTER DELETE ON items BEGIN
        INSERT INTO items_fts(items_fts, rowid, search_text, title, source_app_name)
        VALUES ('delete', old.id, old.search_text, old.title, old.source_app_name);
    END;

    CREATE TRIGGER items_fts_update AFTER UPDATE ON items BEGIN
        INSERT INTO items_fts(items_fts, rowid, search_text, title, source_app_name)
        VALUES ('delete', old.id, old.search_text, old.title, old.source_app_name);
        INSERT INTO items_fts(rowid, search_text, title, source_app_name)
        VALUES (new.id, new.search_text, new.title, new.source_app_name);
    END;
    """
}
