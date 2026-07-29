import Foundation

/// What a clipping fundamentally *is*, used for filtering, iconography and
/// choosing how to render a card.
public enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text
    case richText = "rich_text"
    case code
    case link
    case color
    case image
    case file
    case other

    public var displayName: String {
        switch self {
        case .text: return "Text"
        case .richText: return "Rich Text"
        case .code: return "Code"
        case .link: return "Link"
        case .color: return "Color"
        case .image: return "Image"
        case .file: return "File"
        case .other: return "Other"
        }
    }

    /// SF Symbol used on cards and in the category bar.
    public var symbolName: String {
        switch self {
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .link: return "link"
        case .color: return "paintpalette"
        case .image: return "photo"
        case .file: return "doc"
        case .other: return "questionmark.square.dashed"
        }
    }

    /// Kinds that are just "text with a flavour" — searched and previewed alike.
    public var isTextual: Bool {
        switch self {
        case .text, .richText, .code, .link, .color: return true
        case .image, .file, .other: return false
        }
    }
}
