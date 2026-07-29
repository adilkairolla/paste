import Foundation

/// A reusable piece of text with `{{placeholder}}` slots.
///
/// Parsing and rendering share one tokenizer, so what the fill sheet asks for
/// and what the paste substitutes can never drift apart. Anything between
/// braces that isn't a well-formed name is left exactly as written — a template
/// containing `{{ 2 + 2 }}` pastes that literally instead of silently vanishing.
public struct PromptTemplate: Equatable, Sendable {
    /// One slot to fill. `builtIn` slots are filled by PasteDeck itself and are
    /// never shown as empty text fields.
    public struct Variable: Equatable, Sendable, Identifiable {
        public var name: String
        public var builtIn: BuiltIn?

        public var id: String { name }
        public var isBuiltIn: Bool { builtIn != nil }

        /// "target audience" → "Target audience".
        public var displayName: String {
            guard let first = name.first else { return name }
            return first.uppercased() + name.dropFirst()
        }
    }

    /// Slots PasteDeck knows how to fill without asking.
    public enum BuiltIn: String, CaseIterable, Equatable, Sendable {
        /// Whatever is on the pasteboard right now.
        case clipboard
        /// Every clipping currently in the stack, composed.
        case stack

        public var explanation: String {
            switch self {
            case .clipboard: return "what's on the clipboard right now"
            case .stack: return "everything in the stack"
            }
        }
    }

    public let body: String
    /// In order of first appearance, deduplicated.
    public let variables: [Variable]

    public init(body: String) {
        self.body = body
        var seen = Set<String>()
        var found: [Variable] = []
        for token in Self.tokenize(body) {
            guard case .variable(let name) = token, seen.insert(name).inserted else { continue }
            found.append(Variable(name: name, builtIn: BuiltIn(rawValue: name.lowercased())))
        }
        variables = found
    }

    public var hasVariables: Bool { !variables.isEmpty }

    /// Slots the user has to type something into.
    public var userVariables: [Variable] { variables.filter { !$0.isBuiltIn } }

    /// Substitutes every known slot. Values are looked up by normalized name;
    /// a slot with no value collapses to nothing, because leaving `{{topic}}`
    /// sitting in the pasted text is never what anyone wanted.
    public func rendered(with values: [String: String]) -> String {
        var normalized: [String: String] = [:]
        for (key, value) in values {
            normalized[Self.normalize(key)] = value
        }

        var output = ""
        for token in Self.tokenize(body) {
            switch token {
            case .literal(let text):
                output += text
            case .variable(let name):
                output += normalized[name] ?? ""
            }
        }
        return output
    }

    /// One run of the body, for drawing slots in a different colour from the
    /// text around them. Rebuilding the body from these is lossless.
    public enum Segment: Equatable, Sendable {
        case literal(String)
        case slot(String)
    }

    public var segments: [Segment] {
        Self.tokenize(body).map { token in
            switch token {
            case .literal(let text): return .literal(text)
            case .variable(let name): return .slot(name)
            }
        }
    }

    // MARK: - Tokenizing

    enum Token: Equatable {
        case literal(String)
        case variable(String)
    }

    /// Names may hold letters, digits, spaces, `_` and `-`. Anything else means
    /// the braces weren't a placeholder at all.
    private static let allowedExtras = Set(" _-")

    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private static func isValidName(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return false }
        return trimmed.allSatisfy { $0.isLetter || $0.isNumber || allowedExtras.contains($0) }
    }

    static func tokenize(_ body: String) -> [Token] {
        var tokens: [Token] = []
        var literal = ""
        var index = body.startIndex

        func flush() {
            guard !literal.isEmpty else { return }
            tokens.append(.literal(literal))
            literal = ""
        }

        while index < body.endIndex {
            guard body[index] == "{",
                  let afterOpen = body.index(index, offsetBy: 2, limitedBy: body.endIndex),
                  body[body.index(after: index)] == "{",
                  // An unterminated `{{` is literal text, not a broken slot.
                  let closeStart = body.range(of: "}}", range: afterOpen..<body.endIndex)
            else {
                literal.append(body[index])
                index = body.index(after: index)
                continue
            }

            let inner = String(body[afterOpen..<closeStart.lowerBound])
            guard isValidName(inner) else {
                literal.append(body[index])
                index = body.index(after: index)
                continue
            }

            flush()
            tokens.append(.variable(normalize(inner)))
            index = closeStart.upperBound
        }

        flush()
        return tokens
    }
}
