import Foundation
import PasteDeckCore

private func textClip(
    _ text: String,
    app: String = "Xcode",
    bundleID: String = "com.apple.dt.Xcode",
    at date: Date = Date()
) -> NewClip {
    let snapshot = PasteboardSnapshot(
        items: [.init(representations: [.init(uti: UTI.plainText, data: Data(text.utf8))])],
        sourceBundleID: bundleID,
        sourceAppName: app,
        capturedAt: date
    )
    return ClipClassifier().classify(snapshot)!
}

private func inserted(_ store: ClipStore, _ clip: NewClip) throws -> ClipItem {
    guard case .inserted(let item) = try store.insert(clip) else {
        throw Check.RequirementFailure(message: "expected an insert, got a promotion")
    }
    return item
}

func runStoreTests() {
    suite("ClipStore") {
        test("inserts and reads back an item with its payload") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let item = try inserted(store, textClip("hello deck"))

                expectEqual(item.kind, .text)
                expectEqual(item.title, "hello deck")
                expectEqual(item.sourceAppName, "Xcode")
                expectEqual(item.sourceBundleID, "com.apple.dt.Xcode")

                let payloads = try store.payloads(itemID: item.id)
                expectEqual(payloads.count, 1)
                expectEqual(payloads.first?.uti, UTI.plainText)
                expectEqual(
                    store.data(for: payloads[0]).flatMap { String(data: $0, encoding: .utf8) },
                    "hello deck"
                )
            }
        }

        test("identical content is promoted rather than duplicated") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let first = Date(timeIntervalSince1970: 1_000)
                let later = Date(timeIntervalSince1970: 2_000)

                _ = try store.insert(textClip("same text", at: first))
                _ = try store.insert(textClip("different", at: first.addingTimeInterval(1)))
                let outcome = try store.insert(
                    textClip("same text", app: "Safari", bundleID: "com.apple.Safari", at: later)
                )

                guard case .promoted(let promoted) = outcome else {
                    fail("expected a promotion, got \(outcome)")
                    return
                }
                expectEqual(promoted.updatedAt, later)
                expectEqual(try store.count(), 2)

                // Promotion moves it back to the front of the deck and re-attributes it.
                let items = try store.items()
                expectEqual(items.first?.title, "same text")
                expectEqual(items.first?.sourceAppName, "Safari")
            }
        }

        test("payloads over the inline threshold move to the blob store") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let big = String(repeating: "abcdefgh", count: 20_000) // 160 KB
                let item = try inserted(store, textClip(big))

                let payloads = try store.payloads(itemID: item.id)
                expect(payloads[0].blobKey != nil, "large payload should live in a blob")
                expectEqual(store.data(for: payloads[0])?.count, big.utf8.count)
                expectEqual(try store.referencedBlobKeys().count, 1)
            }
        }

        test("full text search matches prefixes and ignores case") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                _ = try store.insert(textClip("The quick brown fox"))
                _ = try store.insert(textClip("Slow green turtle"))
                _ = try store.insert(textClip("https://example.com/quick-start"))

                expectEqual(try store.items(ClipQuery(search: "quick")).count, 2, "prefix across kinds")
                expectEqual(try store.items(ClipQuery(search: "QUI")).count, 2, "case insensitive")
                expectEqual(try store.items(ClipQuery(search: "turtle")).count, 1)
                expectEqual(try store.items(ClipQuery(search: "nothing here")).count, 0)
                expectEqual(try store.items(ClipQuery(search: "quick fox")).count, 1, "terms are ANDed")
            }
        }

        test("search matches the source app name") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                _ = try store.insert(textClip("some note", app: "Notes", bundleID: "com.apple.Notes"))
                _ = try store.insert(textClip("a terminal line", app: "Ghostty", bundleID: "com.mitchellh.ghostty"))
                expectEqual(try store.items(ClipQuery(search: "ghostty")).count, 1)
            }
        }

        test("search survives punctuation in the query") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                _ = try store.insert(textClip("https://example.com/a-b"))
                // Quotes and bare operators must not blow up the FTS parser.
                expectEqual(try store.items(ClipQuery(search: "\"example")).count, 1)
                expectEqual(try store.items(ClipQuery(search: "example.com")).count, 1)
                expectEqual(try store.items(ClipQuery(search: "zzz *")).count, 0)
            }
        }

        test("search index stays in sync when items are deleted") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let item = try inserted(store, textClip("ephemeral content"))
                expectEqual(try store.items(ClipQuery(search: "ephemeral")).count, 1)

                try store.delete(itemIDs: [item.id])
                expectEqual(try store.items(ClipQuery(search: "ephemeral")).count, 0)
            }
        }

        test("kind filters split the deck") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                _ = try store.insert(textClip("plain sentence here"))
                _ = try store.insert(textClip("https://apple.com"))
                _ = try store.insert(textClip("#ff8800"))

                expectEqual(try store.items(ClipQuery(filter: .links)).count, 1)
                expectEqual(try store.items(ClipQuery(filter: .colors)).count, 1)
                expectEqual(try store.items(ClipQuery(filter: .text)).count, 1)
                expectEqual(try store.items(ClipQuery(filter: .all)).count, 3)
            }
        }

        test("pinned filter and pin toggling") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let item = try inserted(store, textClip("pin this one"))
                _ = try store.insert(textClip("leave this one"))

                expectEqual(try store.count(.pinned), 0)
                try store.setPinned(true, itemID: item.id)
                expectEqual(try store.count(.pinned), 1)
                expectEqual(try store.items(ClipQuery(filter: .pinned)).first?.isPinned, true)

                try store.setPinned(false, itemID: item.id)
                expectEqual(try store.count(.pinned), 0)
            }
        }

        test("categories are many-to-many and load with items") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let work = try store.createCategory(name: "Work", symbolName: "briefcase", colorName: "orange")
                let snippets = try store.createCategory(name: "Snippets")
                let item = try inserted(store, textClip("shared item"))

                try store.addItem(item.id, toCategory: work.id)
                try store.addItem(item.id, toCategory: snippets.id)
                try store.addItem(item.id, toCategory: work.id) // idempotent

                expectEqual(try store.count(.category(work.id)), 1)
                let fetched = try store.items(ClipQuery(filter: .category(snippets.id)))
                expectEqual(fetched.count, 1)
                expectEqual(Set(fetched.first?.categoryIDs ?? []), [work.id, snippets.id])

                try store.removeItem(item.id, fromCategory: work.id)
                expectEqual(try store.count(.category(work.id)), 0)

                // Deleting a category must not delete the items in it.
                try store.deleteCategory(id: snippets.id)
                expectEqual(try store.count(), 1)
                expectEqual(try store.categories().count, 1)
            }
        }

        test("category listing reports item counts in sort order") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let alpha = try store.createCategory(name: "Alpha")
                let beta = try store.createCategory(name: "Beta")
                let item = try inserted(store, textClip("counted"))
                try store.addItem(item.id, toCategory: beta.id)

                var categories = try store.categories()
                expectEqual(categories.map(\.name), ["Alpha", "Beta"])
                expectEqual(categories.last?.itemCount, 1)

                try store.reorderCategories(ids: [beta.id, alpha.id])
                categories = try store.categories()
                expectEqual(categories.map(\.name), ["Beta", "Alpha"])

                try store.updateCategory(id: alpha.id, name: "Renamed", colorName: "green")
                expectEqual(try store.categories().last?.name, "Renamed")
                expectEqual(try store.categories().last?.colorName, "green")
            }
        }

        test("clearing history spares pinned and filed items") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let pinned = try inserted(store, textClip("keep me pinned"))
                let filed = try inserted(store, textClip("keep me filed"))
                _ = try inserted(store, textClip("throwaway"))

                let category = try store.createCategory(name: "Keep")
                try store.setPinned(true, itemID: pinned.id)
                try store.addItem(filed.id, toCategory: category.id)

                try store.deleteAll()
                expectEqual(try store.count(), 2)

                try store.deleteAll(everything: true)
                expectEqual(try store.count(), 0)
            }
        }

        test("usage counters advance") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let item = try inserted(store, textClip("used often"))
                try store.markUsed(itemID: item.id)
                try store.markUsed(itemID: item.id)

                let reloaded = try require(store.item(id: item.id))
                expectEqual(reloaded.useCount, 2)
                expect(reloaded.lastUsedAt != nil, "lastUsedAt should be set")
            }
        }

        test("pasting an item moves it back to the front of the deck") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let base = Date(timeIntervalSince1970: 50_000)
                let oldest = try inserted(store, textClip("buried item", at: base))
                _ = try inserted(store, textClip("middle item", at: base.addingTimeInterval(10)))
                _ = try inserted(store, textClip("newest item", at: base.addingTimeInterval(20)))
                expectEqual(try store.items().first?.title, "newest item")

                try store.markUsed(itemID: oldest.id, at: base.addingTimeInterval(30))
                expectEqual(try store.items().first?.title, "buried item", "using a clipping makes it recent")

                // …and it is no longer the first candidate for pruning.
                _ = try Retention.prune(
                    store: store,
                    policy: RetentionPolicy(maxItems: 2, maxAgeDays: 0, maxBytes: 0),
                    now: base.addingTimeInterval(40)
                )
                expectEqual(Set(try store.items().map(\.title)), ["buried item", "newest item"])
            }
        }

        test("paging returns newest first") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let base = Date(timeIntervalSince1970: 10_000)
                for index in 0..<25 {
                    _ = try store.insert(textClip("row \(index)", at: base.addingTimeInterval(Double(index))))
                }
                let firstPage = try store.items(ClipQuery(limit: 10))
                let secondPage = try store.items(ClipQuery(limit: 10, offset: 10))
                expectEqual(firstPage.count, 10)
                expectEqual(firstPage.first?.title, "row 24")
                expectEqual(secondPage.first?.title, "row 14")
            }
        }

        test("the store reopens an existing database") {
            try Fixture.withTemporaryDirectory { directory in
                do {
                    let store = try ClipStore(directory: directory)
                    _ = try store.insert(textClip("persisted"))
                }
                let reopened = try ClipStore(directory: directory)
                expectEqual(try reopened.count(), 1)
                expectEqual(try reopened.items().first?.title, "persisted")
            }
        }
    }
}
