import BanyanCore
import Foundation

/// Chooses how a tool result should be shown in the transcript. Structured
/// output gets pretty-printed where that is lossless and always carries a
/// language so the existing code-block highlighter can color it.
struct PuckToolTextPresentation: Equatable {
    let text: String
    let language: CodeBlockLanguage?
    let syntaxSections: [CodeBlockSyntaxSection]?

    var containsJSON: Bool {
        language == .json || language == .jsonl || syntaxSections != nil
    }

    var languageIdentifier: String? {
        language?.rawValue ?? (syntaxSections == nil ? nil : "JSON + Text")
    }

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
        } else if let sections = JSONTextFormatter.embeddedSections(plain) {
            self.init(text: sections.map(\.text).joined(), language: nil, syntaxSections: sections)
        } else if Self.looksLikeYAML(trimmed) {
            self.init(text: plain, language: .yaml)
        } else {
            self.init(text: plain, language: nil)
        }
    }

    private init(
        text: String,
        language: CodeBlockLanguage?,
        syntaxSections: [CodeBlockSyntaxSection]? = nil
    ) {
        self.text = text
        self.language = language
        self.syntaxSections = syntaxSections
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
