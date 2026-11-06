import BanyanCore
import Testing
@testable import Banyan

@Test func toolTextPresentationPrettyPrintsJSONWithoutReorderingKeys() {
    let raw = #"[{"class":"worker","tool_groups":["worker_code"],"engine":"native","id":"worker-1","usage":{"reported_requests":2,"ok":true}}]"#

    let presentation = PuckToolTextPresentation(text: raw)

    #expect(presentation.language == .json)
    #expect(presentation.text.contains("\n  {\n    \"class\": \"worker\","))
    #expect(presentation.text.range(of: "\"class\"")!.lowerBound < presentation.text.range(of: "\"id\"")!.lowerBound)
    #expect(presentation.text.contains("\"tool_groups\": [\n      \"worker_code\"\n    ]"))
}

@Test func toolTextPresentationDetectsJSONLines() {
    let raw = """
    {"type":"start","id":1}
    {"type":"finish","id":1,"ok":true}
    """

    let presentation = PuckToolTextPresentation(text: raw)

    #expect(presentation.language == .jsonl)
    #expect(presentation.text.contains("\"type\": \"start\""))
    #expect(presentation.text.contains("\"type\": \"finish\""))
    #expect(presentation.text.contains("\n  \"ok\": true\n}"))
    #expect(presentation.text.contains("}\n\n{"))
}

@Test func toolTextPresentationFormatsJSONLinesMixedWithErrors() throws {
    let raw = #"{"ahead_by":0,"behind_by":22,"status":"behind"}"# + "\n"
        + #"{"message":"fix: wait for cleanup\n\nDetails","ok":true}"# + "\n"
        + "HTTP 404: workflow not found (https://api.example.com/actions/workflows/build.yml)"

    let presentation = PuckToolTextPresentation(text: raw)
    let sections = try #require(presentation.syntaxSections)
    let spans = try #require(CodeBlockSyntaxHighlighter.highlight(sections))

    #expect(presentation.containsJSON)
    #expect(presentation.languageIdentifier == "JSON + Text")
    #expect(presentation.text == """
    {
      "ahead_by": 0,
      "behind_by": 22,
      "status": "behind"
    }
    {
      "message": "fix: wait for cleanup\\n\\nDetails",
      "ok": true
    }
    HTTP 404: workflow not found (https://api.example.com/actions/workflows/build.yml)
    """)
    #expect(spans.map(\.text).joined() == presentation.text)
    #expect(spans.contains { $0.text == "\"ahead_by\"" && $0.kind == .key })
    #expect(spans.contains { $0.text.contains("HTTP 404") && $0.kind == nil })
}

@Test func toolTextPresentationFindsMultilineNestedJSONBetweenLogs() throws {
    let raw = #"""
    Fetching results...
    {
      "data":{"items":[{"text":"braces } [ and \"quotes\"","path":"a\\b"}]},
      "empty":[]
    }
    Done: 1 result
    [{"next":false}]
    """#

    let presentation = PuckToolTextPresentation(text: raw)
    let sections = try #require(presentation.syntaxSections)

    #expect(sections.filter { $0.language == .json }.count == 2)
    #expect(presentation.text.hasPrefix("Fetching results...\n{\n  \"data\": {\n"))
    #expect(presentation.text.contains(#""text": "braces } [ and \"quotes\""#))
    #expect(presentation.text.contains(#""path": "a\\b""#))
    #expect(presentation.text.contains("\nDone: 1 result\n[\n  {\n    \"next\": false"))
}

@Test func toolTextPresentationPreservesNonJSONAndExplicitLanguages() {
    for raw in [
        "Starting\n{not JSON}\nDone",
        "Starting\n{\"value\": 1\noutput truncated",
        "Starting\n{\"value\": 1} trailing log",
        "Starting\nlog prefix {\"value\": 1}",
    ] {
        let presentation = PuckToolTextPresentation(text: raw)
        #expect(presentation.syntaxSections == nil)
        #expect(presentation.text == raw)
    }

    let shell = "echo done\n{\"value\":1}"
    let explicit = PuckToolTextPresentation(text: shell, explicitLanguage: "shell")
    #expect(explicit.text == shell)
    #expect(explicit.language == .shell)
    #expect(explicit.syntaxSections == nil)

    let diff = "diff --git a/result b/result\n{\"value\":1}\n-old\n+new"
    let presentation = PuckToolTextPresentation(text: diff)
    #expect(presentation.language == .diff)
    #expect(presentation.text == diff)
    #expect(presentation.syntaxSections == nil)
}

@Test func toolTextPresentationPreservesLogWhitespaceAndInvalidJSON() throws {
    let raw = "  Starting  \r\n{broken}\r\n  {\"ok\":true}\r\n\r\n  Done  "
    let presentation = PuckToolTextPresentation(text: raw)
    let sections = try #require(presentation.syntaxSections)

    #expect(sections.filter { $0.language == .json }.count == 1)
    // The transcript's existing plain-text normalization removes carriage returns.
    #expect(presentation.text == "  Starting  \n{broken}\n{\n  \"ok\": true\n}\n\n  Done  ")
}

@Test func toolTextPresentationLeavesTruncatedJSONAfterCompleteResultsUntouched() throws {
    let raw = "{\"ok\":true}\n{\"partial\":[1,2\noutput truncated"
    let presentation = PuckToolTextPresentation(text: raw)
    let sections = try #require(presentation.syntaxSections)
    let spans = try #require(CodeBlockSyntaxHighlighter.highlight(sections))

    #expect(presentation.text == "{\n  \"ok\": true\n}\n{\"partial\":[1,2\noutput truncated")
    #expect(spans.contains { $0.text == "\n{\"partial\":[1,2\noutput truncated" && $0.kind == nil })
}

@Test func toolTextPresentationHighlightsYAMLWithoutRewritingIt() {
    let raw = """
    name: banyan
    enabled: true
    services:
      - web
      - worker
    """

    let presentation = PuckToolTextPresentation(text: raw)

    #expect(presentation.language == .yaml)
    #expect(presentation.text == raw)
}

@Test func toolTextPresentationLeavesPlainOutputUnclassified() {
    let raw = """
    Build complete
    All tests passed
    """

    let presentation = PuckToolTextPresentation(text: raw)

    #expect(presentation.language == nil)
    #expect(presentation.text == raw)
}

@Test func toolTextPresentationHonorsExplicitLanguagesAndDiffDetection() {
    let json = PuckToolTextPresentation(text: #"{"ok":true}"#, explicitLanguage: "json")
    #expect(json.language == .json)
    #expect(json.text == "{\n  \"ok\": true\n}")

    let diff = PuckToolTextPresentation(text: """
    --- a/file.swift
    +++ b/file.swift
    @@ -1 +1 @@
    -let old = true
    +let new = true
    """)
    #expect(diff.language == .diff)
    #expect(diff.text.hasPrefix("--- a/file.swift"))
}

@Test func toolPreviewFormatsJSONBeforeCountingHiddenLines() throws {
    let tool = PuckToolActivity(
        callID: "workers", name: "exec_command",
        output: #"[{"id":"worker-1","usage":{"requests":2,"ok":true}}]"#,
        state: .succeeded
    )

    let preview = try #require(tool.preview)

    #expect(preview.language == .json)
    #expect(preview.lines == [
        "[", "  {", "    \"id\": \"worker-1\",", "    \"usage\": {",
        "      \"requests\": 2,", "      \"ok\": true", "    }", "  }",
    ])
    #expect(preview.hiddenLineCount == 1)
}

@Test func toolPreviewFormatsConsecutiveJSONResultsAfterRemovingShellWrappers() throws {
    let tool = PuckToolActivity(
        callID: "search", name: "exec_command",
        output: """
        exit code: 0
        --- stdout ---
        {"error":{"code":"runtime","message":"attempt to write a readonly database"}}
        [{"number":123,"state":"MERGED"}]
        """,
        state: .succeeded
    )

    let preview = try #require(tool.preview)

    #expect(preview.language == .jsonl)
    #expect(preview.lines == [
        "{", "  \"error\": {", "    \"code\": \"runtime\",",
        "    \"message\": \"attempt to write a readonly database\"", "  }", "}", "", "[",
    ])
    #expect(preview.hiddenLineCount == 5)
}

@Test func toolPreviewKeepsPlainAndIncompleteJSONOutputCompact() throws {
    for output in [
        "Building\nTests passed\nDone",
        "{\"error\":{\"code\":\"runtime\"\noutput truncated\nDone",
    ] {
        let tool = PuckToolActivity(
            callID: "command", name: "exec_command", output: output, state: .succeeded
        )
        let preview = try #require(tool.preview)
        #expect(preview.language == nil)
        #expect(preview.lines == Array(output.components(separatedBy: "\n").prefix(2)))
        #expect(preview.hiddenLineCount == 1)
    }
}

@Test func toolPreviewClipsMixedJSONSectionsWithoutLosingHighlighting() throws {
    let tool = PuckToolActivity(
        callID: "command", name: "exec_command",
        output: "Fetching\n{\"data\":{\"items\":[1,2,3],\"ok\":true}}\nHTTP 404: missing",
        state: .succeeded
    )
    let presentation = PuckToolTextPresentation(text: tool.displayOutput)
    let preview = try #require(tool.preview)
    let sections = try #require(preview.syntaxSections)
    let spans = try #require(CodeBlockSyntaxHighlighter.highlight(sections))

    #expect(preview.lines.count == 8)
    #expect(preview.hiddenLineCount == presentation.text.components(separatedBy: "\n").count - 8)
    #expect(sections.map(\.text).joined() == preview.lines.joined(separator: "\n"))
    #expect(spans.map(\.text).joined() == preview.lines.joined(separator: "\n"))
    #expect(spans.contains { $0.text == "Fetching\n" && $0.kind == nil })
    #expect(spans.contains { $0.text == "\"items\"" && $0.kind == .key })
    #expect(!spans.contains { $0.text.contains("HTTP 404") })
}

@Test func toolPreviewKeepsShortMixedOutputComplete() throws {
    let tool = PuckToolActivity(
        callID: "command", name: "exec_command",
        output: "{\"ok\":true}\nHTTP 404: missing", state: .succeeded
    )
    let preview = try #require(tool.preview)
    let sections = try #require(preview.syntaxSections)
    let spans = try #require(CodeBlockSyntaxHighlighter.highlight(sections))

    #expect(preview.hiddenLineCount == 0)
    #expect(preview.lines == ["{", "  \"ok\": true", "}", "HTTP 404: missing"])
    #expect(spans.contains { $0.text == "\nHTTP 404: missing" && $0.kind == nil })
}
