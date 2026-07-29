import Foundation

/// Turns several clippings into one block of text.
///
/// The point is the labels. Pasting an error and the function that threw it as
/// two anonymous blobs makes the reader guess which is which; naming each part
/// by kind and source app is the whole reason to stack rather than paste twice.
public enum StackComposer {
    public struct Entry: Equatable, Sendable {
        public var kind: ClipKind
        public var title: String
        public var sourceAppName: String
        public var text: String
        /// Fences the block when set, e.g. "swift".
        public var language: String?

        public init(
            kind: ClipKind,
            title: String = "",
            sourceAppName: String = "",
            text: String,
            language: String? = nil
        ) {
            self.kind = kind
            self.title = title
            self.sourceAppName = sourceAppName
            self.text = text
            self.language = language
        }

        public init(item: ClipItem, text: String) {
            self.init(
                kind: item.kind,
                title: item.title,
                sourceAppName: item.sourceAppName,
                text: text,
                language: item.metadata.language
            )
        }
    }

    /// A single entry composes to its own text and nothing else — stacking one
    /// clipping has to paste exactly like choosing it would, or the stack
    /// becomes something you have to think about before using.
    public static func compose(_ entries: [Entry]) -> String {
        guard entries.count > 1 else { return entries.first?.text ?? "" }
        return entries.map(block(for:)).joined(separator: "\n\n")
    }

    private static func block(for entry: Entry) -> String {
        let body = entry.kind == .code ? fenced(entry.text, language: entry.language) : entry.text
        return "### \(heading(for: entry))\n\(body)"
    }

    private static func heading(for entry: Entry) -> String {
        var parts = [entry.kind.displayName]
        let source = entry.sourceAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty { parts.append(source) }
        return parts.joined(separator: " · ")
    }

    /// Grows the fence past any backtick run in the content, so a clipping that
    /// itself contains a code block can't break out of its own.
    private static func fenced(_ text: String, language: String?) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let tag = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(fence)\(tag)\n\(text)\n\(fence)"
    }
}
