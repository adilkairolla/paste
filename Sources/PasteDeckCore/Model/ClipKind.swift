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
    /// A reusable template the user wrote, not something they copied.
    case prompt
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
        case .prompt: return "Prompt"
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
        case .prompt: return "sparkles"
        case .other: return "questionmark.square.dashed"
        }
    }

    /// Kinds that are just "text with a flavour" — searched and previewed alike.
    public var isTextual: Bool {
        switch self {
        case .text, .richText, .code, .link, .color, .prompt: return true
        case .image, .file, .other: return false
        }
    }

    /// Whether a clipping of this kind can contribute to a composed stack.
    ///
    /// Images have no text to contribute, and a placeholder line in the middle
    /// of a paste is worse than refusing outright. Prompts are excluded for a
    /// different reason: a prompt is the thing a stack gets poured *into*, so
    /// stacking one inverts the relationship.
    public var isStackable: Bool {
        switch self {
        case .text, .richText, .code, .link, .color, .file: return true
        case .image, .prompt, .other: return false
        }
    }

    /// Authored by the user rather than captured from the pasteboard. Library
    /// kinds are kept out of history views and exempt from pruning.
    public var isLibrary: Bool { self == .prompt }
}
