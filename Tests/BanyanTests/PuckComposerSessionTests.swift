import AppKit
import BanyanCore
import Foundation
import Testing
@testable import Banyan

/// Queueing, image attachments, compaction and feedback denials on a Puck
/// session, against the in-memory daemon.
@MainActor
struct PuckComposerSessionTests {
    private func openSession(_ summary: PuckSessionSummary, daemon: FakePuckDaemon) throws -> (PuckStoreFixture, SessionStore, PuckSession) {
        let fixture = try PuckStoreFixture(daemon: daemon)
        let store = fixture.makeStore()
        daemon.put(summary)
        store.openListedPuckSessions([summary])
        let session = try #require(store.sessions.first as? PuckSession)
        return (fixture, store, session)
    }

    @Test func messagesSentDuringATurnQueueAndGoOutWhenItSettles() async throws {
        let daemon = FakePuckDaemon()
        let root = FileManager.default.temporaryDirectory.path
        let running = puckSummary(cwd: root, position: "running")
        let (fixture, store, session) = try openSession(running, daemon: daemon)
        _ = fixture

        session.draft = "Then update the changelog"
        session.send(session.draft)
        session.send("And run the tests")
        #expect(session.draft.isEmpty)
        #expect(session.queuedPrompts.map(\.text) == ["Then update the changelog", "And run the tests"])
        #expect(daemon.turns.isEmpty)

        let idle = running.with(position: "idle")
        daemon.put(idle)
        store.applyPuckSummaries([idle])
        try await waitForPuckState { daemon.turns.count == 1 }
        #expect(daemon.turns.map(\.prompt) == ["Then update the changelog"])
        #expect(session.queuedPrompts.map(\.text) == ["And run the tests"])

        // The fake marks the session running when it accepts the turn; the
        // second message waits for that turn too.
        let settled = running.with(position: "idle", historyItems: 2)
        daemon.put(settled)
        try await waitForPuckState { !session.admissionTurnInFlight && !session.queueDispatchInFlight }
        store.applyPuckSummaries([settled])
        try await waitForPuckState { daemon.turns.count == 2 }
        #expect(daemon.turns.map(\.prompt) == ["Then update the changelog", "And run the tests"])
        #expect(session.queuedPrompts.isEmpty)
    }

    @Test func stoppingATurnReturnsQueuedMessagesToTheComposer() async throws {
        let daemon = FakePuckDaemon()
        let running = puckSummary(cwd: FileManager.default.temporaryDirectory.path, position: "running")
        let (fixture, _, session) = try openSession(running, daemon: daemon)
        _ = fixture

        session.send("Try the other parser")
        session.draft = "draft in progress"
        session.cancel()
        try await waitForPuckState { daemon.cancellations.count == 1 && !session.cancelInFlight }

        #expect(session.queuedPrompts.isEmpty)
        #expect(session.draft == "Try the other parser\n\ndraft in progress")
        #expect(daemon.turns.isEmpty)
    }

    @Test func codexFeedbackDenialStopsTheTurnAndSendsTheFeedbackNext() async throws {
        let daemon = FakePuckDaemon()
        let approval = PuckPendingApproval(callID: "approval-1", tool: "exec_command",
                                           arguments: #"{"command":"rm -rf build"}"#, expiresAtMS: 0)
        let parked = puckSummary(engine: "codex", cwd: FileManager.default.temporaryDirectory.path,
                                 position: "parked", pendingApproval: approval)
        let (fixture, _, session) = try openSession(parked, daemon: daemon)
        _ = fixture

        session.denyWithFeedback("Use make clean instead")
        try await waitForPuckState { daemon.turns.count == 1 }
        #expect(daemon.decisions == ["deny"])
        #expect(daemon.decisionReasons == ["Use make clean instead"])
        #expect(daemon.cancellations.count == 1)
        #expect(daemon.turns.map(\.prompt) == ["Use make clean instead"])
        #expect(session.draft.isEmpty)
    }

    @Test func nativeFeedbackDenialPassesTheReasonWithoutStoppingTheTurn() async throws {
        let daemon = FakePuckDaemon()
        let approval = PuckPendingApproval(callID: "approval-1", tool: "exec_command",
                                           arguments: #"{"cmd":"rm -rf build"}"#, expiresAtMS: 0)
        let parked = puckSummary(engine: "native", cwd: FileManager.default.temporaryDirectory.path,
                                 position: "parked", pendingApproval: approval)
        let (fixture, _, session) = try openSession(parked, daemon: daemon)
        _ = fixture

        session.denyWithFeedback("Use make clean instead")
        try await waitForPuckState { daemon.decisions.count == 1 && !session.decisionInFlight }
        #expect(daemon.decisionReasons == ["Use make clean instead"])
        #expect(daemon.cancellations.isEmpty)
        #expect(daemon.turns.isEmpty)
        #expect(session.queuedPrompts.isEmpty)
    }

    @Test func imagesAttachOnlyWhenTheDaemonAndEngineTakeThem() async throws {
        let daemon = FakePuckDaemon()
        daemon.capabilitiesResult = try puckImageCapabilities()
        let idle = puckSummary(engine: "codex", cwd: FileManager.default.temporaryDirectory.path)
        let (fixture, _, session) = try openSession(idle, daemon: daemon)
        let image = fixture.root.appendingPathComponent("screen.png")
        try Self.pngData().write(to: image)

        session.startFollowing()
        try await waitForPuckState { session.acceptsImages }
        session.attachImageFile(image)
        session.attachImage(pngData: Self.pngData())
        #expect(session.draftImages.count == 2)
        let staged = try #require(session.draftImages.last)
        #expect(staged.isStaged && FileManager.default.fileExists(atPath: staged.path))

        session.send("What changed in this screenshot?")
        #expect(session.draftImages.isEmpty)
        #expect(session.timeline.items.last?.images == [image.path, staged.path])
        try await waitForPuckState { daemon.turns.count == 1 && !session.admissionTurnInFlight }
        #expect(daemon.turns.first?.images == [image.path, staged.path])
        try await waitForPuckState { !FileManager.default.fileExists(atPath: staged.path) }
        #expect(FileManager.default.fileExists(atPath: image.path))
        session.stopFollowing()
    }

    @Test func nativeSessionsRefuseImagesWithAReason() async throws {
        let daemon = FakePuckDaemon()
        daemon.capabilitiesResult = try puckImageCapabilities()
        let idle = puckSummary(engine: "native", cwd: FileManager.default.temporaryDirectory.path)
        let (fixture, _, session) = try openSession(idle, daemon: daemon)
        _ = fixture

        session.startFollowing()
        try await waitForPuckState { session.daemonCapabilities != nil }
        session.attachImage(pngData: Self.pngData())
        #expect(session.draftImages.isEmpty)
        #expect(session.daemonError?.contains("Codex-engine") == true)
        session.stopFollowing()
    }

    @Test func compactRunsInPuckdAndReportsWhenItSettles() async throws {
        let daemon = FakePuckDaemon()
        let idle = puckSummary(engine: "codex", cwd: FileManager.default.temporaryDirectory.path)
        let (fixture, _, session) = try openSession(idle, daemon: daemon)
        _ = fixture

        session.compact()
        try await waitForPuckState { daemon.compactions.count == 1 && !session.compactInFlight }
        #expect(session.infoNotice == "Conversation compacted.")
    }

    @Test func slashCommandsMatchWholeWordsOnly() {
        #expect(PuckSlashCommand.suggestions(for: "/co") == [.compact, .copy])
        #expect(PuckSlashCommand.suggestions(for: "/") == PuckSlashCommand.allCases)
        #expect(PuckSlashCommand.suggestions(for: "/compact now").isEmpty)
        #expect(PuckSlashCommand.exact(" /Compact \n") == .compact)
        #expect(PuckSlashCommand.exact("/Users/example/project") == nil)
    }

    static func pngData() -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return bitmap.representation(using: .png, properties: [:])!
    }
}
