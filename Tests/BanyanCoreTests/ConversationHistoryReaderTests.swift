import Foundation
import Testing
@testable import BanyanCore

private func historyFile(_ content: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-reader-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("transcript.jsonl")
    try Data(content.utf8).write(to: url)
    return url
}

private func codexMessage(_ role: String, _ text: String) -> String {
    #"{"type":"response_item","payload":{"type":"message","role":"\#(role)","content":[{"type":"input_text","text":"\#(text)"}]}}"# + "\n"
}

@Test func conversationHistoryPagesAreStableAcrossAppends() async throws {
    let url = try historyFile(#"{"type":"session_meta","payload":{"id":"conversation-a"}}"# + "\n" +
        codexMessage("user", "one") + codexMessage("assistant", "two") + codexMessage("user", "three"))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let identity = ConversationHistoryReader.Identity(provider: .codex, conversationID: "conversation-a", transcriptURL: url)
    let reader = ConversationHistoryReader()
    let latest = try await reader.page(identity: identity, limit: 2)
    #expect(latest.messages.map(\.text) == ["two", "three"])
    let cursor = try #require(latest.earlier)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(codexMessage("assistant", "four").utf8))
    try handle.close()
    let previous = try await reader.page(identity: identity, earlier: cursor, limit: 2)
    #expect(previous.messages.map(\.text) == ["one"])
    #expect(previous.earlier == nil)
    #expect(try await reader.page(identity: identity, limit: 2).messages.map(\.text) == ["three", "four"])
}

@Test func conversationHistoryRejectsWrongIdentityAndChangedGeneration() async throws {
    let content = #"{"type":"session_meta","payload":{"id":"conversation-a"}}"# + "\n" +
        codexMessage("user", "one") + codexMessage("assistant", "two")
    let url = try historyFile(content)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let reader = ConversationHistoryReader()
    let identity = ConversationHistoryReader.Identity(provider: .codex, conversationID: "conversation-a", transcriptURL: url)
    let other = ConversationHistoryReader.Identity(provider: .codex, conversationID: "conversation-b", transcriptURL: url)
    await #expect(throws: ConversationHistoryReader.ReadError.identityMismatch) { try await reader.page(identity: other) }
    let page = try await reader.page(identity: identity, limit: 1)
    let cursor = try #require(page.earlier)
    await #expect(throws: ConversationHistoryReader.ReadError.invalidCursor) { try await reader.page(identity: other, earlier: cursor) }
    try Data(content.replacingOccurrences(of: "one", with: "new").utf8).write(to: url)
    await #expect(throws: ConversationHistoryReader.ReadError.changed) { try await reader.page(identity: identity, earlier: cursor) }
}

@Test func conversationHistoryChecksClaudeRowsAndIncompleteTail() async throws {
    let content = #"{"type":"user","sessionId":"a","message":{"content":[{"type":"text","text":"first"},{"type":"text","text":"second"}]}}"# + "\n" + "{"
    let url = try historyFile(content)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let reader = ConversationHistoryReader()
    let identity = ConversationHistoryReader.Identity(provider: .claude, conversationID: "a", transcriptURL: url)
    let page = try await reader.page(identity: identity)
    #expect(page.messages.map(\.text) == ["first\nsecond"])
    #expect(page.incompleteTail)
    let wrong = content.replacingOccurrences(of: "\"sessionId\":\"a\"", with: "\"sessionId\":\"b\"")
    try Data(wrong.utf8).write(to: url)
    await #expect(throws: ConversationHistoryReader.ReadError.identityMismatch) { try await reader.page(identity: identity) }
}

@Test func conversationHistoryBoundsReadSize() async throws {
    let content = #"{"type":"session_meta","payload":{"id":"a"}}"# + "\n" +
        (0..<30).map { codexMessage("user", "message-\($0)") }.joined()
    let url = try historyFile(content)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let reader = ConversationHistoryReader(maxBytes: 500)
    let identity = ConversationHistoryReader.Identity(provider: .codex, conversationID: "a", transcriptURL: url)
    let page = try await reader.page(identity: identity)
    #expect(page.truncatedBefore)
    #expect(page.messages.last?.text == "message-29")
    #expect(!page.messages.contains(where: { $0.text == "message-0" }))
}

@Test func conversationHistoryResetInvalidatesEarlierCursor() async throws {
    let url = try historyFile(#"{"type":"session_meta","payload":{"session_id":"a"}}"# + "\n" +
        codexMessage("user", "old") + codexMessage("assistant", "answer"))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let reader = ConversationHistoryReader()
    let identity = ConversationHistoryReader.Identity(provider: .codex, conversationID: "a", transcriptURL: url)
    let before = try await reader.page(identity: identity, limit: 1)
    let cursor = try #require(before.earlier)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((codexMessage("user", "/clear") + codexMessage("user", "new")).utf8))
    try handle.close()
    await #expect(throws: ConversationHistoryReader.ReadError.changed) { try await reader.page(identity: identity, earlier: cursor) }
    #expect(try await reader.page(identity: identity).messages.map(\.text) == ["new"])
}

@Test func conversationHistoryReadsCompactedReplacementWithoutDuplicatingRetainedMessages() async throws {
    let compacted = #"{"type":"compacted","payload":{"replacement_history":[{"type":"message","role":"user","content":[{"type":"input_text","text":"retained user"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"retained answer"}]}]}}"# + "\n"
    let header = #"{"type":"session_meta","payload":{"id":"a"}}"# + "\n"
    let url = try historyFile(header + compacted + codexMessage("assistant", "later"))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let reader = ConversationHistoryReader()
    let identity = ConversationHistoryReader.Identity(provider: .codex, conversationID: "a", transcriptURL: url)
    let page = try await reader.page(identity: identity)
    #expect(page.resetCount == 1)
    #expect(page.messages.map(\.text) == ["retained user", "retained answer", "later"])
    try Data((header + codexMessage("user", "original") + compacted + codexMessage("assistant", "later")).utf8).write(to: url)
    let retained = try await reader.page(identity: identity)
    #expect(retained.messages.map(\.text) == ["original", "later"])
}

@Test func conversationHistoryIncludesBoundedToolOutput() async throws {
    let content = #"{"type":"session_meta","payload":{"id":"a"}}"# + "\n" +
        #"{"type":"response_item","payload":{"type":"function_call_output","output":"tool result"}}"# + "\n"
    let url = try historyFile(content)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let reader = ConversationHistoryReader()
    let identity = ConversationHistoryReader.Identity(provider: .codex, conversationID: "a", transcriptURL: url)
    let page = try await reader.page(identity: identity)
    #expect(page.messages.map(\.role) == ["tool"])
    #expect(page.messages.map(\.text) == ["tool result"])
}

@Test func conversationHistoryCursorIsBoundToItsTerminalOwner() async throws {
    let url = try historyFile(#"{"type":"session_meta","payload":{"id":"thread"}}"# + "\n" +
        codexMessage("user", "first") + codexMessage("assistant", "second"))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let root = AgentProcessIdentity(pid: 100, startSeconds: 1, startMicroseconds: 0)
    let writer = AgentProcessIdentity(pid: 101, startSeconds: 2, startMicroseconds: 0)
    let owner = ConversationHistoryReader.TerminalOwner(sessionID: "first", paneID: "%1", root: root, writer: writer)
    let other = ConversationHistoryReader.TerminalOwner(sessionID: "second", paneID: "%1", root: root, writer: writer)
    let identity = ConversationHistoryReader.Identity(provider: .codex, conversationID: "thread", transcriptURL: url, terminalOwner: owner)
    let otherIdentity = ConversationHistoryReader.Identity(provider: .codex, conversationID: "thread", transcriptURL: url, terminalOwner: other)
    let reader = ConversationHistoryReader()
    let page = try await reader.page(identity: identity, limit: 1)
    let cursor = try #require(page.earlier)
    await #expect(throws: ConversationHistoryReader.ReadError.invalidCursor) { try await reader.page(identity: otherIdentity, earlier: cursor) }
    let native = ConversationHistoryReader.Identity(provider: .codex, conversationID: "thread", transcriptURL: url, ownerSessionID: "first")
    let otherNative = ConversationHistoryReader.Identity(provider: .codex, conversationID: "thread", transcriptURL: url, ownerSessionID: "second")
    let nativePage = try await reader.page(identity: native, limit: 1)
    await #expect(throws: ConversationHistoryReader.ReadError.invalidCursor) {
        try await reader.page(identity: otherNative, earlier: try #require(nativePage.earlier))
    }
}

@Test func conversationHistoryReadsLegacyEventsAndCoalescesMirroredRecords() async throws {
    let lines = [
        #"{"type":"session_meta","payload":{"id":"a"}}"#,
        #"{"timestamp":"2026-01-01T00:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"legacy"}}"#,
        #"{"timestamp":"2026-01-01T00:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hello"}]}}"#,
        #"{"timestamp":"2026-01-01T00:00:02.100Z","type":"event_msg","payload":{"type":"agent_message","message":"hello"}}"#,
        #"{"timestamp":"2026-01-01T00:00:03Z","type":"event_msg","payload":{"type":"user_message","message":"repeat"}}"#,
        #"{"timestamp":"2026-01-01T00:00:04Z","type":"event_msg","payload":{"type":"user_message","message":"repeat"}}"#
    ]
    let url = try historyFile(lines.joined(separator: "\n") + "\n")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let reader = ConversationHistoryReader()
    let identity = ConversationHistoryReader.Identity(provider: .codex, conversationID: "a", transcriptURL: url)
    let page = try await reader.page(identity: identity)
    #expect(page.messages.map(\.text) == ["legacy", "hello", "repeat", "repeat"])
}
