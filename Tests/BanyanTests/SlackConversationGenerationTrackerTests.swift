import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

@Test func slackConversationGenerationsSurviveAppendsAndRestartButNotRewrite() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slack-generation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("index.json")
    func proof(_ text: String, inode: UInt64 = 10, resets: Int = 0) -> ConversationHistoryReader.Proof {
        .init(bytes: Data(text.utf8), deviceNumber: 1, fileNumber: inode, resetCount: resets)
    }
    let tracker = SlackConversationGenerationTracker(file: file)
    let first = try await tracker.identity(sessionID: "row", conversationID: "thread", proof: proof("private fixture"))
    let appended = try await tracker.identity(sessionID: "row", conversationID: "thread", proof: proof("private fixture continued"))
    #expect(appended == first)
    let restarted = SlackConversationGenerationTracker(file: file)
    let afterRestart = try await restarted.identity(sessionID: "row", conversationID: "thread", proof: proof("private fixture continued"))
    #expect(afterRestart == first)
    let reset = try await restarted.identity(sessionID: "row", conversationID: "thread", proof: proof("private fixture continued reset", resets: 1))
    #expect(reset != first)
    let compacted = try await restarted.identity(sessionID: "row", conversationID: "thread", proof: proof("private fixture", resets: 0))
    #expect(compacted != first && compacted != reset)
    let replacement = try await restarted.identity(sessionID: "row", conversationID: "thread", proof: proof("private fixture", inode: 11))
    #expect(replacement != compacted)
    let encoded = try String(contentsOf: file, encoding: .utf8)
    #expect(!encoded.contains("private fixture"))
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    try FileManager.default.removeItem(at: file)
    let lostIndex = SlackConversationGenerationTracker(file: file)
    let newGeneration = try await lostIndex.identity(sessionID: "row", conversationID: "thread", proof: proof("private fixture", inode: 11))
    #expect(newGeneration != replacement)
}

@Test func slackConversationGenerationCorruptionFailsClosed() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slack-generation-corrupt-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("index.json")
    try Data("not-json".utf8).write(to: file)
    let tracker = SlackConversationGenerationTracker(file: file)
    let proof = ConversationHistoryReader.Proof(bytes: Data("fixture".utf8), deviceNumber: 1, fileNumber: 2, resetCount: 0)
    await #expect(throws: (any Error).self) {
        try await tracker.identity(sessionID: "row", conversationID: "thread", proof: proof)
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == "not-json")
}

@Test func longTranscriptGenerationSurvivesAppendButNotCompactionOrReplacement() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slack_generation_window_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let transcript = directory.appendingPathComponent("rollout-fixture.jsonl")
    func message(_ text: String) -> String {
        #"{"type":"event_msg","payload":{"type":"user_message","message":"\#(text)"}}"# + "\n"
    }
    let initial = #"{"type":"session_meta","payload":{"id":"thread"}}"# + "\n" +
        (0..<30).map { message("message-\($0)") }.joined()
    try Data(initial.utf8).write(to: transcript)
    let reader = ConversationHistoryReader(maxBytes: 500)
    let identity = ConversationHistoryReader.Identity(provider: .codex, conversationID: "thread", transcriptURL: transcript)
    let journal = directory.appendingPathComponent("index.json")
    let tracker = SlackConversationGenerationTracker(file: journal)
    let firstPage = try await reader.page(identity: identity, limit: 1)
    #expect(firstPage.truncatedBefore)
    let first = try await tracker.identity(sessionID: "row", conversationID: "thread", proof: try #require(firstPage.proof))
    let cursor = try #require(firstPage.earlier)
    let handle = try FileHandle(forWritingTo: transcript)
    try handle.seekToEnd(); try handle.write(contentsOf: Data(message("next").utf8)); try handle.close()
    let appendedPage = try await reader.page(identity: identity, limit: 1)
    let restarted = SlackConversationGenerationTracker(file: journal)
    let appended = try await restarted.identity(sessionID: "row", conversationID: "thread", proof: try #require(appendedPage.proof))
    #expect(appended == first)
    let earlier = try await reader.page(identity: identity, earlier: cursor, limit: 1)
    #expect(earlier.messages.last?.text == "message-28")
    let compact = try FileHandle(forWritingTo: transcript)
    try compact.seekToEnd()
    try compact.write(contentsOf: Data((#"{"type":"compacted","payload":{"replacement_history":[]}}"# + "\n" + message("after compaction")).utf8))
    try compact.close()
    await #expect(throws: ConversationHistoryReader.ReadError.changed) { try await reader.page(identity: identity, earlier: cursor) }
    let compactedPage = try await reader.page(identity: identity, limit: 1)
    let compacted = try await restarted.identity(sessionID: "row", conversationID: "thread", proof: try #require(compactedPage.proof))
    #expect(compacted != appended)
    let reset = try FileHandle(forWritingTo: transcript)
    try reset.seekToEnd(); try reset.write(contentsOf: Data(message("/clear").utf8)); try reset.close()
    let resetPage = try await reader.page(identity: identity, limit: 1)
    let resetGeneration = try await restarted.identity(sessionID: "row", conversationID: "thread", proof: try #require(resetPage.proof))
    #expect(resetGeneration != compacted)
    try Data(initial.utf8).write(to: transcript, options: .atomic)
    let replacedPage = try await reader.page(identity: identity, limit: 1)
    let replaced = try await restarted.identity(sessionID: "row", conversationID: "thread", proof: try #require(replacedPage.proof))
    #expect(replaced != resetGeneration)
}
