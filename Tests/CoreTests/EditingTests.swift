import Foundation
import PasteDeckCore

private func clip(
    _ text: String,
    app: String = "Xcode",
    utis: [(String, String)] = [],
    at date: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> NewClip {
    var representations = [PasteboardSnapshot.Representation(uti: UTI.plainText, data: Data(text.utf8))]
    representations += utis.map { .init(uti: $0.0, data: Data($0.1.utf8)) }
    let snapshot = PasteboardSnapshot(
        items: [.init(representations: representations)],
        sourceBundleID: "com.example.\(app)",
        sourceAppName: app,
        capturedAt: date
    )
    return ClipClassifier().classify(snapshot)!
}

func runEditingTests() {
    suite("ClipKind.isEditable") {
        test("only kinds whose content is plain text can be rewritten") {
            expectEqual(ClipKind.allCases.filter(\.isEditable), [.text, .code, .link, .prompt])
        }

        test("rich text is protected because editing would drop its formatting") {
            expect(!ClipKind.richText.isEditable)
        }
    }

    suite("ClipStore.updateText") {
        test("rewrites the text and reads it back") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                guard case .inserted(let item) = try store.insert(clip("first draft")) else { return }

                try store.updateText(itemID: item.id, text: "second draft")

                expectEqual(try store.text(itemID: item.id), "second draft")
                let reloaded = try require(try store.item(id: item.id))
                expectEqual(reloaded.id, item.id)
                expectEqual(reloaded.title, "second draft")
                expectEqual(reloaded.preview, "second draft")
            }
        }

        test("recomputes counts, size and hash") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                guard case .inserted(let item) = try store.insert(clip("one")) else { return }

                try store.updateText(itemID: item.id, text: "one two three")

                let reloaded = try require(try store.item(id: item.id))
                expectEqual(reloaded.metadata.words, 3)
                expectEqual(reloaded.metadata.characters, 13)
                expectEqual(reloaded.byteSize, 13)
                expect(reloaded.contentHash != item.contentHash, "hash did not change")
            }
        }

        test("keeps the card where it is rather than resurfacing it") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let old = Date(timeIntervalSince1970: 1_600_000_000)
                guard case .inserted(let item) = try store.insert(clip("old note", at: old)) else { return }
                _ = try store.insert(clip("newer note", app: "Safari"))

                try store.updateText(itemID: item.id, text: "old note, edited")

                expectEqual(try require(try store.item(id: item.id)).updatedAt, old)
                // Still second in the deck, not promoted to the front.
                expectEqual(try store.items().map(\.id).last, item.id)
            }
        }

        test("keeps pins and categories") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                guard case .inserted(let item) = try store.insert(clip("keep me")) else { return }
                let category = try store.createCategory(name: "Work")
                try store.addItem(item.id, toCategory: category.id)
                try store.setPinned(true, itemID: item.id)

                try store.updateText(itemID: item.id, text: "keep me, edited")

                let reloaded = try require(try store.item(id: item.id))
                expect(reloaded.isPinned)
                expectEqual(reloaded.categoryIDs, [category.id])
            }
        }

        test("replaces every representation, so no stale copy survives") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let withHTML = clip("plain version", utis: [(UTI.html, "<b>rich version</b>")])
                guard case .inserted(let item) = try store.insert(withHTML) else { return }
                expect(try store.payloads(itemID: item.id).count > 1, "fixture had only one payload")

                try store.updateText(itemID: item.id, text: "edited")

                let payloads = try store.payloads(itemID: item.id)
                expectEqual(payloads.count, 1)
                expectEqual(payloads.first?.uti, UTI.plainText)
            }
        }

        test("re-derives link metadata from the new URL") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                guard case .inserted(let item) = try store.insert(clip("https://example.com/one")) else { return }
                expectEqual(item.kind, .link)

                try store.updateText(itemID: item.id, text: "https://apple.com/two")

                let reloaded = try require(try store.item(id: item.id))
                expectEqual(reloaded.metadata.host, "apple.com")
                expectEqual(reloaded.metadata.url, "https://apple.com/two")
                expectEqual(reloaded.title, "apple.com/two")
            }
        }

        test("re-detects the language of edited code without changing its kind") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let swift = "func greet(name: String) -> String {\n    return \"hi \\(name)\"\n}"
                guard case .inserted(let item) = try store.insert(clip(swift)) else { return }
                expectEqual(item.kind, .code)
                expectEqual(item.metadata.language, "Swift")

                try store.updateText(
                    itemID: item.id,
                    text: "SELECT id FROM items WHERE kind = 'code';\nUPDATE items SET pinned = 1;"
                )

                let reloaded = try require(try store.item(id: item.id))
                expectEqual(reloaded.metadata.language, "SQL")
                // The kind is deliberately sticky — no jumping between tabs.
                expectEqual(reloaded.kind, .code)
            }
        }

        test("an edit is findable by its new text and not its old") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                guard case .inserted(let item) = try store.insert(clip("aardvark")) else { return }

                try store.updateText(itemID: item.id, text: "bandicoot")

                expectEqual(try store.items(ClipQuery(search: "bandicoot")).count, 1)
                expectEqual(try store.items(ClipQuery(search: "aardvark")).count, 0)
            }
        }

        test("refuses an edit that would duplicate another clipping") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                _ = try store.insert(clip("already here"))
                guard case .inserted(let second) = try store.insert(clip("distinct", app: "Safari")) else { return }

                do {
                    try store.updateText(itemID: second.id, text: "already here")
                    fail("expected a duplicate error")
                } catch ClipEditError.duplicate {
                    expectEqual(try store.text(itemID: second.id), "distinct")
                    expectEqual(try store.count(.all), 2)
                }
            }
        }

        test("saving a clipping unchanged is not treated as a duplicate of itself") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                guard case .inserted(let item) = try store.insert(clip("unchanged")) else { return }
                try store.updateText(itemID: item.id, text: "unchanged")
                expectEqual(try store.text(itemID: item.id), "unchanged")
            }
        }

        test("refuses empty text and uneditable kinds") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                guard case .inserted(let item) = try store.insert(clip("something")) else { return }

                do {
                    try store.updateText(itemID: item.id, text: "   \n  ")
                    fail("expected an empty error")
                } catch ClipEditError.empty {}

                let png = try require(Fixture.png(width: 8, height: 8))
                let snapshot = PasteboardSnapshot(
                    items: [.init(representations: [.init(uti: UTI.png, data: png)])],
                    sourceAppName: "Preview"
                )
                guard case .inserted(let image) = try store.insert(ClipClassifier().classify(snapshot)!) else { return }

                do {
                    try store.updateText(itemID: image.id, text: "nope")
                    fail("expected a notEditable error")
                } catch ClipEditError.notEditable(let kind) {
                    expectEqual(kind, .image)
                }
            }
        }

        test("editing a prompt keeps its title and re-parses its slots") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let prompt = try store.createPrompt(title: "Summarise", body: "Summarise {{text}}")

                try store.updateText(itemID: prompt.id, text: "Summarise {{text}} for {{audience}}")

                let reloaded = try require(try store.item(id: prompt.id))
                expectEqual(reloaded.title, "Summarise")
                expectEqual(reloaded.metadata.promptVariables ?? [], ["text", "audience"])
            }
        }
    }
}
