import AppKit
import PasteDeckCore
import SwiftUI

/// Renders the deck offscreen into a PNG: `PasteDeck --render-preview out.png`.
///
/// Handy for iterating on layout without a screen recording permission, and for
/// the screenshot in the README.
@MainActor
enum PreviewRenderer {
    static func render(
        to path: String,
        width: CGFloat = 1440,
        height: CGFloat = Theme.deckHeight,
        appearanceName: NSAppearance.Name = .darkAqua
    ) {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pastedeck-preview-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let store = try ClipStore(directory: directory)
            try seed(store)

            let model = DeckModel(
                store: store,
                pasteService: PasteService(store: store, monitor: nil),
                preferences: Preferences(defaults: UserDefaults(suiteName: "app.pastedeck.preview")!)
            )
            model.reload(resetSelection: true)
            if model.items.count > 1 {
                model.selectedItemID = model.items[1].id
            }
            if CommandLine.arguments.contains("--large") {
                model.selectedItemID = model.items.first { $0.kind == .image }?.id ?? model.selectedItemID
                model.isPreviewingLarge = true
            }
            // `--zone categories|search|items` so focus states can be eyeballed
            // without driving the real panel.
            if let index = CommandLine.arguments.firstIndex(of: "--zone"),
               index + 1 < CommandLine.arguments.count {
                switch CommandLine.arguments[index + 1] {
                case "search": model.focusZone = .search
                case "categories": model.focusZone = .categories
                default: model.focusZone = .items
                }
            }

            // `--tab <id>` picks a filter tab, e.g. `--tab prompts`.
            if let index = CommandLine.arguments.firstIndex(of: "--tab"),
               index + 1 < CommandLine.arguments.count {
                model.selectedTabID = CommandLine.arguments[index + 1]
                model.reload(resetSelection: true)
            }

            // `--stack N` gathers the first N stackable clippings.
            if let index = CommandLine.arguments.firstIndex(of: "--stack"),
               index + 1 < CommandLine.arguments.count,
               let count = Int(CommandLine.arguments[index + 1]) {
                for item in model.items.filter({ $0.kind.isStackable }).prefix(count) {
                    model.toggleStack(item)
                }
                model.toast = nil
            }

            // `--fill` opens the slot sheet on the first prompt that has one.
            if CommandLine.arguments.contains("--fill") {
                model.selectedTabID = "prompts"
                model.reload(resetSelection: true)
                if let prompt = model.items.first(where: {
                    !PromptTemplate(body: model.promptBody(for: $0)).userVariables.isEmpty
                }) {
                    model.selectedItemID = prompt.id
                    model.paste(prompt)
                }
            }

            let view = ZStack {
                Color(nsColor: .underPageBackgroundColor)
                DeckView(model: model)
            }
            .frame(width: width, height: height)

            // A real window, not `ImageRenderer`: lazy scroll content only
            // materialises once AppKit has laid the view out for a window.
            let frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.appearance = NSAppearance(named: appearanceName)
            window.backgroundColor = .clear
            window.isOpaque = false

            let hosting = NSHostingView(rootView: view)
            hosting.frame = frame
            window.contentView = hosting
            window.orderBack(nil)

            hosting.layoutSubtreeIfNeeded()
            for _ in 0..<24 {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            hosting.layoutSubtreeIfNeeded()

            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                FileHandle.standardError.write(Data("could not allocate a bitmap\n".utf8))
                exit(1)
            }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("could not encode PNG\n".utf8))
                exit(1)
            }
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("preview failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func seed(_ store: ClipStore) throws {
        let now = Date()
        let classifier = ClipClassifier()

        func add(
            _ representations: [(String, Data)],
            app: String,
            bundleID: String,
            minutesAgo: Double
        ) throws -> ClipItem? {
            let snapshot = PasteboardSnapshot(
                items: [.init(representations: representations.map { .init(uti: $0.0, data: $0.1) })],
                sourceBundleID: bundleID,
                sourceAppName: app,
                capturedAt: now.addingTimeInterval(-minutesAgo * 60)
            )
            guard let clip = classifier.classify(snapshot) else { return nil }
            if case .inserted(let item) = try store.insert(clip) { return item }
            return nil
        }

        func text(_ value: String, app: String, bundleID: String, minutesAgo: Double) throws -> ClipItem? {
            try add([(UTI.plainText, Data(value.utf8))], app: app, bundleID: bundleID, minutesAgo: minutesAgo)
        }

        let work = try store.createCategory(name: "Work", symbolName: "briefcase", colorName: "orange")
        let snippets = try store.createCategory(name: "Snippets", symbolName: "chevron.left.forwardslash.chevron.right", colorName: "green")

        let code = try text(
            """
            func recentClippings(limit: Int) throws -> [ClipItem] {
                try store.items(ClipQuery(filter: .all, limit: limit))
            }
            """,
            app: "Xcode", bundleID: "com.apple.dt.Xcode", minutesAgo: 2
        )
        _ = try text("https://developer.apple.com/documentation/appkit/nspasteboard",
                     app: "Safari", bundleID: "com.apple.Safari", minutesAgo: 6)

        if let png = samplePNG() {
            _ = try add([(UTI.png, png)], app: "Preview", bundleID: "com.apple.Preview", minutesAgo: 11)
        }

        let note = try text("Ship the retention policy before the release. Pinned so it survives the nightly prune.",
                            app: "Notes", bundleID: "com.apple.Notes", minutesAgo: 24)
        _ = try text("#3f7fd0", app: "Figma", bundleID: "com.figma.Desktop", minutesAgo: 47)
        _ = try add(
            [(UTI.fileURL, Data("file:///Users/you/Documents/quarterly-report.pdf".utf8))],
            app: "Finder", bundleID: "com.apple.finder", minutesAgo: 63
        )
        _ = try text("SELECT kind, COUNT(*) FROM items GROUP BY kind ORDER BY 2 DESC;",
                     app: "Terminal", bundleID: "com.apple.Terminal", minutesAgo: 95)
        _ = try text("Meeting moved to Thursday 15:00 — the room is booked under “Deck review”.",
                     app: "Slack", bundleID: "com.tinyspeck.slackmacgap", minutesAgo: 140)

        for starter in PromptLibrary.starters {
            _ = try store.createPrompt(title: starter.title, body: starter.body, now: now)
        }

        if let note { try store.setPinned(true, itemID: note.id) }
        if let code { try store.addItem(code.id, toCategory: snippets.id) }
        if let note { try store.addItem(note.id, toCategory: work.id) }
    }

    /// A small gradient PNG so the image card has something to show.
    private static func samplePNG() -> Data? {
        let size = 480
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size * 2 / 3,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let colors = [
            CGColor(red: 0.98, green: 0.55, blue: 0.32, alpha: 1),
            CGColor(red: 0.55, green: 0.29, blue: 0.87, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size, y: size * 2 / 3),
                options: []
            )
        }
        guard let image = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
