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
