import Foundation
import PasteDeckCore

private func insert(_ store: ClipStore, _ text: String, at date: Date, padding: Int = 0) throws -> ClipItem {
    let payload = padding > 0 ? text + String(repeating: "x", count: padding) : text
    let snapshot = PasteboardSnapshot(
        items: [.init(representations: [.init(uti: UTI.plainText, data: Data(payload.utf8))])],
        sourceAppName: "Test",
        capturedAt: date
    )
    guard case .inserted(let item) = try store.insert(ClipClassifier().classify(snapshot)!) else {
        throw Check.RequirementFailure(message: "expected an insert")
    }
    return item
}

func runRetentionTests() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    suite("Retention") {
        test("age limit drops old items and keeps recent ones") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                _ = try insert(store, "ancient", at: now.addingTimeInterval(-40 * 86_400))
                _ = try insert(store, "recent", at: now.addingTimeInterval(-2 * 86_400))

                let report = try Retention.prune(
                    store: store,
                    policy: RetentionPolicy(maxItems: 0, maxAgeDays: 30, maxBytes: 0),
                    now: now
                )
                expectEqual(report.deletedByAge, 1)
                expectEqual(try store.items().map(\.title), ["recent"])
            }
        }

        test("count limit keeps the newest N") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                for index in 0..<10 {
                    _ = try insert(store, "item \(index)", at: now.addingTimeInterval(Double(index)))
                }

                let report = try Retention.prune(
                    store: store,
                    policy: RetentionPolicy(maxItems: 4, maxAgeDays: 0, maxBytes: 0),
                    now: now
                )
                expectEqual(report.deletedByCount, 6)
                expectEqual(try store.items().map(\.title), ["item 9", "item 8", "item 7", "item 6"])
            }
        }

        test("pinned and filed items are never pruned") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let old = now.addingTimeInterval(-365 * 86_400)
                let pinned = try insert(store, "pinned ancient", at: old)
                let filed = try insert(store, "filed ancient", at: old)
                _ = try insert(store, "plain ancient", at: old)

                let category = try store.createCategory(name: "Keep")
                try store.setPinned(true, itemID: pinned.id)
                try store.addItem(filed.id, toCategory: category.id)

                let report = try Retention.prune(
                    store: store,
                    policy: RetentionPolicy(maxItems: 1, maxAgeDays: 1, maxBytes: 1),
                    now: now
                )
                expectEqual(report.totalDeleted, 1)
                expectEqual(Set(try store.items().map(\.title)), ["pinned ancient", "filed ancient"])
            }
        }

        test("size limit trims oldest until under budget") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                for index in 0..<5 {
                    _ = try insert(store, "chunk \(index) ", at: now.addingTimeInterval(Double(index)), padding: 10_000)
                }
                expect(try store.totalBytes() > 50_000)

                _ = try Retention.prune(
                    store: store,
                    policy: RetentionPolicy(maxItems: 0, maxAgeDays: 0, maxBytes: 25_000),
                    now: now
                )
                expectEqual(try store.count(), 2)
                expect(try store.totalBytes() <= 25_000, "should be under budget")
            }
        }

        test("orphaned blobs are reclaimed") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let item = try insert(store, "blob ", at: now, padding: 200_000)
                expectEqual(try store.referencedBlobKeys().count, 1)
                expect(store.blobs.totalBytes() > 100_000)

                try store.delete(itemIDs: [item.id])
                let report = try Retention.prune(store: store, policy: .unlimited, now: now)
                expect(report.blobBytesReclaimed > 100_000, "blob bytes should be reclaimed")
                expectEqual(store.blobs.totalBytes(), 0)
            }
        }

        test("blobs still referenced are never collected") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                _ = try insert(store, "keep ", at: now, padding: 200_000)
                let report = try Retention.prune(store: store, policy: .unlimited, now: now)
                expectEqual(report.blobBytesReclaimed, 0)
                expect(store.blobs.totalBytes() > 100_000, "live blob must survive GC")
            }
        }

        test("unlimited policy deletes nothing") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                _ = try insert(store, "very old", at: now.addingTimeInterval(-10_000 * 86_400))
                let report = try Retention.prune(store: store, policy: .unlimited, now: now)
                expectEqual(report.totalDeleted, 0)
                expectEqual(try store.count(), 1)
            }
        }

        test("usage reporting counts protected items") {
            try Fixture.withTemporaryDirectory { directory in
                let store = try ClipStore(directory: directory)
                let pinned = try insert(store, "pinned", at: now)
                _ = try insert(store, "loose", at: now.addingTimeInterval(1))
                try store.setPinned(true, itemID: pinned.id)

                let usage = try Retention.usage(store: store)
                expectEqual(usage.items, 2)
                expectEqual(usage.protectedItems, 1)
                expect(usage.bytes > 0)
            }
        }
    }
}
