import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

@Suite(.serialized)
@MainActor
struct SlackThreadJournalTests {
    private let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    private let identity = SlackConversationIdentity(kind: "terminalCodex", conversationID: "conversation-a", generation: "generation-a")

    @Test func bindingSurvivesRestartAndRejectsConflictingRootsAndSessions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slack-thread-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.json")
        let journal = SlackThreadJournal(file: file)
        let first = try journal.bind(sessionID: "session-a", identity: identity, principal: principal, slackThread: "100.123")
        #expect(try journal.bind(sessionID: "session-a", identity: identity, principal: principal, slackThread: "100.123") == first)
        #expect(throws: CodexRemoteError.self) { try journal.bind(sessionID: "session-a", identity: identity, principal: principal, slackThread: "101.123") }
        #expect(throws: CodexRemoteError.self) { try journal.bind(sessionID: "session-b", identity: identity, principal: principal, slackThread: "100.123") }
        let restarted = SlackThreadJournal(file: file)
        #expect(try restarted.lookup(sessionID: "session-a", identity: identity, principal: principal) == first)
        #expect(try restarted.lookup(sessionID: "session-b", identity: identity, principal: principal) == nil)
        let changed = SlackConversationIdentity(kind: "terminalCodex", conversationID: "conversation-a", generation: "generation-b")
        #expect(try restarted.lookup(sessionID: "session-a", identity: changed, principal: principal) == nil)
        #expect(try restarted.permitsNativeAttachment(sessionID: "native", threadID: "thread", principal: principal, slackThread: "100.123") == false)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func malformedOrConflictingJournalFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slack-thread-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("journal.json")
        let id = UUID().uuidString
        let row: [String: Any] = ["id": id, "sessionID": "a", "identity": ["kind": "terminalCodex", "conversationID": "c", "generation": "generation-a"],
                                  "workspace": "T_TEST", "channel": "C_TEST", "slackThread": "100.123"]
        try JSONSerialization.data(withJSONObject: ["version": 1, "mappings": [row, row]]).write(to: file)
        let journal = SlackThreadJournal(file: file)
        #expect(journal.storageError != nil)
        #expect(throws: CodexRemoteError.self) { try journal.lookup(sessionID: "a", identity: identity, principal: principal) }
        #expect(throws: CodexRemoteError.self) { try journal.bind(sessionID: "a", identity: identity, principal: principal, slackThread: "101.123") }
    }
}
