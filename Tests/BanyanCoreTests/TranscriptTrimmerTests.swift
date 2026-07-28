import Testing
@testable import BanyanCore

@Test func sharedTranscriptTrimmerKeepsRecentCodexOutput() {
    let contents = [
        #"{"type":"response_item","payload":{"type":"function_call_output","output":"old tool output"}}"#,
        #"{"type":"response_item","payload":{"type":"function_call_output","output":"recent output"}}"#
    ].joined(separator: "\n")

    let result = TranscriptTrimmer.trim(
        contents: contents,
        provider: .codex,
        oldSessionID: "old-session",
        newSessionID: "new-session",
        config: .init(minResultBytes: 1, keepRecentResults: 1)
    )

    #expect(result?.trimmedCount == 1)
    #expect(result?.bytesSaved == "old tool output".utf8.count)
    #expect(result?.content.contains("Banyan trimmed") == true)
    #expect(result?.content.contains("recent output") == true)
}
