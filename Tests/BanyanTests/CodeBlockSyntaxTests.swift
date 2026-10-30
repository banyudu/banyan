import Testing
@testable import Banyan

@Test func codeBlockLanguagesNormalizeCommonAliases() {
    #expect(CodeBlockLanguage(identifier: "swift") == .swift)
    #expect(CodeBlockLanguage(identifier: "Swift linenums") == .swift)
    #expect(CodeBlockLanguage(identifier: "js") == .javascript)
    #expect(CodeBlockLanguage(identifier: "tsx") == .typescript)
    #expect(CodeBlockLanguage(identifier: "python3") == .python)
    #expect(CodeBlockLanguage(identifier: "shellsession") == .shell)
    #expect(CodeBlockLanguage(identifier: "postgresql") == .sql)
    #expect(CodeBlockLanguage(identifier: "{.yml}") == .yaml)
    #expect(CodeBlockLanguage(identifier: ".patch") == .diff)
    #expect(CodeBlockLanguage(identifier: "language-html") == .markup)
}

@Test func codeBlockLanguagesRejectMissingAndUnknownIdentifiers() {
    #expect(CodeBlockLanguage(identifier: nil) == nil)
    #expect(CodeBlockLanguage(identifier: "   ") == nil)
    #expect(CodeBlockLanguage(identifier: "brainfuck") == nil)
    #expect(CodeBlockSyntaxHighlighter.highlight("plain text", languageIdentifier: nil) == nil)
    #expect(CodeBlockSyntaxHighlighter.highlight("plain text", languageIdentifier: "brainfuck") == nil)
}

@Test func syntaxHighlighterProducesSemanticSpansWithoutDroppingText() throws {
    let samples: [(String, String)] = [
        ("swift", "let answer = 42 // note\nprint(\"ok\")"),
        ("json", #"{"name": "banyan", "ready": true, "count": 3}"#),
        ("python", "def run(value):\n    return value + 1  # note"),
        ("shell", "for file in *.swift; do\n  echo \"$file\"\ndone"),
        ("sql", "SELECT id, name FROM sessions WHERE active = true;"),
        ("yaml", "name: banyan\nenabled: true\ncount: 3 # note"),
        ("diff", "diff --git a/a.swift b/a.swift\n@@ -1 +1 @@\n-let old = true\n+let new = true"),
        ("html", "<section class=\"card\">Hello</section>")
    ]

    for (language, sample) in samples {
        let spans = try #require(CodeBlockSyntaxHighlighter.highlight(sample, languageIdentifier: language))
        #expect(spans.map(\.text).joined() == sample)
        #expect(spans.contains { $0.kind != nil })
    }
}

@Test func syntaxHighlighterIdentifiesKeywordsStringsCommentsKeysAndLiterals() throws {
    let swiftSpans = try #require(CodeBlockSyntaxHighlighter.highlight(
        "let answer = \"forty-two\" // note",
        languageIdentifier: "swift"
    ))
    #expect(swiftSpans.contains { $0.text == "let" && $0.kind == .keyword })
    #expect(swiftSpans.contains { $0.text == "\"forty-two\"" && $0.kind == .string })
    #expect(swiftSpans.contains { $0.text == "// note" && $0.kind == .comment })

    let jsonSpans = try #require(CodeBlockSyntaxHighlighter.highlight(
        #"{"name": true, "count": 3}"#,
        languageIdentifier: "json"
    ))
    #expect(jsonSpans.contains { $0.text == "\"name\"" && $0.kind == .key })
    #expect(jsonSpans.contains { $0.text == "true" && $0.kind == .literal })
    #expect(jsonSpans.contains { $0.text == "3" && $0.kind == .number })
}

@Test func syntaxHighlighterSkipsOversizedInput() {
    let oversized = String(repeating: "a", count: CodeBlockHighlightPolicy.maximumCharacters + 1)
    #expect(!CodeBlockHighlightPolicy.canHighlight(oversized))
    #expect(CodeBlockSyntaxHighlighter.highlight(oversized, languageIdentifier: "swift") == nil)
}

@Test func previewExpansionPolicyBoundsShortContent() {
    #expect(!CodeBlockHighlightPolicy.needsExpansion("let value = 1"))
    #expect(!CodeBlockHighlightPolicy.needsExpansion(Array(repeating: "line", count: 12).joined(separator: "\n")))
    #expect(CodeBlockHighlightPolicy.needsExpansion(Array(repeating: "line", count: 13).joined(separator: "\n")))
    #expect(CodeBlockHighlightPolicy.needsExpansion(String(
        repeating: "a",
        count: CodeBlockHighlightPolicy.previewCharacterThreshold + 1
    )))
}

@Test func markdownParserPreservesFenceLanguageMetadata() {
    let markdown = """
    Before

    ```swift linenums
    let value = 1
    ```

    ~~~json
    {"ok": true}
    ~~~

    ```
    plain text
    ```

    ```not-a-language
    raw output
    ```
    """

    let blocks = MarkdownBlockParser.codeBlocks(in: markdown)
    #expect(blocks.count == 4)
    #expect(blocks[0].language == "swift linenums")
    #expect(blocks[0].text == "let value = 1")
    #expect(blocks[1].language == "json")
    #expect(blocks[1].text == #"{"ok": true}"#)
    #expect(blocks[2].language == nil)
    #expect(blocks[2].text == "plain text")
    #expect(blocks[3].language == "not-a-language")
    #expect(blocks[3].text == "raw output")
}
