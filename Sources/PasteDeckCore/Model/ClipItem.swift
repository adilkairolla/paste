import Foundation

/// One representation of a clipping: a uniform type identifier plus its bytes.
/// Small payloads live inline in the database, large ones in the blob store, so
/// the row stays cheap to read while the deck scrolls.
public struct ClipPayload: Equatable, Sendable {
    public enum Storage: Equatable, Sendable {
        case inline(Data)
        case blob(key: String)
    }

    /// Index of the owning item on the original pasteboard (multi-item copies,
    /// e.g. several files, keep their grouping).
    public var pasteboardIndex: Int
    /// Preserves the pasteboard's own type ordering — the first type is the
    /// richest one and receivers pick from the top.
    public var order: Int
    public var uti: String
    public var byteSize: Int
    public var storage: Storage

    public init(pasteboardIndex: Int = 0, order: Int, uti: String, byteSize: Int, storage: Storage) {
        self.pasteboardIndex = pasteboardIndex
        self.order = order
        self.uti = uti
        self.byteSize = byteSize
        self.storage = storage
    }

    public var inlineData: Data? {
        if case .inline(let data) = storage { return data }
        return nil
    }

    public var blobKey: String? {
        if case .blob(let key) = storage { return key }
        return nil
    }
}

/// A clipping as it exists in the database.
public struct ClipItem: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var kind: ClipKind
    /// First time we saw this content.
    public var createdAt: Date
    /// Last time this content hit the pasteboard — the deck's sort key.
    public var updatedAt: Date
    /// Last time the user pasted it back out of PasteDeck.
    public var lastUsedAt: Date?
    public var useCount: Int
    public var isPinned: Bool
    public var title: String
    public var preview: String
    public var contentHash: String
    public var byteSize: Int64
    public var sourceBundleID: String?
    public var sourceAppName: String
    public var metadata: ClipMetadata
    public var thumbnail: Data?
    public var categoryIDs: [Int64]

    public init(
        id: Int64,
        kind: ClipKind,
        createdAt: Date,
        updatedAt: Date,
        lastUsedAt: Date? = nil,
        useCount: Int = 0,
        isPinned: Bool = false,
        title: String,
        preview: String,
        contentHash: String,
        byteSize: Int64,
        sourceBundleID: String? = nil,
        sourceAppName: String = "",
        metadata: ClipMetadata = .empty,
        thumbnail: Data? = nil,
        categoryIDs: [Int64] = []
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.isPinned = isPinned
        self.title = title
        self.preview = preview
        self.contentHash = contentHash
        self.byteSize = byteSize
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.metadata = metadata
        self.thumbnail = thumbnail
        self.categoryIDs = categoryIDs
    }
}

/// A clipping on its way *into* the database, before it has an id.
public struct NewClip: Equatable, Sendable {
    public var kind: ClipKind
    public var capturedAt: Date
    public var title: String
    public var preview: String
    public var searchText: String
    public var contentHash: String
    public var sourceBundleID: String?
    public var sourceAppName: String
    public var metadata: ClipMetadata
    public var thumbnail: Data?
    /// Raw representations, richest first.
    public var payloads: [(pasteboardIndex: Int, uti: String, data: Data)]

    public init(
        kind: ClipKind,
        capturedAt: Date = Date(),
        title: String,
        preview: String,
        searchText: String,
        contentHash: String,
        sourceBundleID: String? = nil,
        sourceAppName: String = "",
        metadata: ClipMetadata = .empty,
        thumbnail: Data? = nil,
        payloads: [(pasteboardIndex: Int, uti: String, data: Data)]
    ) {
        self.kind = kind
        self.capturedAt = capturedAt
        self.title = title
        self.preview = preview
        self.searchText = searchText
        self.contentHash = contentHash
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.metadata = metadata
        self.thumbnail = thumbnail
        self.payloads = payloads
    }

    public static func == (lhs: NewClip, rhs: NewClip) -> Bool {
        lhs.contentHash == rhs.contentHash
            && lhs.kind == rhs.kind
            && lhs.payloads.count == rhs.payloads.count
    }

    public var totalBytes: Int64 {
        payloads.reduce(0) { $0 + Int64($1.data.count) }
    }

    /// What this clipping actually costs on disk — payloads plus the cached
    /// thumbnail — so retention's byte budget doesn't undercount.
    public var storedBytes: Int64 {
        totalBytes + Int64(thumbnail?.count ?? 0)
    }
}
