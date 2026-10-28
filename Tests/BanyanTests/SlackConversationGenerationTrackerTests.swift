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

@Test func longTranscriptRemainsUnprovenAfterAnUnobservedPrefixRewrite() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slack_generation_window_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let transcript = directory.appendingPathComponent("rollout-fixture.jsonl")
    func message(_ text: String) -> String {
        #"{"type":"event_msg","payload":{"type":"user_message","message":"\#(text)"}}"# + "\n"
    }
    let header = #"{"type":"session_meta","payload":{"id":"thread"}}"# + "\n"
    let initial = header + message("hello1") + (0..<30).map { message("message-\($0)") }.joined()
    try Data(initial.utf8).write(to: transcript)
    let reader = ConversationHistoryReader(maxBytes: 500)
    let identity = ConversationHistoryReader.Identity(provider: .codex, conversationID: "thread", transcriptURL: transcript)
    let first = try await reader.page(identity: identity, limit: 1)
    #expect(first.truncatedBefore && first.proof.map { _ in true } == nil)
    let offset = try #require(initial.range(of: "hello1")).lowerBound.utf16Offset(in: initial)
    let handle = try FileHandle(forWritingTo: transcript)
    try handle.seek(toOffset: UInt64(offset)); try handle.write(contentsOf: Data("/clear".utf8)); try handle.close()
    let changed = try await reader.page(identity: identity, limit: 1)
    #expect(changed.truncatedBefore && changed.proof.map { _ in true } == nil)
    #expect(changed.windowDigest == first.windowDigest)
}
