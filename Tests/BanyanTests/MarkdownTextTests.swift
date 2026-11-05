import Testing
@testable import Banyan

@Test func markdownParserRecognizesPipeTables() {
    let markdown = """
    Recent events
    | observedAt | severity | detail |
    | -- | :--: | --: |
    | 2026-07-17 | critical | **failure** |
    """

    #expect(MarkdownBlockParser.containsTable(in: markdown))
}

@Test func markdownParserRecognizesEng8117Table() {
    let markdown = """
    ### Recent events

    | observedAt | severity | detail | request IDs | archive refs |
    | -- | -- | -- | -- | -- |
    | 2026-07-17T05:25:36.569Z | critical | email pipeline terminal failures=2 | *none* | *none* |
    """

    #expect(MarkdownBlockParser.containsTable(in: markdown))
}

@Test func markdownParserKeepsPipesInsideTableCells() {
    let markdown = """
    | Query | Result |
    | --- | --- |
    | `a\\|b` | ok |
    """

    #expect(MarkdownBlockParser.containsTable(in: markdown))
}

@Test func markdownParserRecognizesBlockquotesAndHorizontalRules() {
    let markdown = """
    > Some paths are best explored slowly.

    ---
    """

    #expect(MarkdownBlockParser.containsBlockquote(in: markdown))
    #expect(MarkdownBlockParser.containsHorizontalRule(in: markdown))
}

@Test func markdownParserSeparatesTaggedJSONKindAndFormatsOnlyThePayload() throws {
    let envelope = """
    [[investigation-result]]
    {"verdict":"needs_more_evidence","confidence":0.91,"summary":"尚无共同根因 🐳","root_cause":null,"ready":false,"acceptance":[]}
    [[/investigation-result]]
    """
    let markdown = "Before the result\n" + envelope + "\nAfter the result"
    let blocks = MarkdownBlockParser.codeBlocks(in: markdown)

    #expect(blocks.count == 1)
    let block = try #require(blocks.first)
    #expect(block.kind == "investigation-result")
    #expect(block.language == "json")
    #expect(block.originalText == envelope)
    #expect(block.text == """
    {
      "verdict": "needs_more_evidence",
      "confidence": 0.91,
      "summary": "尚无共同根因 🐳",
      "root_cause": null,
      "ready": false,
      "acceptance": []
    }
    """)
    let spans = try #require(CodeBlockSyntaxHighlighter.highlight(block.text, languageIdentifier: block.language))
    #expect(spans.map(\.text).joined() == block.text)
    #expect(spans.contains { $0.text == "\"verdict\"" && $0.kind == .key })
    #expect(spans.contains { $0.text == "\"尚无共同根因 🐳\"" && $0.kind == .string })
    #expect(spans.contains { $0.text == "0.91" && $0.kind == .number })
    #expect(spans.contains { $0.text == "null" && $0.kind == .literal })
}

@Test func markdownParserRecognizesMultipleTaggedContainersAfterAList() throws {
    let object = """
      [[result_v2]]
      {
        "message": "**literal** and \\n escaped text"
      }
      [[/result_v2]]
    """
    let array = """
    [[records.v1]]
    [{"ok":true}, {"ok":false}]
    [[/records.v1]]
    """
    let blocks = MarkdownBlockParser.codeBlocks(in: "- Findings\n" + object + "\n" + array)

    try #require(blocks.count == 2)
    #expect(blocks.map(\.kind) == ["result_v2", "records.v1"])
    #expect(blocks.map(\.originalText) == [object, array])
    #expect(blocks[0].text == """
    {
      "message": "**literal** and \\n escaped text"
    }
    """)
    #expect(blocks[1].text == """
    [
      {
        "ok": true
      },
      {
        "ok": false
      }
    ]
    """)
}

@Test func markdownParserLeavesIncompleteOrNonJSONEnvelopesAsText() {
    let samples = [
        "[[result]]\n{\"ok\":true}",
        "[[result]]\n{\"ok\":true}\n[[/other]]",
        "[[result]]\n{\"ok\":}\n[[/result]]",
        "[[result]]\nordinary text\n[[/result]]",
        "[[result]]\ntrue\n[[/result]]",
        "[[result]]\n[[nested]]\n{}\n[[/result]]",
        "See [[result]]\n{}\n[[/result]]",
        "[[wiki link]]\n{}\n[[/wiki link]]",
        "[[result]]",
    ]
    for sample in samples {
        #expect(MarkdownBlockParser.codeBlocks(in: sample).isEmpty)
    }
}

@Test func markdownParserKeepsTaggedExamplesInsideTheirExplicitFence() {
    let envelope = "[[result]]\n{\"ok\":true}\n[[/result]]"
    let markdown = "```text\n" + envelope + "\n```"

    #expect(MarkdownBlockParser.codeBlocks(in: markdown) == [.init(language: "text", text: envelope)])
}

@Test func markdownParserBoundsTaggedJSONDetection() {
    let oversized = "[[result]]\n{\"text\":\""
        + String(repeating: "a", count: CodeBlockHighlightPolicy.maximumCharacters)
        + "\"}\n[[/result]]"
    let tooManyLines = "[[result]]\n{"
        + String(repeating: "\n", count: CodeBlockHighlightPolicy.maximumLines)
        + "}\n[[/result]]"

    #expect(MarkdownBlockParser.codeBlocks(in: oversized).isEmpty)
    #expect(MarkdownBlockParser.codeBlocks(in: tooManyLines).isEmpty)
}

@Test func markdownTaskTogglePreservesUnrelatedMarkdown() {
    let markdown = """
    # Acceptance criteria

      - [ ] first criterion
        - [x] nested criterion
    **Unrelated** text and `- [ ] code`.
    """
    let toggled = MarkdownTaskListEditor.toggledDescription(markdown, taskIndex: 1)
    #expect(toggled == """
    # Acceptance criteria

      - [ ] first criterion
        - [ ] nested criterion
    **Unrelated** text and `- [ ] code`.
    """)
}

@Test func markdownTaskToggleSkipsFencedCodeAndSupportsOrderedTasks() {
    let markdown = """
    ```markdown
    - [ ] code example
    ```
    1. [ ] actual criterion
    2. [x] another criterion
    """
    #expect(MarkdownTaskListEditor.toggledDescription(markdown, taskIndex: 0) == """
    ```markdown
    - [ ] code example
    ```
    1. [x] actual criterion
    2. [x] another criterion
    """)
}
