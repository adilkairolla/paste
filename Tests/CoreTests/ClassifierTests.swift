import Foundation
import PasteDeckCore

private func snapshot(
    _ representations: [(String, Data)],
    app: String = "Safari",
    bundleID: String = "com.apple.Safari"
) -> PasteboardSnapshot {
    PasteboardSnapshot(
        items: [.init(representations: representations.map { .init(uti: $0.0, data: $0.1) })],
        sourceBundleID: bundleID,
        sourceAppName: app
    )
}

private func text(_ value: String) -> PasteboardSnapshot {
    snapshot([(UTI.plainText, Data(value.utf8))])
}

func runClassifierTests() {
    let classifier = ClipClassifier()

    suite("ClipClassifier") {
        test("plain prose is text") {
            let clip = try require(classifier.classify(text("Remember to buy milk on the way home")))
            expectEqual(clip.kind, .text)
            expectEqual(clip.title, "Remember to buy milk on the way home")
            expectEqual(clip.metadata.words, 8)
            expectEqual(clip.metadata.lines, 1)
            expectEqual(clip.metadata.characters, 36)
        }

        test("titles come from the first non-empty line") {
            let clip = try require(classifier.classify(text("\n\n  Heading line  \nbody text\nmore")))
            expectEqual(clip.title, "Heading line")
            expectEqual(clip.metadata.lines, 5)
        }

        test("long text is truncated for the title but kept for search") {
            let long = String(repeating: "word ", count: 400)
            let clip = try require(classifier.classify(text(long)))
            expect(clip.title.count <= 91, "title should be trimmed, got \(clip.title.count)")
            expect(clip.title.hasSuffix("…"), "truncated titles get an ellipsis")
            expectEqual(clip.searchText.count, long.count)
        }

        test("URLs become links with host metadata") {
            for value in ["https://example.com/path?q=1", "http://sub.domain.co.uk", "example.com/docs", "www.apple.com"] {
                let clip = try require(classifier.classify(text(value)), "no clip for \(value)")
                expectEqual(clip.kind, .link, value)
                expect(clip.metadata.host?.isEmpty == false, "no host for \(value)")
            }
        }

        test("mailto links are recognised") {
            let clip = try require(classifier.classify(text("mailto:someone@example.com")))
            expectEqual(clip.kind, .link)
            expectEqual(clip.metadata.scheme, "mailto")
        }

        test("text that merely mentions a URL stays text") {
            let clip = try require(classifier.classify(text("see https://example.com for details")))
            expectEqual(clip.kind, .text)
        }

        test("hex and rgb strings become colors") {
            for value in ["#fff", "#FF8800", "#ff8800aa", "rgb(12, 240, 8)"] {
                let clip = try require(classifier.classify(text(value)), "no clip for \(value)")
                expectEqual(clip.kind, .color, value)
                expect(clip.metadata.colorHex?.hasPrefix("#") == true, "no hex for \(value)")
            }
        }

        test("out of range rgb is not a color") {
            let clip = try require(classifier.classify(text("rgb(300, 0, 0)")))
            expect(clip.kind != .color, "rgb components above 255 are not a colour")
        }

        test("source code is detected and labelled") {
            let source = """
            func greet(name: String) -> String {
                guard !name.isEmpty else { return "hi" }
                return "Hello there"
            }
            """
            let clip = try require(classifier.classify(text(source)))
            expectEqual(clip.kind, .code)
            expectEqual(clip.metadata.language, "Swift")
        }

        test("JSON is recognised as code") {
            let clip = try require(classifier.classify(text(#"{"id": 7, "name": "deck", "tags": ["a","b"]}"#)))
            expectEqual(clip.kind, .code)
            expectEqual(clip.metadata.language, "JSON")
        }

        test("a shell command is code") {
            let clip = try require(classifier.classify(text("grep -rn 'needle' . && echo done")))
            expectEqual(clip.kind, .code)
        }

        test("rtf alongside plain text is rich text") {
            let clip = try require(classifier.classify(snapshot([
                (UTI.rtf, Data("{\\rtf1\\ansi styled}".utf8)),
                (UTI.plainText, Data("styled".utf8)),
            ])))
            expectEqual(clip.kind, .richText)
            expectEqual(clip.payloads.count, 2, "both representations are kept for faithful paste-back")
        }

        test("file URLs become file clippings") {
            let pasteboard = PasteboardSnapshot(items: [
                .init(representations: [.init(uti: UTI.fileURL, data: Data("file:///tmp/one.txt".utf8))]),
                .init(representations: [.init(uti: UTI.fileURL, data: Data("file:///tmp/two.txt".utf8))]),
            ])
            let clip = try require(classifier.classify(pasteboard))
            expectEqual(clip.kind, .file)
            expectEqual(clip.title, "2 files")
            expectEqual(clip.metadata.filePaths ?? [], ["/tmp/one.txt", "/tmp/two.txt"])
            expectEqual(Set(clip.payloads.map(\.pasteboardIndex)), [0, 1], "grouping is preserved")
        }

        test("a single file is titled by its name") {
            let clip = try require(classifier.classify(
                snapshot([(UTI.fileURL, Data("file:///Users/me/Documents/report%20final.pdf".utf8))])
            ))
            expectEqual(clip.kind, .file)
            expectEqual(clip.title, "report final.pdf")
        }

        test("images carry dimensions and a thumbnail") {
            let png = try require(Fixture.png(width: 40, height: 25))
            let clip = try require(classifier.classify(snapshot([(UTI.png, png)])))
            expectEqual(clip.kind, .image)
            expectEqual(clip.metadata.pixelWidth, 40)
            expectEqual(clip.metadata.pixelHeight, 25)
            expect(clip.thumbnail != nil, "a thumbnail should be generated")
            expect(clip.title.contains("40 × 25"), "title should mention dimensions, got \(clip.title)")
        }

        test("big images get a small thumbnail") {
            let png = try require(Fixture.png(width: 2400, height: 1600))
            let clip = try require(classifier.classify(snapshot([(UTI.png, png)])))
            let thumbnail = try require(clip.thumbnail)
            let info = try require(ImageInspector.inspect(thumbnail))
            expect(max(info.width, info.height) <= 384, "thumbnail should be downscaled, got \(info)")
            expect(thumbnail.count < png.count, "thumbnail should be smaller than the original")
        }

        test("concealed and transient pasteboards are skipped") {
            let secret = snapshot([
                ("org.nspasteboard.ConcealedType", Data("1".utf8)),
                (UTI.plainText, Data("hunter2".utf8)),
            ])
            expect(classifier.classify(secret) == nil, "password manager clips must be ignored")

            let ours = snapshot([
                (UTI.internalMarker, Data("1".utf8)),
                (UTI.plainText, Data("round trip".utf8)),
            ])
            expect(classifier.classify(ours) == nil, "our own writes must not be re-captured")
        }

        test("empty pasteboards produce nothing") {
            expect(classifier.classify(text("")) == nil)
            expect(classifier.classify(text("   \n  ")) == nil, "whitespace only is not worth keeping")
            expect(classifier.classify(PasteboardSnapshot(items: [])) == nil)
        }

        test("the same text hashes the same way regardless of source app") {
            let a = try require(classifier.classify(snapshot([(UTI.plainText, Data("dedupe me".utf8))], app: "Notes")))
            let b = try require(classifier.classify(snapshot([(UTI.plainText, Data("dedupe me".utf8))], app: "Terminal")))
            expectEqual(a.contentHash, b.contentHash)
        }

        test("different kinds never collide") {
            let link = try require(classifier.classify(text("https://example.com")))
            let plain = try require(classifier.classify(text("https://example.com ")))
            expect(link.contentHash != plain.contentHash, "trailing space changes the content")
        }

        test("promise types and empty representations are dropped") {
            let clip = try require(classifier.classify(snapshot([
                (UTI.plainText, Data("real".utf8)),
                ("com.apple.pasteboard.promised-file-url", Data("x".utf8)),
                ("public.rtf", Data()),
            ])))
            expectEqual(clip.payloads.map(\.uti), [UTI.plainText])
        }

        test("representations over the size budget are dropped, primary kept") {
            var limited = ClipClassifier()
            limited.limits = ClipClassifier.Limits(maxRepresentationBytes: 4096, maxTotalBytes: 4096)
            let clip = try require(limited.classify(snapshot([
                (UTI.plainText, Data("small".utf8)),
                (UTI.rtf, Data(repeating: 0x41, count: 5000)),
            ])))
            expectEqual(clip.payloads.map(\.uti), [UTI.plainText])
        }
    }
}
