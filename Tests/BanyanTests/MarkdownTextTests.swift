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
