import AppKit
import BanyanCore
import Foundation
import Testing
@testable import Banyan

/// Closing a session always asks first — same list, same dialog. What differs
/// between backends is only what the confirmation says the close will do.

@MainActor
@Test func closingAFinishedPlainSessionStillAsksFirst() throws {
    let fixture = try ClosePromptFixture()
    let store = fixture.makeStore()
    store.loadPersistedSessionsIfNeeded()
    let session = try #require(store.sessions.first)
    #expect(session.status == .completed)

    // No running agent, no children — the close used to skip the dialog.
    store.requestClose(id: session.id)
    #expect(store.pendingCloseSession?.id == session.id)
    #expect(session.status == .completed)

    store.cancelPendingClose()
    #expect(store.pendingCloseSession == nil)
    #expect(session.status == .completed)

    store.requestClose(id: session.id)
    store.confirmPendingClose()
    #expect(store.pendingCloseSession == nil)
    #expect(session.status == .closed)
}

@MainActor
@Test func keyboardCloseShortcutConfirmsThePendingOrdinaryClose() throws {
    let fixture = try ClosePromptFixture()
    let store = fixture.makeStore()
    store.loadPersistedSessionsIfNeeded()
    let session = try #require(store.sessions.first)

    store.requestClose(id: session.id)
    #expect(store.pendingCloseSession?.id == session.id)

    store.confirmPendingCloseFromKeyboardShortcut()
    #expect(store.pendingCloseSession == nil)
    #expect(session.status == .closed)
}

@Test func closeConfirmationOnlyRequiresCommandForForceClose() {
    let ordinary = CloseConfirmationActionAvailability(
        isPausing: false, canPause: false, needsForce: false, commandHeld: false
    )
    #expect(!ordinary.primaryCloseDisabled)
    #expect(ordinary.primaryCloseIsDefault)
    #expect(!ordinary.backgroundIsDefault)

    let pause = CloseConfirmationActionAvailability(
        isPausing: false, canPause: true, needsForce: true, commandHeld: false
    )
    #expect(!pause.primaryCloseDisabled)
    #expect(pause.primaryCloseIsDefault)
    #expect(pause.forceCloseDisabled)
    #expect(!pause.backgroundIsDefault)

    let force = CloseConfirmationActionAvailability(
        isPausing: false, canPause: false, needsForce: true, commandHeld: false
    )
    #expect(force.forceCloseDisabled)
    #expect(!force.forceCloseIsDefault)
    #expect(force.backgroundIsDefault)

    let forceWithCommand = CloseConfirmationActionAvailability(
        isPausing: false, canPause: false, needsForce: true, commandHeld: true
    )
    #expect(!forceWithCommand.forceCloseDisabled)
    #expect(forceWithCommand.forceCloseIsDefault)
    #expect(!forceWithCommand.backgroundIsDefault)

    let pausing = CloseConfirmationActionAvailability(
        isPausing: true, canPause: true, needsForce: true, commandHeld: true
    )
    #expect(pausing.primaryCloseDisabled)
    #expect(pausing.forceCloseDisabled)
    #expect(pausing.backgroundIsDefault)
}

@MainActor
private struct ClosePromptFixture {
    let root: URL
    let project: URL
    let persistence: SessionPersistence

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("banyan-close-prompt-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        persistence = SessionPersistence(
            databaseURL: root.appendingPathComponent("state.sqlite"),
            legacyJSONURL: root.appendingPathComponent("sessions.json")
        )
        let now = Date()
        persistence.save([
            SessionSnapshot(
                id: "plain-shell",
                tmuxSessionName: "banyan-plain-shell",
                title: "~",
                reportedTitle: nil,
                cwd: project.path,
                command: "/bin/zsh -l",
                status: .completed,
                tone: .neutral,
                createdAt: now,
                updatedAt: now
            )
        ])
    }

    func makeStore() -> SessionStore {
        // The store reads `NSApp` for its background-refresh budget, which is nil
        // in a test process until the shared application exists.
        _ = NSApplication.shared
        return SessionStore(
            persistence: persistence,
            tmuxBackend: banyanTestTmuxBackend,
            sessionBackend: banyanTestTmuxBackend,
            processTable: ClosePromptTestProcessTable(),
            historyBackend: ClosePromptTestHistoryBackend(),
            detector: AgentStateDetector(rules: []),
            host: HostRuntimeContext(
                environment: [
                    "HOME": root.appendingPathComponent("home").path,
                    "PATH": "/usr/bin:/bin",
                    "SHELL": "/bin/zsh"
                ],
                homeDirectory: root.appendingPathComponent("home"),
                currentDirectory: project.path
            ),
            telemetry: banyanTestTelemetry,
            attentionNotifier: AttentionNotifier()
        )
    }
}

private struct ClosePromptTestProcessTable: ProcessTableProvider {
    func snapshot() -> ProcessTable {
        ProcessTable(rows: [])
    }
}

private struct ClosePromptTestHistoryBackend: SessionHistoryBackend {
    func load(maxPerProvider limit: Int) -> [ImportedAgentSession] { [] }

    func resumeCandidates(
        cwd: String,
        provider: CodingAgentProvider?,
        maxFilesScanned: Int
    ) -> [AgentResumeCandidate] {
        []
    }

    func sourceID(fromImportedSessionID id: String, provider: CodingAgentProvider) -> String? { nil }

    func resumeCommand(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        prompt: String?
    ) -> String? {
        nil
    }

    func prepareTrimmedTranscript(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        transcriptURL: URL?
    ) -> String? {
        nil
    }

    func transcriptPreview(from url: URL, provider: CodingAgentProvider, maxMessages: Int) -> String { "" }
}
