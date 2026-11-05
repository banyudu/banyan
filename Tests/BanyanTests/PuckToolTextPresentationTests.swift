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
