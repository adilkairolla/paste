import CryptoKit
import Foundation

/// Turns a raw ``PasteboardSnapshot`` into a ``NewClip``: picks the kind,
/// derives title/preview/metadata, builds a thumbnail and decides which
/// representations are worth storing.
public struct ClipClassifier {
    public struct Limits: Sendable {
        /// Largest single representation we'll persist.
        public var maxRepresentationBytes: Int
        /// Largest total across all representations of one clipping.
        public var maxTotalBytes: Int
        /// Text longer than this is truncated for the search index.
        public var maxSearchTextCharacters: Int
        public var previewCharacters: Int

        public init(
            maxRepresentationBytes: Int = 64 * 1024 * 1024,
            maxTotalBytes: Int = 96 * 1024 * 1024,
            maxSearchTextCharacters: Int = 100_000,
            previewCharacters: Int = 1200
        ) {
            self.maxRepresentationBytes = maxRepresentationBytes
            self.maxTotalBytes = maxTotalBytes
            self.maxSearchTextCharacters = maxSearchTextCharacters
            self.previewCharacters = previewCharacters
        }
    }

    public var limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public func classify(_ snapshot: PasteboardSnapshot) -> NewClip? {
        guard !snapshot.isEmpty, !snapshot.shouldBeIgnored else { return nil }

        let filePaths = Self.filePaths(in: snapshot)
        let text = snapshot.plainText
        let imageRepresentation = Self.primaryImage(in: snapshot)

        // A pasteboard holding nothing but blank text (a stray double-click, a
        // trailing newline) isn't worth a card.
        if filePaths.isEmpty, imageRepresentation == nil,
           text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false {
            let meaningful: Set<String> = [UTI.rtf, UTI.rtfd, UTI.html, UTI.color]
            if snapshot.allUTIs.isDisjoint(with: meaningful) { return nil }
        }

        var metadata = ClipMetadata()
        metadata.utis = Array(snapshot.allUTIs).sorted()

        let kind: ClipKind
        var title = ""
        var preview = ""
        var searchText = ""
        var thumbnail: Data?
        var canonical = Data()

        if !filePaths.isEmpty {
            kind = .file
            let names = filePaths.map { ($0 as NSString).lastPathComponent }
            title = names.count == 1 ? names[0] : "\(names.count) files"
            preview = filePaths.joined(separator: "\n")
            searchText = (names + filePaths).joined(separator: " ")
            metadata.filePaths = filePaths
            metadata.fileCount = filePaths.count
            metadata.fileTotalBytes = Self.totalSize(ofPaths: filePaths)
            canonical = Data(filePaths.sorted().joined(separator: "\n").utf8)
        } else if let imageRepresentation {
            kind = .image
            let info = ImageInspector.inspect(imageRepresentation.data)
            metadata.pixelWidth = info?.width
            metadata.pixelHeight = info?.height
            metadata.imageFormat = info?.format
            if let info {
                title = "\(info.format.uppercased()) image · \(info.width) × \(info.height)"
            } else {
                title = "Image"
            }
            preview = ""
            searchText = "image \(info?.format ?? "") \(snapshot.sourceAppName)"
            thumbnail = ImageInspector.thumbnailPNG(from: imageRepresentation.data)
            canonical = imageRepresentation.data
        } else if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let counts = TextAnalysis.counts(for: text)
            metadata.characters = counts.characters
            metadata.words = counts.words
            metadata.lines = counts.lines
            searchText = String(text.prefix(limits.maxSearchTextCharacters))
            preview = TextAnalysis.truncate(text, to: limits.previewCharacters)
            canonical = Data(text.utf8)

            if let link = TextAnalysis.link(in: text) {
                kind = .link
                metadata.url = link.url
                metadata.host = link.host
                metadata.scheme = link.scheme
                title = link.host.map { host in
                    let path = URLComponents(string: link.url)?.path ?? ""
                    return path.isEmpty || path == "/" ? host : host + path
                } ?? TextAnalysis.title(for: text)
                title = TextAnalysis.truncate(title, to: 90)
            } else if let hex = TextAnalysis.colorHex(in: text) {
                kind = .color
                metadata.colorHex = hex
                title = hex.uppercased()
            } else if let code = TextAnalysis.code(in: text) {
                kind = .code
                metadata.language = code.language
                title = TextAnalysis.title(for: text)
            } else if snapshot.allUTIs.contains(UTI.rtf) || snapshot.allUTIs.contains(UTI.rtfd) {
                kind = .richText
                title = TextAnalysis.title(for: text)
            } else {
                kind = .text
                title = TextAnalysis.title(for: text)
            }
        } else if let colorData = snapshot.items.compactMap({ $0.data(for: UTI.color) }).first {
            kind = .color
            title = "Color"
            canonical = colorData
        } else if snapshot.allUTIs.contains(UTI.rtf) || snapshot.allUTIs.contains(UTI.html) {
            kind = .richText
            title = "Formatted text"
            canonical = snapshot.items.compactMap { $0.data(for: UTI.rtf) ?? $0.data(for: UTI.html) }.first ?? Data()
        } else {
            kind = .other
            let types = snapshot.allUTIs.sorted().joined(separator: ", ")
            title = TextAnalysis.truncate(types.isEmpty ? "Clipping" : types, to: 90)
            searchText = types
            canonical = snapshot.items.flatMap { $0.representations.map(\.data) }.reduce(into: Data()) { $0 += $1 }
        }

        if title.isEmpty { title = kind.displayName }

        let payloads = selectPayloads(from: snapshot, kind: kind)
        guard !payloads.isEmpty else { return nil }

        return NewClip(
            kind: kind,
            capturedAt: snapshot.capturedAt,
            title: title,
            preview: preview,
            searchText: searchText,
            contentHash: Self.hash(kind: kind, canonical: canonical),
            sourceBundleID: snapshot.sourceBundleID,
            sourceAppName: snapshot.sourceAppName,
            metadata: metadata,
            thumbnail: thumbnail,
            payloads: payloads
        )
    }

    // MARK: - Payload selection

    /// Keeps every representation that fits the budget, richest first, so
    /// pasting back into the originating app is byte-identical where possible.
    private func selectPayloads(
        from snapshot: PasteboardSnapshot,
        kind: ClipKind
    ) -> [(pasteboardIndex: Int, uti: String, data: Data)] {
        var candidates: [(priority: Int, pasteboardIndex: Int, order: Int, uti: String, data: Data)] = []

        for (itemIndex, item) in snapshot.items.enumerated() {
            for (order, representation) in item.representations.enumerated() {
                let uti = representation.uti
                guard !representation.data.isEmpty,
                      !UTI.skipped.contains(uti),
                      !UTI.concealed.contains(uti),
                      uti != UTI.internalMarker,
                      representation.data.count <= limits.maxRepresentationBytes
                else { continue }
                candidates.append((
                    priority: Self.priority(of: uti, kind: kind),
                    pasteboardIndex: itemIndex,
                    order: order,
                    uti: uti,
                    data: representation.data
                ))
            }
        }

        var budget = limits.maxTotalBytes
        var keep: Set<String> = []
        for candidate in candidates.sorted(by: { ($0.priority, $0.pasteboardIndex, $0.order) < ($1.priority, $1.pasteboardIndex, $1.order) }) {
            let identity = "\(candidate.pasteboardIndex)|\(candidate.uti)"
            guard candidate.data.count <= budget else { continue }
            budget -= candidate.data.count
            keep.insert(identity)
        }

        return candidates
            .filter { keep.contains("\($0.pasteboardIndex)|\($0.uti)") }
            .sorted { ($0.pasteboardIndex, $0.order) < ($1.pasteboardIndex, $1.order) }
            .map { (pasteboardIndex: $0.pasteboardIndex, uti: $0.uti, data: $0.data) }
    }

    /// Lower is kept first when the size budget runs out.
    private static func priority(of uti: String, kind: ClipKind) -> Int {
        switch kind {
        case .image:
            if uti == UTI.png { return 0 }
            if UTI.imageTypes.contains(uti) { return 1 }
            return uti == UTI.plainText ? 2 : 3
        case .file:
            if uti == UTI.fileURL || uti == UTI.legacyFilenames { return 0 }
            return uti == UTI.plainText ? 1 : 2
        default:
            if uti == UTI.plainText || uti == UTI.legacyText { return 0 }
            if uti == UTI.rtf || uti == UTI.rtfd || uti == UTI.html { return 1 }
            if uti == UTI.url || uti == UTI.urlName { return 1 }
            return 2
        }
    }

    // MARK: - Helpers

    static func hash(kind: ClipKind, canonical: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: canonical)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func primaryImage(in snapshot: PasteboardSnapshot) -> PasteboardSnapshot.Representation? {
        let preferredOrder = [UTI.png, UTI.heic, UTI.jpeg, UTI.gif, UTI.tiff, UTI.webp]
        for uti in preferredOrder {
            for item in snapshot.items {
                if let data = item.data(for: uti), !data.isEmpty {
                    return .init(uti: uti, data: data)
                }
            }
        }
        return nil
    }

    static func filePaths(in snapshot: PasteboardSnapshot) -> [String] {
        var paths: [String] = []

        for item in snapshot.items {
            if let data = item.data(for: UTI.fileURL),
               let text = String(data: data, encoding: .utf8),
               let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
               url.isFileURL {
                paths.append(url.path)
            }
        }

        if paths.isEmpty {
            for item in snapshot.items {
                guard let data = item.data(for: UTI.legacyFilenames) else { continue }
                if let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
                    paths.append(contentsOf: list)
                }
            }
        }
        return paths
    }

    static func totalSize(ofPaths paths: [String]) -> Int64 {
        let fileManager = FileManager.default
        var total: Int64 = 0
        for path in paths {
            guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { continue }
            total += (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        return total
    }
}
