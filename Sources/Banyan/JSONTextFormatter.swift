import Foundation

enum JSONTextFormatter {
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

    /// Recognize complete containers on their own lines within command output.
    /// Scan once, respecting quoted braces, and validate before changing text.
    /// Keeping each section's language lets log/error lines remain uncolored.
    static func embeddedSections(_ text: String) -> [CodeBlockSyntaxSection]? {
        var sections: [CodeBlockSyntaxSection] = []
        var plainStart = text.startIndex
        var containerStart: String.Index?
        var closingBrackets: [Character] = []
        var inString = false
        var escaped = false

        for line in text.split(omittingEmptySubsequences: false, whereSeparator: {
            $0 == "\n" || $0 == "\r\n" || $0 == "\r"
        }) {
            if containerStart == nil {
                let first = line.first { !$0.isWhitespace }
                guard first == "{" || first == "[" else { continue }
                containerStart = line.startIndex
            }

            var complete = false
            var invalid = false
            for character in line {
                if complete {
                    if !character.isWhitespace { invalid = true; break }
                } else if inString {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inString = false
                    }
                } else {
                    switch character {
                    case "\"": inString = true
                    case "{": closingBrackets.append("}")
                    case "[": closingBrackets.append("]")
                    case "}", "]":
                        if closingBrackets.popLast() != character { invalid = true }
                        complete = closingBrackets.isEmpty
                    default: break
                    }
                    if invalid { break }
                }
            }

            // JSON strings cannot contain literal line breaks.
            invalid = invalid || inString
            if complete, !invalid, let start = containerStart,
               let formatted = prettyPrinted(String(text[start..<line.endIndex])) {
                if plainStart < start {
                    sections.append(CodeBlockSyntaxSection(text: String(text[plainStart..<start]), language: nil))
                }
                sections.append(CodeBlockSyntaxSection(text: formatted, language: .json))
                plainStart = line.endIndex
            }
            if complete || invalid {
                containerStart = nil
                closingBrackets.removeAll(keepingCapacity: true)
                inString = false
                escaped = false
            }
        }

        guard !sections.isEmpty else { return nil }
        if plainStart < text.endIndex {
            sections.append(CodeBlockSyntaxSection(text: String(text[plainStart...]), language: nil))
        }
        return sections
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
    /// escaping stay exactly as supplied.
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
