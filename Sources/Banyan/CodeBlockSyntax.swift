import Foundation

enum CodeBlockLanguage: String, CaseIterable, Sendable {
    case swift
    case json
    case javascript
    case typescript
    case python
    case shell
    case sql
    case yaml
    case diff
    case markup

    init?(identifier: String?) {
        guard let identifier,
              let token = identifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0.isWhitespace })
                .first else {
            return nil
        }

        var key = String(token).lowercased()
        if key.hasPrefix("{."), key.hasSuffix("}") {
            key = String(key.dropFirst(2).dropLast())
        }
        if key.hasPrefix(".") {
            key.removeFirst()
        }
        if key.hasPrefix("language-") {
            key.removeFirst("language-".count)
        }
        guard let language = Self.aliases[key] else { return nil }
        self = language
    }

    var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .json: return "JSON"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .python: return "Python"
        case .shell: return "Shell"
        case .sql: return "SQL"
        case .yaml: return "YAML"
        case .diff: return "Diff"
        case .markup: return "Markup"
        }
    }

    private static let aliases: [String: CodeBlockLanguage] = [
        "swift": .swift,
        "json": .json,
        "js": .javascript,
        "javascript": .javascript,
        "jsx": .javascript,
        "mjs": .javascript,
        "cjs": .javascript,
        "ts": .typescript,
        "typescript": .typescript,
        "tsx": .typescript,
        "py": .python,
        "python": .python,
        "python3": .python,
        "sh": .shell,
        "bash": .shell,
        "zsh": .shell,
        "shell": .shell,
        "console": .shell,
        "shellsession": .shell,
        "sql": .sql,
        "postgresql": .sql,
        "postgres": .sql,
        "mysql": .sql,
        "sqlite": .sql,
        "yml": .yaml,
        "yaml": .yaml,
        "diff": .diff,
        "patch": .diff,
        "html": .markup,
        "htm": .markup,
        "xml": .markup,
        "svg": .markup,
        "markup": .markup
    ]
}

enum SyntaxHighlightKind: Equatable, Sendable {
    case keyword
    case string
    case comment
    case number
    case literal
    case attribute
    case key
    case tag
    case added
    case removed
    case hunk
}

struct SyntaxHighlightSpan: Equatable, Sendable {
    let text: String
    let kind: SyntaxHighlightKind?

    init(_ text: String, kind: SyntaxHighlightKind? = nil) {
        self.text = text
        self.kind = kind
    }
}

enum CodeBlockHighlightPolicy {
    static let maximumCharacters = 40_000
    static let maximumLines = 2_000
    static let cacheEntries = 64
    static let previewCharacterThreshold = 900
    static let previewLineThreshold = 12

    static func canHighlight(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= maximumCharacters else { return false }
        var lines = 1
        for character in text where character == "\n" {
            lines += 1
            if lines > maximumLines { return false }
        }
        return true
    }

    static func needsExpansion(_ text: String) -> Bool {
        if text.count > previewCharacterThreshold { return true }
        var lines = 1
        for character in text where character == "\n" {
            lines += 1
            if lines > previewLineThreshold { return true }
        }
        return false
    }
}

enum CodeBlockSyntaxHighlighter {
    static func highlight(_ text: String, languageIdentifier: String?) -> [SyntaxHighlightSpan]? {
        guard let language = CodeBlockLanguage(identifier: languageIdentifier) else { return nil }
        return highlight(text, language: language)
    }

    static func highlight(_ text: String, language: CodeBlockLanguage) -> [SyntaxHighlightSpan]? {
        guard CodeBlockHighlightPolicy.canHighlight(text) else { return nil }
        if language == .diff { return diffSpans(text) }
        return lexicalSpans(text, rules: rules[language] ?? [])
    }

    private struct Rule {
        let regex: NSRegularExpression
        let kind: SyntaxHighlightKind
        let priority: Int
        let captureGroup: Int
    }

    private struct Candidate {
        let range: NSRange
        let kind: SyntaxHighlightKind
        let priority: Int
    }

    private static func rule(
        _ pattern: String,
        _ kind: SyntaxHighlightKind,
        priority: Int = 0,
        captureGroup: Int = 0
    ) -> Rule {
        Rule(
            regex: try! NSRegularExpression(pattern: pattern),
            kind: kind,
            priority: priority,
            captureGroup: captureGroup
        )
    }

    private static func words(_ values: [String]) -> String {
        #"(?<![A-Za-z0-9_])(?:"# + values.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")(?![A-Za-z0-9_])"#
    }

    private static let stringPattern = #""(?:\\.|[^"\\])*""#
    private static let singleQuotedStringPattern = #"'(?:\\.|[^'\\])*'"#
    private static let backtickStringPattern = #"`(?:\\.|[^`\\])*`"#
    private static let numberPattern = #"(?<![A-Za-z0-9_])(?:0[xX][0-9A-Fa-f_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)(?![A-Za-z0-9_])"#
    private static let slashCommentPattern = #"//[^\n]*"#
    private static let sqlCommentPattern = #"--[^\n]*|/\*[\s\S]*?\*/"#
    private static let blockCommentPattern = #"/\*[\s\S]*?\*/"#
    private static let hashCommentPattern = #"#[^\n]*"#

    private static let rules: [CodeBlockLanguage: [Rule]] = [
        .json: [
            rule(#""(?:\\.|[^"\\])*"(?=\s*:)"#, .key, priority: 95),
            rule(stringPattern, .string, priority: 90),
            rule(numberPattern, .number, priority: 80),
            rule(words(["true", "false", "null"]), .literal, priority: 75)
        ],
        .swift: [
            rule(slashCommentPattern, .comment, priority: 100),
            rule(blockCommentPattern, .comment, priority: 100),
            rule(stringPattern, .string, priority: 90),
            rule(#"@[A-Za-z_][A-Za-z0-9_]*"#, .attribute, priority: 85),
            rule(numberPattern, .number, priority: 80),
            rule(words(["true", "false", "nil"]), .literal, priority: 75),
            rule(words([
                "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func",
                "import", "init", "inout", "internal", "let", "open", "operator", "private",
                "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias",
                "var", "break", "case", "continue", "default", "defer", "do", "else",
                "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where",
                "while", "as", "catch", "is", "super", "self", "Self", "throw", "throws", "try",
                "actor", "any", "async", "await", "some", "macro", "nonisolated", "isolated"
            ]), .keyword, priority: 70)
        ],
        .javascript: [
            rule(slashCommentPattern, .comment, priority: 100),
            rule(blockCommentPattern, .comment, priority: 100),
            rule(stringPattern, .string, priority: 90),
            rule(singleQuotedStringPattern, .string, priority: 90),
            rule(backtickStringPattern, .string, priority: 90),
            rule(numberPattern, .number, priority: 80),
            rule(words(["true", "false", "null", "undefined", "NaN", "Infinity"]), .literal, priority: 75),
            rule(words([
                "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
                "debugger", "declare", "default", "delete", "do", "else", "enum", "export",
                "extends", "finally", "for", "from", "function", "get", "if", "implements", "import",
                "in", "instanceof", "interface", "keyof", "let", "namespace", "new", "of", "private",
                "protected", "public", "readonly", "return", "set", "static", "super", "switch",
                "this", "throw", "try", "type", "typeof", "var", "void", "while", "with", "yield"
            ]), .keyword, priority: 70)
        ],
        .typescript: [
            rule(slashCommentPattern, .comment, priority: 100),
            rule(blockCommentPattern, .comment, priority: 100),
            rule(stringPattern, .string, priority: 90),
            rule(singleQuotedStringPattern, .string, priority: 90),
            rule(backtickStringPattern, .string, priority: 90),
            rule(numberPattern, .number, priority: 80),
            rule(words(["true", "false", "null", "undefined", "NaN", "Infinity"]), .literal, priority: 75),
            rule(words([
                "any", "as", "async", "await", "bigint", "boolean", "break", "case", "catch",
                "class", "const", "continue", "declare", "default", "delete", "do", "else", "enum",
                "export", "extends", "finally", "for", "from", "function", "get", "if", "implements",
                "import", "in", "interface", "keyof", "let", "namespace", "never", "new", "number",
                "object", "of", "private", "protected", "public", "readonly", "return", "set",
                "static", "string", "super", "switch", "symbol", "this", "throw", "try", "type",
                "typeof", "unknown", "var", "void", "while", "with", "yield"
            ]), .keyword, priority: 70)
        ],
        .python: [
            rule(hashCommentPattern, .comment, priority: 100),
            rule(stringPattern, .string, priority: 90),
            rule(singleQuotedStringPattern, .string, priority: 90),
            rule(#"@[A-Za-z_][A-Za-z0-9_.]*"#, .attribute, priority: 85),
            rule(numberPattern, .number, priority: 80),
            rule(words(["True", "False", "None"]), .literal, priority: 75),
            rule(words([
                "and", "as", "assert", "async", "await", "break", "case", "class", "continue",
                "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if",
                "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise",
                "return", "try", "while", "with", "yield"
            ]), .keyword, priority: 70)
        ],
        .shell: [
            rule(hashCommentPattern, .comment, priority: 100),
            rule(stringPattern, .string, priority: 90),
            rule(singleQuotedStringPattern, .string, priority: 90),
            rule(backtickStringPattern, .string, priority: 90),
            rule(#"\$[A-Za-z_][A-Za-z0-9_]*"#, .attribute, priority: 85),
            rule(numberPattern, .number, priority: 80),
            rule(words(["true", "false"]), .literal, priority: 75),
            rule(words([
                "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in",
                "select", "then", "until", "while", "break", "continue", "return", "export", "local",
                "readonly", "declare", "unset", "shift", "source"
            ]), .keyword, priority: 70)
        ],
        .sql: [
            rule(sqlCommentPattern, .comment, priority: 100),
            rule(stringPattern, .string, priority: 90),
            rule(singleQuotedStringPattern, .string, priority: 90),
            rule(numberPattern, .number, priority: 80),
            rule(words(["true", "false", "null"]), .literal, priority: 75),
            rule("(?i)" + words([
                "add", "all", "alter", "and", "as", "asc", "begin", "between", "by", "case", "check",
                "column", "commit", "constraint", "create", "cross", "database", "default", "delete",
                "desc", "distinct", "drop", "else", "end", "except", "exists", "foreign", "from",
                "full", "group", "having", "in", "index", "inner", "insert", "intersect", "into",
                "is", "join", "key", "left", "like", "limit", "not", "null", "offset", "on", "or",
                "order", "outer", "primary", "references", "right", "rollback", "select", "set",
                "table", "then", "true", "union", "unique", "update", "values", "view", "when",
                "where", "with"
            ]), .keyword, priority: 70)
        ],
        .yaml: [
            rule(hashCommentPattern, .comment, priority: 100),
            rule(#"(?m)^[ \t-]*([^#:\n][^:\n]*):(?=\s|$)"#, .key, priority: 95, captureGroup: 1),
            rule(stringPattern, .string, priority: 90),
            rule(singleQuotedStringPattern, .string, priority: 90),
            rule(numberPattern, .number, priority: 80),
            rule(words(["true", "false", "null", "yes", "no", "on", "off"]), .literal, priority: 75)
        ],
        .markup: [
            rule(#"<!--[\s\S]*?-->"#, .comment, priority: 100),
            rule(#"<[^>\n]*>"#, .tag, priority: 90)
        ]
    ]

    private static func lexicalSpans(_ text: String, rules: [Rule]) -> [SyntaxHighlightSpan] {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        var candidates: [Candidate] = []
        for rule in rules {
            for match in rule.regex.matches(in: text, range: fullRange) {
                let range = match.range(at: rule.captureGroup)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                candidates.append(Candidate(range: range, kind: rule.kind, priority: rule.priority))
            }
        }
        candidates.sort {
            if $0.range.location == $1.range.location { return $0.priority > $1.priority }
            return $0.range.location < $1.range.location
        }

        let text = text as NSString
        var spans: [SyntaxHighlightSpan] = []
        var cursor = 0
        for candidate in candidates where candidate.range.location >= cursor {
            if cursor < candidate.range.location {
                spans.append(SyntaxHighlightSpan(text.substring(with: NSRange(
                    location: cursor,
                    length: candidate.range.location - cursor
                ))))
            }
            spans.append(SyntaxHighlightSpan(text.substring(with: candidate.range), kind: candidate.kind))
            cursor = NSMaxRange(candidate.range)
        }
        if cursor < text.length {
            spans.append(SyntaxHighlightSpan(text.substring(from: cursor)))
        }
        return spans
    }

    private static func diffSpans(_ text: String) -> [SyntaxHighlightSpan] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.enumerated().map { index, line in
            let value = String(line) + (index < lines.count - 1 ? "\n" : "")
            let kind: SyntaxHighlightKind?
            if line.hasPrefix("@@") {
                kind = .hunk
            } else if line.hasPrefix("+++") || line.hasPrefix("---") {
                kind = .key
            } else if line.hasPrefix("+") {
                kind = .added
            } else if line.hasPrefix("-") {
                kind = .removed
            } else if line.hasPrefix("diff ") || line.hasPrefix("index ") {
                kind = .key
            } else {
                kind = nil
            }
            return SyntaxHighlightSpan(value, kind: kind)
        }
    }
}
