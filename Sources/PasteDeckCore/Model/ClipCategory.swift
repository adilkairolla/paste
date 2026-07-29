import Foundation

/// A user-created, persistent bucket. Items filed into one are never pruned.
public struct ClipCategory: Identifiable, Equatable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var symbolName: String
    public var colorName: String
    public var sortOrder: Int
    public var createdAt: Date
    /// Populated by list queries for the badge in the category bar.
    public var itemCount: Int

    public init(
        id: Int64,
        name: String,
        symbolName: String = "folder",
        colorName: String = "blue",
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        itemCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.colorName = colorName
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.itemCount = itemCount
    }

    /// Colours offered when creating a category, resolved to SwiftUI colours in the UI layer.
    public static let paletteNames = ["blue", "purple", "pink", "red", "orange", "yellow", "green", "teal", "gray"]

    public static let symbolChoices = [
        "folder", "star", "bookmark", "tag", "tray.full", "briefcase",
        "hammer", "lightbulb", "heart", "flag", "paperclip", "square.stack",
    ]
}

/// What the deck is currently showing. Smart cases are computed filters over
/// the whole history; ``category`` is a stored membership list.
public enum ClipFilter: Equatable, Hashable, Sendable {
    case all
    case pinned
    case kinds(Set<ClipKind>)
    case category(Int64)
    /// The prompt library. Kept as its own case rather than `.kinds([.prompt])`
    /// because every other view deliberately hides prompts, and one named case
    /// is easier to keep honest than a set that must never appear elsewhere.
    case prompts

    public static let text = ClipFilter.kinds([.text, .richText])
    public static let links = ClipFilter.kinds([.link])
    public static let images = ClipFilter.kinds([.image])
    public static let files = ClipFilter.kinds([.file])
    public static let code = ClipFilter.kinds([.code])
    public static let colors = ClipFilter.kinds([.color])
}

/// One tab in the category bar: either a smart filter or a user category.
public struct FilterTab: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var symbolName: String
    public var colorName: String
    public var filter: ClipFilter
    public var isUserCategory: Bool
    public var categoryID: Int64?

    public init(
        id: String,
        title: String,
        symbolName: String,
        colorName: String = "gray",
        filter: ClipFilter,
        isUserCategory: Bool = false,
        categoryID: Int64? = nil
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.colorName = colorName
        self.filter = filter
        self.isUserCategory = isUserCategory
        self.categoryID = categoryID
    }

    public static let smartTabs: [FilterTab] = [
        FilterTab(id: "all", title: "All", symbolName: "square.grid.2x2", filter: .all),
        FilterTab(id: "prompts", title: "Prompts", symbolName: "sparkles", colorName: "indigo", filter: .prompts),
        FilterTab(id: "pinned", title: "Pinned", symbolName: "pin", colorName: "orange", filter: .pinned),
        FilterTab(id: "text", title: "Text", symbolName: "text.alignleft", filter: .text),
        FilterTab(id: "links", title: "Links", symbolName: "link", colorName: "blue", filter: .links),
        FilterTab(id: "images", title: "Images", symbolName: "photo", colorName: "purple", filter: .images),
        FilterTab(id: "files", title: "Files", symbolName: "doc", colorName: "teal", filter: .files),
        FilterTab(id: "code", title: "Code", symbolName: "chevron.left.forwardslash.chevron.right", colorName: "green", filter: .code),
        FilterTab(id: "colors", title: "Colors", symbolName: "paintpalette", colorName: "pink", filter: .colors),
    ]

    public static func tab(for category: ClipCategory) -> FilterTab {
        FilterTab(
            id: "category-\(category.id)",
            title: category.name,
            symbolName: category.symbolName,
            colorName: category.colorName,
            filter: .category(category.id),
            isUserCategory: true,
            categoryID: category.id
        )
    }
}
