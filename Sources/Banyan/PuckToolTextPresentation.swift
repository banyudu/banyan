import BanyanCore
import Foundation

/// Chooses how a tool result should be shown in the transcript. Structured
/// output gets pretty-printed where that is lossless and always carries a
/// language so the existing code-block highlighter can color it.
struct PuckToolTextPresentation: Equatable {
    let text: String
    let language: CodeBlockLanguage?

    init(text: String, explicitLanguage: String? = nil) {
        let plain = CodexConversationText.plain(text)
        let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.init(text: plain, language: CodeBlockLanguage(identifier: explicitLanguage))
            return
        }

        if let explicit = CodeBlockLanguage(identifier: explicitLanguage) {
            self = Self.formatted(text: plain, trimmed: trimmed, language: explicit)
            return
        }

        if let formatted = JSONTextFormatter.prettyPrinted(trimmed) {
            self.init(text: formatted, language: .json)
        } else if Self.looksLikeDiff(trimmed) {
            self.init(text: plain, language: .diff)
        } else if let formatted = JSONTextFormatter.prettyPrintedLines(trimmed) {
            self.init(text: formatted, language: .jsonl)
        } else if Self.looksLikeYAML(trimmed) {
            self.init(text: plain, language: .yaml)
        } else {
            self.init(text: plain, language: nil)
        }
    }

    private init(text: String, language: CodeBlockLanguage?) {
        self.text = text
        self.language = language
    }

    private static func formatted(
        text: String,
        trimmed: String,
        language: CodeBlockLanguage
    ) -> PuckToolTextPresentation {
        switch language {
        case .json:
            return PuckToolTextPresentation(
                text: JSONTextFormatter.prettyPrinted(trimmed) ?? text,
                language: .json
            )
        case .jsonl:
            return PuckToolTextPresentation(
                text: JSONTextFormatter.prettyPrintedLines(trimmed) ?? text,
                language: .jsonl
            )
        default:
            return PuckToolTextPresentation(text: text, language: language)
        }
    }

    private static func looksLikeDiff(_ text: String) -> Bool {
        text.hasPrefix("diff --git ")
            || (text.hasPrefix("--- ") && text.contains("\n+++ "))
            || text.contains("\n@@ ")
    }

    /// YAML has no formatter in the app, so only infer it when the shape is
    /// unambiguous enough not to turn ordinary command output into YAML.
    private static func looksLikeYAML(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { return false }
        if lines.first == "---" || lines.last == "..." { return true }
        guard lines.count >= 2 else { return false }

        let keyPattern = #"^(?:-\s+)?[A-Za-z_][A-Za-z0-9_-]*\s*:\s*(?:.*)$"#
        let sequencePattern = #"^-\s+\S.*$"#
        let keyRegex = try! NSRegularExpression(pattern: keyPattern)
        let sequenceRegex = try! NSRegularExpression(pattern: sequencePattern)

        var keyCount = 0
        var sequenceCount = 0
        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if keyRegex.firstMatch(in: line, range: range) != nil {
                keyCount += 1
            } else if sequenceRegex.firstMatch(in: line, range: range) != nil {
                sequenceCount += 1
            }
        }
        return keyCount >= 2 || sequenceCount >= 2 || (keyCount >= 1 && sequenceCount >= 1)
    }
}

private enum JSONTextFormatter {
    static func prettyPrinted(_ text: String) -> String? {
        guard isJSONContainer(text) else { return nil }
        return format(text)
    }

    static func prettyPrintedLines(_ text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }

        var formatted: [String] = []
        for line in lines {
            let value = String(line)
            guard isJSONContainer(value) else { return nil }
            formatted.append(format(value))
        }
        return formatted.joined(separator: "\n\n")
    }

    private static func isJSONContainer(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return object is [String: Any] || object is [Any]
    }

    /// JSONSerialization validates the input, but re-encoding it would reorder
    /// object keys. Format the original token stream instead so key order and
    /// escaping stay exactly as the tool returned them.
    private static func format(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        var depth = 0
        var inString = false
        var escaped = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index += 1
                continue
            }

            switch character {
            case "\"":
                inString = true
                output.append(character)
            case "{", "[":
                let close: Character = character == "{" ? "}" : "]"
                output.append(character)
                if nextNonWhitespace(in: characters, after: index) == close {
                    output.append(close)
                    index = nextNonWhitespaceIndex(in: characters, after: index) ?? index
                } else {
                    depth += 1
                    output.append("\n")
                    output.append(String(repeating: "  ", count: depth))
                }
            case "}", "]":
                depth = max(0, depth - 1)
                output.append("\n")
                output.append(String(repeating: "  ", count: depth))
                output.append(character)
            case ",":
                output.append(",\n")
                output.append(String(repeating: "  ", count: depth))
            case ":":
                output.append(": ")
            case " ", "\n", "\r", "\t":
                break
            default:
                output.append(character)
            }
            index += 1
        }
        return output
    }

    private static func nextNonWhitespaceIndex(in characters: [Character], after index: Int) -> Int? {
        var cursor = index + 1
        while cursor < characters.count {
            if !characters[cursor].isWhitespace { return cursor }
            cursor += 1
        }
        return nil
    }

    private static func nextNonWhitespace(in characters: [Character], after index: Int) -> Character? {
        guard let next = nextNonWhitespaceIndex(in: characters, after: index) else { return nil }
        return characters[next]
    }
}
