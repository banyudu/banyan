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
