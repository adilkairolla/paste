import Foundation

/// Heuristics that decide whether a chunk of text is a link, a colour, source
/// code or just prose — and summarise it for the card.
public enum TextAnalysis {
    // MARK: Links

    public struct LinkInfo: Equatable, Sendable {
        public var url: String
        public var scheme: String
        public var host: String?
    }

    /// A whole-string URL. Deliberately strict: text that merely *contains* a
    /// link is still text.
    public static func link(in text: String) -> LinkInfo? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2048 else { return nil }
        guard !trimmed.contains(where: { $0.isNewline || $0 == " " }) else { return nil }

        if let components = URLComponents(string: trimmed),
           let scheme = components.scheme?.lowercased(),
           !scheme.isEmpty {
            let hasHost = !(components.host ?? "").isEmpty
            let opaqueSchemes: Set<String> = ["mailto", "tel", "sms", "facetime"]
            if hasHost || opaqueSchemes.contains(scheme) {
                return LinkInfo(url: trimmed, scheme: scheme, host: components.host)
            }
        }

        // Bare hosts like "example.com/path" — accept only obvious web shapes.
        if trimmed.range(of: #"^(www\.)?[a-z0-9-]+(\.[a-z0-9-]+)+(/\S*)?$"#,
                         options: [.regularExpression, .caseInsensitive]) != nil,
           let components = URLComponents(string: "https://" + trimmed) {
            return LinkInfo(url: trimmed, scheme: "https", host: components.host)
        }
        return nil
    }

    // MARK: Colours

    /// `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb(…)` and `rgba(…)`.
    public static func colorHex(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 32 else { return nil }

        if trimmed.range(of: #"^#([0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$"#,
                         options: [.regularExpression, .caseInsensitive]) != nil {
            return trimmed.lowercased()
        }

        let functional = #"^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(,\s*[\d.]+\s*)?\)$"#
        guard let match = trimmed.range(of: functional, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let numbers = trimmed[match]
            .components(separatedBy: CharacterSet(charactersIn: "(),"))
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count >= 3, numbers.prefix(3).allSatisfy({ (0...255).contains($0) }) else { return nil }
        return String(format: "#%02x%02x%02x", numbers[0], numbers[1], numbers[2])
    }

    // MARK: Code

    private static let codeKeywords: [(language: String, tokens: [String])] = [
        ("Swift", ["func ", "guard let ", "if let ", "@State", "var body:", "struct ", "extension ", "-> "]),
        ("Python", ["def ", "elif ", "import ", "self.", "__init__", "print("]),
        ("JavaScript", ["function ", "const ", "=> ", "console.log", "require(", "export default", "async "]),
        ("Rust", ["fn ", "let mut ", "impl ", "pub fn", "::<", "match "]),
        ("Go", ["func ", ":= ", "package main", "import (", "err != nil"]),
        ("Java", ["public class", "private ", "void ", "@Override", "System.out"]),
        ("C", ["#include", "int main", "printf(", "malloc(", "typedef struct"]),
        ("Ruby", ["def ", "end\n", "puts ", "require '", "do |"]),
        ("PHP", ["<?php", "$this->", "echo ", "function "]),
        ("SQL", ["SELECT ", "INSERT INTO", "UPDATE ", "CREATE TABLE", "JOIN ", "WHERE "]),
        ("Shell", ["#!/bin/", "sudo ", "&& ", "cd ", "export ", "grep "]),
        ("HTML", ["<div", "<span", "</html>", "<!DOCTYPE", "<body"]),
        ("CSS", ["margin:", "padding:", "display: flex", "@media", "border-radius:"]),
    ]

    public struct CodeInfo: Equatable, Sendable {
        public var language: String?
        public var confidence: Int
    }

    /// Scores a few independent signals; two or more is enough to call it code.
    public static func code(in text: String) -> CodeInfo? {
        guard text.count >= 12 else { return nil }
        let sample = String(text.prefix(4000))

        if let json = jsonLanguage(for: sample) {
            return CodeInfo(language: json, confidence: 4)
        }

        var score = 0
        var language: String?

        var bestHits = 0
        for entry in codeKeywords {
            let hits = entry.tokens.reduce(0) { $0 + (sample.contains($1) ? 1 : 0) }
            if hits > bestHits {
                bestHits = hits
                language = entry.language
            }
        }
        if bestHits >= 2 { score += 2 } else if bestHits == 1 { score += 1 }

        let lines = sample.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1 {
            let indented = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count
            if Double(indented) / Double(lines.count) > 0.25 { score += 1 }

            let terminated = lines.filter {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return trimmed.hasSuffix(";") || trimmed.hasSuffix("{") || trimmed.hasSuffix("}")
            }.count
            if Double(terminated) / Double(lines.count) > 0.25 { score += 1 }
        }

        let symbols = sample.filter { "{}()[];=<>_/#$".contains($0) }.count
        if Double(symbols) / Double(sample.count) > 0.06 { score += 1 }

        guard score >= 2 else { return nil }
        return CodeInfo(language: bestHits >= 1 ? language : nil, confidence: score)
    }

    private static func jsonLanguage(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")),
              let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
        else { return nil }
        return "JSON"
    }

    // MARK: Summaries

    public static func counts(for text: String) -> (characters: Int, words: Int, lines: Int) {
        let characters = text.count
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        return (characters, words, lines)
    }

    /// First meaningful line, collapsed and truncated — used as the card title.
    public static func title(for text: String, limit: Int = 90) -> String {
        let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ?? Substring(text.prefix(limit))
        let collapsed = firstLine
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return truncate(collapsed, to: limit)
    }

    public static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
