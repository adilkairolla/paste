import Foundation

/// Everything we know about a clipping beyond its bytes. Stored as JSON so new
/// fields can appear without a migration.
public struct ClipMetadata: Codable, Equatable, Sendable {
    // Text-ish
    public var characters: Int?
    public var words: Int?
    public var lines: Int?
    public var language: String?

    // Link
    public var url: String?
    public var host: String?
    public var scheme: String?

    // Image
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var imageFormat: String?

    // Files
    public var filePaths: [String]?
    public var fileCount: Int?
    public var fileTotalBytes: Int64?

    // Color
    public var colorHex: String?

    /// Slot names found in a prompt's body, cached so the deck can badge a card
    /// without re-parsing the template for every frame.
    public var promptVariables: [String]?

    /// Every uniform type identifier the original pasteboard offered.
    public var utis: [String]?

    public init() {}

    public static let empty = ClipMetadata()

    public func encodedJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(json: String?) -> ClipMetadata {
        guard let json, let data = json.data(using: .utf8) else { return .empty }
        return (try? JSONDecoder().decode(ClipMetadata.self, from: data)) ?? .empty
    }

    /// Label/value pairs for the detail strip, in display order.
    public func displayPairs() -> [(String, String)] {
        var pairs: [(String, String)] = []
        if let pixelWidth, let pixelHeight { pairs.append(("Dimensions", "\(pixelWidth) × \(pixelHeight)")) }
        if let imageFormat { pairs.append(("Format", imageFormat.uppercased())) }
        if let characters { pairs.append(("Characters", characters.formatted())) }
        if let words, words > 0 { pairs.append(("Words", words.formatted())) }
        if let lines, lines > 1 { pairs.append(("Lines", lines.formatted())) }
        if let language { pairs.append(("Language", language)) }
        if let host { pairs.append(("Host", host)) }
        if let fileCount { pairs.append(("Files", fileCount.formatted())) }
        if let fileTotalBytes { pairs.append(("Total", ByteFormat.string(fileTotalBytes))) }
        if let colorHex { pairs.append(("Hex", colorHex.uppercased())) }
        if let promptVariables, !promptVariables.isEmpty {
            pairs.append(("Slots", promptVariables.joined(separator: ", ")))
        }
        return pairs
    }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 bytes" }
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let rounded = unit == 0 ? String(Int(value)) : String(format: value < 10 ? "%.1f" : "%.0f", value)
        return "\(rounded) \(units[unit])"
    }
}
