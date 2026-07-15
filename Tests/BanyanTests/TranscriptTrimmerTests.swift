import Foundation
import Testing
@testable import Banyan

private func jsonLine(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(data: data, encoding: .utf8)!
}

private func claudeToolResult(uuid: String, parent: String, toolUseID: String, content: String) -> [String: Any] {
    [
        "type": "user",
        "uuid": uuid,
        "parentUuid": parent,
        "sessionId": "old-session-id",
        "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": toolUseID, "content": content]]],
    ]
}

private func codexOutput(callID: String, output: String) -> [String: Any] {
    ["type": "response_item", "payload": ["type": "function_call_output", "call_id": callID, "output": output]]
}

@Test func claudeTrimReplacesOldOversizedResultsAndKeepsRecentAndSmall() {
    let big = String(repeating: "A", count: 100)
    let big2 = String(repeating: "B", count: 100)
    let lines = [
        jsonLine(["type": "user", "uuid": "u0", "parentUuid": NSNull(), "sessionId": "old-session-id",
                  "message": ["role": "user", "content": [["type": "text", "text": "hi"]]]]),
        jsonLine(["type": "assistant", "uuid": "u1", "parentUuid": "u0", "sessionId": "old-session-id",
                  "message": ["role": "assistant", "content": [["type": "tool_use", "id": "t1", "name": "read", "input": [:]]]]]),
        jsonLine(claudeToolResult(uuid: "u2", parent: "u1", toolUseID: "t1", content: big)),
        jsonLine(claudeToolResult(uuid: "u3", parent: "u2", toolUseID: "t2", content: big2)),
        jsonLine(claudeToolResult(uuid: "u4", parent: "u3", toolUseID: "t3", content: "ok")),
    ]
    let contents = lines.joined(separator: "\n") + "\n"

    let outcome = TranscriptTrimmer.trim(
        contents: contents,
        provider: .claude,
        oldSessionID: "old-session-id",
        newSessionID: "new-session-id",
        config: .init(minResultBytes: 10, keepRecentResults: 1)
    )

    #expect(outcome != nil)
    #expect(outcome?.trimmedCount == 2)
    #expect(outcome?.bytesSaved == 200)
    let content = outcome!.content
    // Session re-keyed everywhere; old id gone.
    #expect(!content.contains("old-session-id"))
    #expect(content.contains("new-session-id"))
    // The two oversized results are placeholdered; the recent small one survives.
    #expect(!content.contains(big))
    #expect(!content.contains(big2))
    #expect(content.contains("[Banyan trimmed 100 bytes of tool output to save context]"))
    #expect(content.contains("\"content\":\"ok\""))
    // uuid chain and tool_use pairing preserved.
    #expect(content.contains("\"parentUuid\":\"u3\""))
    #expect(content.contains("\"tool_use_id\":\"t1\""))
    // Trailing newline preserved.
    #expect(content.hasSuffix("\n"))
}

@Test func claudeTrimReturnsNilWhenNothingLargeEnough() {
    let lines = (0..<5).map { i in
        jsonLine(claudeToolResult(uuid: "u\(i)", parent: "u\(i)", toolUseID: "t\(i)", content: "small"))
    }
    let outcome = TranscriptTrimmer.trim(
        contents: lines.joined(separator: "\n"),
        provider: .claude,
        oldSessionID: "old-session-id",
        newSessionID: "new-session-id",
        config: .init(minResultBytes: 1000, keepRecentResults: 1)
    )
    #expect(outcome == nil)
}

@Test func claudeTrimReturnsNilWhenFewerUnitsThanKeepRecent() {
    let big = String(repeating: "A", count: 100)
    let outcome = TranscriptTrimmer.trim(
        contents: jsonLine(claudeToolResult(uuid: "u0", parent: "u0", toolUseID: "t0", content: big)),
        provider: .claude,
        oldSessionID: "old-session-id",
        newSessionID: "new-session-id",
        config: .init(minResultBytes: 10, keepRecentResults: 8)
    )
    #expect(outcome == nil)
}

@Test func codexTrimReplacesOldOversizedOutputAndProtectsRecent() {
    let big = String(repeating: "A", count: 100)
    let big2 = String(repeating: "B", count: 100)
    let lines = [
        jsonLine(["type": "session_meta", "payload": ["id": "old-session-id", "session_id": "old-session-id", "cwd": "/tmp"]]),
        jsonLine(codexOutput(callID: "c0", output: big)),   // old + big → trimmed
        jsonLine(codexOutput(callID: "c1", output: "ok")),  // small → skipped
        jsonLine(codexOutput(callID: "c2", output: big2)),  // most recent → protected
    ]
    let outcome = TranscriptTrimmer.trim(
        contents: lines.joined(separator: "\n"),
        provider: .codex,
        oldSessionID: "old-session-id",
        newSessionID: "new-session-id",
        config: .init(minResultBytes: 10, keepRecentResults: 1)
    )

    #expect(outcome != nil)
    #expect(outcome?.trimmedCount == 1)
    #expect(outcome?.bytesSaved == 100)
    let content = outcome!.content
    #expect(!content.contains(big))       // first big output trimmed
    #expect(content.contains(big2))       // recent big output protected
    #expect(content.contains("\"output\":\"ok\""))
    #expect(!content.contains("old-session-id"))
    #expect(content.contains("new-session-id"))
}

@Test func trimRejectsUnsupportedProviderAndIdenticalIDs() {
    let line = jsonLine(claudeToolResult(uuid: "u0", parent: "u0", toolUseID: "t0", content: String(repeating: "A", count: 100)))
    #expect(TranscriptTrimmer.trim(contents: line, provider: .gemini, oldSessionID: "a", newSessionID: "b") == nil)
    #expect(TranscriptTrimmer.trim(contents: line, provider: .claude, oldSessionID: "same", newSessionID: "same") == nil)
}

@Test func destinationURLRenamesClaudeStemAndCodexRolloutInPlace() {
    let claudeSource = URL(fileURLWithPath: "/a/b/old-session-id.jsonl")
    #expect(
        TranscriptResumePreparer.destinationURL(for: claudeSource, oldSourceID: "old-session-id", newSourceID: "new-id")
            == URL(fileURLWithPath: "/a/b/new-id.jsonl")
    )

    let codexSource = URL(fileURLWithPath: "/a/b/rollout-2026-06-25T19-04-51-old-session-id.jsonl")
    #expect(
        TranscriptResumePreparer.destinationURL(for: codexSource, oldSourceID: "old-session-id", newSourceID: "new-id")
            == URL(fileURLWithPath: "/a/b/rollout-2026-06-25T19-04-51-new-id.jsonl")
    )

    let mismatch = URL(fileURLWithPath: "/a/b/unrelated.jsonl")
    #expect(TranscriptResumePreparer.destinationURL(for: mismatch, oldSourceID: "old-session-id", newSourceID: "new-id") == nil)
}
