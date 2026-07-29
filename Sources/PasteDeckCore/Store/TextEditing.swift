import Foundation

public extension ClipKind {
    /// Whether a clipping of this kind can be rewritten in place.
    ///
    /// The test is whether plain text *is* the content. Rich text is excluded
    /// on purpose: its payload is RTF or HTML, and saving edited plain text
    /// over it would silently throw away the formatting that makes pasting
    /// back into the originating app worth anything. Colours and files are
    /// structured values rather than prose, and images have no text at all.
    var isEditable: Bool {
        switch self {
        case .text, .code, .link, .prompt: return true
        case .richText, .color, .image, .file, .other: return false
        }
    }
}

public enum ClipEditError: Error, Equatable {
    case notEditable(ClipKind)
    case empty
    /// The new text is byte-identical to another clipping of the same kind.
    case duplicate
    case missing
}

public extension ClipStore {
    /// Rewrites a clipping's text, refreshing everything derived from it.
    ///
    /// The kind is deliberately *not* re-classified. Editing a note until it
    /// happens to look like code shouldn't move it to another tab underneath
    /// the cursor; what you edited is what you keep. `updated_at` is preserved
    /// for the same reason — the deck sorts by when things were copied, and
    /// reordering the strip while someone is reading it is disorienting.
    func updateText(itemID: Int64, text: String) throws {
        guard let item = try item(id: itemID) else { throw ClipEditError.missing }
        guard item.kind.isEditable else { throw ClipEditError.notEditable(item.kind) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClipEditError.empty }

        if item.kind == .prompt {
            try updatePrompt(itemID: itemID, title: item.title, body: text, now: item.updatedAt)
            return
        }

        let derived = TextFacts(text: text, kind: item.kind, existingMetadata: item.metadata)
        let hash = ClipClassifier.hash(kind: item.kind, canonical: Data(text.utf8))

        // The content hash is uniquely indexed, so editing one clipping into an
        // exact copy of another would fail deep inside the transaction. Say so
        // in terms the caller can act on instead.
        if let clash = try existingItemID(forHash: hash), clash != itemID {
            throw ClipEditError.duplicate
        }

        let bytes = Data(text.utf8)
        try database.transaction { connection in
            try connection.run(
                """
                UPDATE items
                   SET title = ?, preview = ?, search_text = ?, content_hash = ?,
                       byte_size = ?, meta_json = ?
                 WHERE id = ?
                """,
                [
                    SQLValue(derived.title),
                    SQLValue(derived.preview),
                    SQLValue(derived.searchText),
                    SQLValue(hash),
                    SQLValue(bytes.count),
                    SQLValue(derived.metadata.encodedJSON()),
                    SQLValue(itemID),
                ]
            )
            // One representation replaces all of them. An edited clipping that
            // still offered its original RTF would paste the text you removed.
            try connection.run("DELETE FROM payloads WHERE item_id = ?", [SQLValue(itemID)])
            try connection.run(
                """
                INSERT INTO payloads (item_id, pb_index, ord, uti, byte_size, inline_data, blob_key)
                VALUES (?, 0, 0, ?, ?, ?, NULL)
                """,
                [SQLValue(itemID), SQLValue(UTI.plainText), SQLValue(bytes.count), SQLValue(bytes)]
            )
        }
    }

    /// The plain text of any editable clipping.
    func text(itemID: Int64) throws -> String? {
        guard let data = try data(itemID: itemID, uti: UTI.plainText) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    internal func existingItemID(forHash hash: String) throws -> Int64? {
        try database.read { connection in
            try connection.query("SELECT id FROM items WHERE content_hash = ? LIMIT 1", [SQLValue(hash)])
                .first?
                .int("id")
        }
    }
}

/// Everything the deck shows about a clipping that is derived from its text,
/// recomputed after an edit. Mirrors the text branch of ``ClipClassifier`` so
/// an edited clipping looks exactly like a freshly copied one.
struct TextFacts {
    var title: String
    var preview: String
    var searchText: String
    var metadata: ClipMetadata

    init(text: String, kind: ClipKind, existingMetadata: ClipMetadata) {
        let limits = ClipClassifier.Limits()
        let counts = TextAnalysis.counts(for: text)

        var metadata = existingMetadata
        metadata.characters = counts.characters
        metadata.words = counts.words
        metadata.lines = counts.lines
        metadata.utis = [UTI.plainText]

        switch kind {
        case .link:
            let link = TextAnalysis.link(in: text)
            metadata.url = link?.url ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
            metadata.host = link?.host
            metadata.scheme = link?.scheme
            title = link?.host.map { host in
                let path = URLComponents(string: link?.url ?? "")?.path ?? ""
                return path.isEmpty || path == "/" ? host : host + path
            } ?? TextAnalysis.title(for: text)
            title = TextAnalysis.truncate(title, to: 90)

        case .code:
            // Re-detected, so editing Swift into SQL relabels the footer — but
            // the kind itself stays code either way.
            metadata.language = TextAnalysis.code(in: text)?.language
            title = TextAnalysis.title(for: text)

        default:
            title = TextAnalysis.title(for: text)
        }

        if title.isEmpty { title = kind.displayName }
        preview = TextAnalysis.truncate(text, to: limits.previewCharacters)
        searchText = String(text.prefix(limits.maxSearchTextCharacters))
        self.metadata = metadata
    }
}
