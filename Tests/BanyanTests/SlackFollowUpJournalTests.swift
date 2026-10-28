import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

@Suite(.serialized)
@MainActor
struct SlackFollowUpJournalTests {
    @Test func uncertainReceiptSurvivesRestartAndRequiresLocalAcknowledgement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("followup_receipt_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.json")
        let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
        let identity = SlackConversationIdentity(kind: "terminalCodex", conversationID: "thread", generation: "generation")
        let journal = SlackFollowUpJournal(file: file)
        let (receipt, fresh) = try journal.claim(operationID: "reply-1", principal: principal, sessionID: "row",
            identity: identity, slackThread: "100.1", text: "private fixture message")
        #expect(fresh)
        try journal.markSending(receipt)
        let restarted = SlackFollowUpJournal(file: file)
        #expect(try restarted.receipt(operationID: "reply-1", principal: principal)?.status == "uncertain")
        let (duplicate, claimed) = try restarted.claim(operationID: "reply-1", principal: principal, sessionID: "row",
            identity: identity, slackThread: "100.1", text: "private fixture message")
        #expect(!claimed && duplicate.status == "uncertain")
        #expect(throws: SlackFollowUpJournal.Failure.self) {
            try restarted.claim(operationID: "reply-2", principal: principal, sessionID: "row",
                identity: identity, slackThread: "100.1", text: "another")
        }
        #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("private fixture message"))
        try restarted.acknowledgeUncertain(operationID: "reply-1", workspace: "T_TEST")
        #expect(try restarted.receipt(operationID: "reply-1", principal: principal)?.status == "acknowledged")
        let (_, next) = try restarted.claim(operationID: "reply-2", principal: principal, sessionID: "row",
            identity: identity, slackThread: "100.1", text: "another")
        #expect(next)
    }
}
