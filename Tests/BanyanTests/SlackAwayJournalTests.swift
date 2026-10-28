import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

@Suite(.serialized)
@MainActor
struct SlackAwayJournalTests {
    private let principal = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_TEST", user: "U_TEST")

    @Test func scopeAndCheckpointPersistAndRepeatedEnableIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("away_state_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("away.json")
        let journal = SlackAwayJournal(file: file)
        let epoch = UUID().uuidString
        #expect(throws: SlackAwayJournal.Failure.self) {
            try journal.configure(principal: principal, enabled: true, sessionID: nil, projectID: nil, follow: nil, epoch: epoch, cursor: 5)
        }
        _ = try journal.configure(principal: principal, enabled: nil, sessionID: "row", projectID: nil, follow: true, epoch: epoch, cursor: 5)
        let enabled = try journal.configure(principal: principal, enabled: true, sessionID: nil, projectID: nil, follow: nil, epoch: epoch, cursor: 7)
        #expect(enabled.enabled && enabled.checkpointEpoch == epoch && enabled.checkpointCursor == 7)
        let repeated = try journal.configure(principal: principal, enabled: true, sessionID: nil, projectID: nil, follow: nil, epoch: epoch, cursor: 9)
        #expect(repeated.activationID == enabled.activationID && repeated.checkpointCursor == 7)
        let restarted = SlackAwayJournal(file: file)
        #expect(try restarted.status(principal: principal) == enabled)
        let changed = try restarted.configure(principal: principal, enabled: nil, sessionID: nil, projectID: "project", follow: true, epoch: epoch, cursor: 10)
        #expect(changed.activationID != enabled.activationID && changed.checkpointCursor == 10)
        let off = try restarted.configure(principal: principal, enabled: false, sessionID: nil, projectID: nil, follow: nil, epoch: epoch, cursor: 11)
        #expect(!off.enabled && off.sessionIDs == ["row"] && off.projectIDs == ["project"])
        #expect(!restarted.includes(sessionID: "row", projectID: "project", principal: principal))
        let other = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_OTHER", user: "U_TEST")
        #expect(throws: SlackAwayJournal.Failure.self) { try restarted.status(principal: other) }
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func corruptAwayStateFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("away_corrupt_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("away.json")
        try Data("not-json".utf8).write(to: file)
        let journal = SlackAwayJournal(file: file)
        #expect(journal.storageError != nil)
        #expect(throws: SlackAwayJournal.Failure.self) { try journal.status(principal: principal) }
    }

    @Test func removingTheAuthorizedChannelClearsItsScopeButDisableKeepsIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("away_channel_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SlackAwayJournal(file: directory.appendingPathComponent("away.json"))
        let epoch = UUID().uuidString
        _ = try journal.configure(principal: principal, enabled: nil, sessionID: "row", projectID: nil, follow: true, epoch: epoch, cursor: 1)
        let active = try journal.configure(principal: principal, enabled: true, sessionID: nil, projectID: nil, follow: nil, epoch: epoch, cursor: 2)
        try journal.resetIfChannelRemoved(allowed: [principal])
        #expect(try journal.status(principal: principal) == active)
        let other = CodexRemotePrincipal(workspace: "T_TEST", channel: "C_OTHER", user: "U_TEST")
        try journal.resetIfChannelRemoved(allowed: [other])
        let empty = try journal.status(principal: other)
        #expect(!empty.enabled && empty.sessionIDs.isEmpty && empty.projectIDs.isEmpty)
        let followed = try journal.configure(principal: other, enabled: nil, sessionID: "new-row", projectID: nil, follow: true, epoch: epoch, cursor: 3)
        #expect(followed.sessionIDs == ["new-row"] && followed.channel == "C_OTHER")
    }
}
