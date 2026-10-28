import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

@Suite(.serialized)
@MainActor
struct SlackDecisionJournalTests {
    private let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")
    private let identity = SlackConversationIdentity(kind: "terminalCodex", conversationID: "thread", generation: "generation")

    @Test func receiptSurvivesRestartAndUncertainSendCannotBeRepeated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("decision_journal_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.json")
        let journal = SlackDecisionJournal(file: file)
        let decision = try #require(try journal.observe(sessionID: "row", identity: identity, principal: principal,
            slackThread: "100.1", paneID: "%1", rootPID: 100, footprint: "footprint"))
        #expect(decision.status == "pending")
        let (receipt, fresh) = try journal.claim(operationID: "action-1", principal: principal, request: decision, option: 2)
        #expect(fresh)
        #expect(throws: SlackDecisionJournal.Failure.self) { try journal.claim(operationID: "action-2", principal: principal, request: decision, option: 2) }
        try journal.markSending(receipt)
        let restarted = SlackDecisionJournal(file: file)
        let recovered = try #require(try restarted.receipt(operationID: "action-1", principal: principal))
        #expect(recovered.status == "uncertain")
        let current = try #require(try restarted.observe(sessionID: "row", identity: identity, principal: principal,
            slackThread: "100.1", paneID: "%1", rootPID: 100, footprint: "footprint"))
        #expect(current.id == decision.id && current.status == "uncertain")
        let (replay, claimed) = try restarted.claim(operationID: "action-1", principal: principal, request: current, option: 2)
        #expect(!claimed && replay.status == "uncertain")
        #expect(throws: SlackDecisionJournal.Failure.self) { try restarted.claim(operationID: "action-2", principal: principal, request: current, option: 2) }
        _ = try restarted.observe(sessionID: "row", identity: identity, principal: principal,
            slackThread: "100.1", paneID: "%1", rootPID: 100, footprint: nil)
        let later = try #require(try restarted.observe(sessionID: "row", identity: identity, principal: principal,
            slackThread: "100.1", paneID: "%1", rootPID: 100, footprint: "footprint"))
        #expect(later.id != decision.id && later.status == "pending")
    }

    @Test func resolvedRequestCannotAdvanceAnAlreadyClaimedOperation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("decision_race_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SlackDecisionJournal(file: directory.appendingPathComponent("journal.json"))
        let decision = try #require(try journal.observe(sessionID: "row", identity: identity, principal: principal,
            slackThread: "100.1", paneID: "%1", rootPID: 100, footprint: "first"))
        let (receipt, _) = try journal.claim(operationID: "action", principal: principal, request: decision, option: 1)
        _ = try journal.observe(sessionID: "row", identity: identity, principal: principal,
            slackThread: "100.1", paneID: "%1", rootPID: 100, footprint: nil)
        #expect(throws: SlackDecisionJournal.Failure.self) { try journal.markSending(receipt) }
        try journal.reject(receipt, reason: "request_changed")
        #expect(try journal.receipt(operationID: "action", principal: principal)?.status == "rejected")
    }

    @Test func storageFailureFencesAlreadyObservedRequests() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("decision_storage_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SlackDecisionJournal(file: directory.appendingPathComponent("journal.json"))
        let decision = try #require(try journal.observe(sessionID: "row", identity: identity, principal: principal,
            slackThread: "100.1", paneID: "%1", rootPID: 100, footprint: "first"))
        #expect(journal.fence.contains(decision.id))
        try FileManager.default.removeItem(at: directory)
        try Data("not a directory".utf8).write(to: directory)
        #expect(throws: SlackDecisionJournal.Failure.self) { try journal.claim(operationID: "action", principal: principal, request: decision, option: 1) }
        #expect(!journal.fence.contains(decision.id))
        #expect(journal.storageError != nil)
    }

    @Test func interruptedPreparationIsKnownNotSent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("decision_prepare_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.json")
        let journal = SlackDecisionJournal(file: file)
        let decision = try #require(try journal.observe(sessionID: "row", identity: identity, principal: principal,
            slackThread: "100.1", paneID: "%1", rootPID: 100, footprint: "opaque-fingerprint"))
        _ = try journal.claim(operationID: "action-1", principal: principal, request: decision, option: 1)
        let restarted = SlackDecisionJournal(file: file)
        let receipt = try #require(try restarted.receipt(operationID: "action-1", principal: principal))
        #expect(receipt.status == "rejected" && receipt.reason == "interrupted_before_send")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func olderReceiptsWithoutPayloadDigestRemainReadable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("decision_legacy_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.json")
        let journal = SlackDecisionJournal(file: file)
        let decision = try #require(try journal.observe(sessionID: "row", identity: identity, principal: principal,
            slackThread: "100.1", paneID: "%1", rootPID: 100, footprint: "first"))
        let (receipt, _) = try journal.claim(operationID: "legacy", principal: principal, request: decision, option: 1)
        try journal.markSending(receipt); try journal.finish(receipt, sent: true, reason: nil)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var receipts = try #require(object["receipts"] as? [[String: Any]])
        receipts[0].removeValue(forKey: "payloadDigest")
        object["receipts"] = receipts
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let restored = SlackDecisionJournal(file: file)
        #expect(restored.storageError == nil)
        #expect(try restored.receipt(operationID: "legacy", principal: principal)?.status == "submitted")
    }

    @Test func parkingFencesPendingDispatchAcrossUnrelatedJournalWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("decision_park_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SlackDecisionJournal(file: directory.appendingPathComponent("journal.json"))
        let first = try #require(try journal.observe(sessionID: "row", identity: identity, principal: principal,
            slackThread: "100.1", paneID: "%1", rootPID: 100, footprint: "first"))
        journal.invalidateSession("row")
        _ = try journal.observe(sessionID: "other", identity: identity, principal: principal,
            slackThread: "100.2", paneID: "%2", rootPID: 101, footprint: "other")
        #expect(!journal.fence.contains(first.id))
        let reopened = try #require(try journal.observe(sessionID: "row", identity: identity, principal: principal,
            slackThread: "100.1", paneID: "%1", rootPID: 100, footprint: "first"))
        #expect(reopened.id != first.id && journal.fence.contains(reopened.id))
        #expect(throws: SlackDecisionJournal.Failure.self) {
            try journal.claim(operationID: "old-action", principal: principal, request: first, option: 1)
        }
    }
}
