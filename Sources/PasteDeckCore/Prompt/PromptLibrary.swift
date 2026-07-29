import CryptoKit
import Foundation

/// Creating, editing and seeding prompts.
///
/// Prompts are ordinary rows in `items` with ``ClipKind/prompt``, which means
/// search, categories, payload storage and the deck's rendering all work on
/// them for free. What differs is lifecycle: they're written rather than
/// captured, so they're editable and never pruned.
public enum PromptLibrary {
    /// Where a prompt claims to come from, since no other app put it there.
    public static let sourceName = "PasteDeck"

    public static func newClip(title: String, body: String, now: Date = Date()) -> NewClip {
        let cleanTitle = displayTitle(title: title, body: body)
        let template = PromptTemplate(body: body)

        var metadata = ClipMetadata()
        metadata.characters = body.count
        metadata.words = body.split(whereSeparator: \.isWhitespace).count
        metadata.lines = body.isEmpty ? 0 : body.components(separatedBy: .newlines).count
        metadata.utis = [UTI.plainText]
        metadata.promptVariables = template.variables.map(\.name)

        return NewClip(
            kind: .prompt,
            capturedAt: now,
            title: cleanTitle,
            preview: String(body.prefix(1200)),
            // The title is searchable on its own, and so are the slot names —
            // "the one with the audience variable" is a real way to look.
            searchText: ([cleanTitle, body] + template.variables.map(\.name)).joined(separator: " "),
            contentHash: hash(title: cleanTitle, body: body),
            sourceAppName: sourceName,
            metadata: metadata,
            payloads: [(pasteboardIndex: 0, uti: UTI.plainText, data: Data(body.utf8))]
        )
    }

    /// Falls back to the first meaningful line of the body, so saving a prompt
    /// never demands a name up front.
    public static func displayTitle(title: String, body: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return String(trimmed.prefix(120)) }

        let firstLine = body
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return firstLine.isEmpty ? "Untitled prompt" : String(firstLine.prefix(120))
    }

    /// Namespaced so a prompt whose body happens to equal a copied snippet
    /// doesn't collide with it on the unique content-hash index. The title is
    /// folded in too: two prompts can legitimately share a body.
    static func hash(title: String, body: String) -> String {
        let digest = SHA256.hash(data: Data("prompt:\(title)\u{1}\(body)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Shipped on first run so the Prompts tab isn't an empty box that has to
    /// be explained. Each one shows off a different slot.
    public static let starters: [(title: String, body: String)] = [
        (
            "Explain this code",
            """
            Explain what this does, then point out anything that looks wrong:

            {{clipboard}}
            """
        ),
        (
            "Debug with context",
            """
            I'm hitting an error. Here's everything relevant:

            {{stack}}

            What's the most likely cause, and what should I check first?
            """
        ),
        (
            "Rewrite for an audience",
            """
            Rewrite the following for {{audience}}. Keep it {{tone}} and don't
            lose any detail that changes the meaning.

            {{clipboard}}
            """
        ),
        (
            "Commit message",
            """
            Write a commit message for this diff. One short subject line under
            60 characters, then a body explaining why rather than what.

            {{stack}}
            """
        ),
    ]
}

public extension ClipStore {
    /// Writes a new prompt. Returns nil only if an identical prompt (same title
    /// and body) already exists, in which case it's promoted to the top.
    @discardableResult
    func createPrompt(title: String, body: String, now: Date = Date()) throws -> ClipItem {
        switch try insert(PromptLibrary.newClip(title: title, body: body, now: now)) {
        case .inserted(let item), .promoted(let item):
            return item
        }
    }

    /// Rewrites a prompt in place, keeping its id, categories and use count.
    ///
    /// The payload is replaced rather than appended: a prompt has exactly one
    /// representation, and leaving the old text behind would mean pasting the
    /// version the user just edited away.
    func updatePrompt(itemID: Int64, title: String, body: String, now: Date = Date()) throws {
        let clip = PromptLibrary.newClip(title: title, body: body, now: now)

        // Same unique content hash as everything else, so editing one prompt
        // into an exact copy of another has to be caught before the write.
        if let clash = try existingItemID(forHash: clip.contentHash), clash != itemID {
            throw ClipEditError.duplicate
        }

        try database.transaction { connection in
            try connection.run(
                """
                UPDATE items
                   SET title = ?, preview = ?, search_text = ?, content_hash = ?,
                       byte_size = ?, meta_json = ?, updated_at = ?
                 WHERE id = ?
                """,
                [
                    SQLValue(clip.title),
                    SQLValue(clip.preview),
                    SQLValue(clip.searchText),
                    SQLValue(clip.contentHash),
                    SQLValue(clip.storedBytes),
                    SQLValue(clip.metadata.encodedJSON()),
                    SQLValue(clip.capturedAt),
                    SQLValue(itemID),
                ]
            )
            try connection.run("DELETE FROM payloads WHERE item_id = ?", [SQLValue(itemID)])
            try connection.run(
                """
                INSERT INTO payloads (item_id, pb_index, ord, uti, byte_size, inline_data, blob_key)
                VALUES (?, 0, 0, ?, ?, ?, NULL)
                """,
                [
                    SQLValue(itemID),
                    SQLValue(UTI.plainText),
                    SQLValue(Int(clip.totalBytes)),
                    SQLValue(Data(body.utf8)),
                ]
            )
        }
    }

    /// The body of a prompt, read back from its payload.
    func promptBody(itemID: Int64) throws -> String? {
        guard let data = try data(itemID: itemID, uti: UTI.plainText) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Installs ``PromptLibrary/starters`` once. Deleting them all afterwards
    /// is respected — the flag lives in preferences, not in a row count.
    func seedStarterPrompts(preferences: Preferences) {
        guard !preferences.hasSeededPrompts else { return }
        preferences.hasSeededPrompts = true
        for starter in PromptLibrary.starters {
            _ = try? createPrompt(title: starter.title, body: starter.body)
        }
    }
}
