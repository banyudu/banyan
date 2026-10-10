import BanyanCore
import AppKit
import Foundation
import Testing
@testable import Banyan

/// An agent session's title comes from its own transcript, so the import that
/// reads it has to run even when nothing else announces the session. These
/// tests pin the triggers, because the failure they guard against is silent:
/// the session simply keeps a placeholder title forever.
@MainActor
@Test func launchImportTitlesAnUnmatchedCodexSessionFromItsTranscript() async throws {
    let fixture = try TitleImportFixture()
    let store = fixture.makeStore()
    store.loadPersistedSessionsIfNeeded()

    let session = try #require(store.sessions.first)
    #expect(session.agentSessionID == nil)
    #expect(fixture.history.loadCount == 0)

    store.refreshImportedHistoryIfNeeded()
    await fixture.waitForTitle(on: session)

    #expect(session.agentSessionID == "thread-1")
    #expect(session.displayTitle == "fix the sidebar title")
}

/// The regression: adoption used to hang off a *rename* in
/// `~/.codex/session_index.jsonl`. A session the agent never names writes no
/// row there, so an index refresh with nothing new must still import.
@MainActor
@Test func indexRefreshImportsWhenNoThreadWasRenamed() async throws {
    let fixture = try TitleImportFixture()
    let store = fixture.makeStore()
    store.loadPersistedSessionsIfNeeded()

    let session = try #require(store.sessions.first)
    store.refreshCodexTitlesFromIndex()
    await fixture.waitForTitle(on: session)

    #expect(session.agentSessionID == "thread-1")
    #expect(session.displayTitle == "fix the sidebar title")
}

/// A session that already carries the agent's own title, or a transcript id,
/// has nothing to gain from a transcript read — the import is not free.
@MainActor
@Test func matchedOrTitledSessionsDoNotAskForAnImport() async throws {
    let titled = try TitleImportFixture(reportedTitle: "already titled")
    let titledStore = titled.makeStore()
    titledStore.loadPersistedSessionsIfNeeded()
    titledStore.refreshImportedHistoryIfNeeded()
    #expect(titled.history.loadCount == 0)

    let matched = try TitleImportFixture(agentSessionID: "thread-known")
    let matchedStore = matched.makeStore()
    matchedStore.loadPersistedSessionsIfNeeded()
    matchedStore.refreshImportedHistoryIfNeeded()
    #expect(matched.history.loadCount == 0)
}

@MainActor
@Test(arguments: [false, true])
func launchImportRepairsSavedImageOnlyTitlesUnlessPinned(isTitlePinned: Bool) async throws {
    let fixture = try TitleImportFixture(
        reportedTitle: "<img>",
        agentSessionID: "thread-1",
        isTitlePinned: isTitlePinned
    )
    let store = fixture.makeStore()
    store.loadPersistedSessionsIfNeeded()
    let session = try #require(store.sessions.first)
    #expect(session.displayTitle == "<img>")

    store.refreshImportedHistoryIfNeeded()
    if isTitlePinned {
        #expect(fixture.history.loadCount == 0)
        #expect(session.displayTitle == "<img>")
    } else {
        await fixture.waitForTitle(on: session)
        #expect(fixture.history.loadCount == 1)
        #expect(session.displayTitle == "fix the sidebar title")
    }
}

@MainActor
private struct TitleImportFixture {
    let root: URL
    let home: URL
    let project: URL
    let persistence: SessionPersistence
    let history: StubTitleHistoryBackend
    let createdAt: Date

    init(reportedTitle: String? = nil, agentSessionID: String? = nil, isTitlePinned: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("banyan-title-import-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        project = root.appendingPathComponent("project")
        createdAt = Date()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        persistence = SessionPersistence(
            databaseURL: root.appendingPathComponent("state.sqlite"),
            legacyJSONURL: root.appendingPathComponent("sessions.json")
        )
        persistence.save([
            SessionSnapshot(
                id: "session-1",
                tmuxSessionName: "banyan-session-1",
                title: isTitlePinned ? (reportedTitle ?? "~") : "~",
                reportedTitle: reportedTitle,
                isTitlePinned: isTitlePinned,
                cwd: project.path,
                command: "codex -p my-profile",
                status: .needInput,
                tone: .blue,
                agentSessionID: agentSessionID,
                createdAt: createdAt,
                updatedAt: createdAt
            )
        ])
        history = StubTitleHistoryBackend(
            imported: [
                ImportedAgentSession(
                    id: "history-codex-thread-1",
                    provider: .codex,
                    sourceID: "thread-1",
                    title: "fix the sidebar title",
                    segmentPromptTitle: "fix the sidebar title",
                    cwd: project.path,
                    transcriptURL: project.appendingPathComponent("rollout-thread-1.jsonl"),
                    createdAt: createdAt,
                    updatedAt: createdAt
                )
            ]
        )
    }

    func makeStore() -> SessionStore {
        // The store reads `NSApp` for its background-refresh budget, which is nil
        // in a test process until the shared application exists.
        _ = NSApplication.shared
        return SessionStore(
            persistence: persistence,
            tmuxBackend: banyanTestTmuxBackend,
            sessionBackend: banyanTestTmuxBackend,
            processTable: EmptyTitleImportProcessTable(),
            historyBackend: history,
            detector: AgentStateDetector(rules: []),
            host: HostRuntimeContext(
                environment: [
                    "HOME": home.path,
                    "PATH": "/usr/bin:/bin",
                    "SHELL": "/bin/zsh"
                ],
                homeDirectory: home,
                currentDirectory: project.path
            ),
            telemetry: banyanTestTelemetry,
            attentionNotifier: AttentionNotifier()
        )
    }

    /// The import runs off the main actor, so give it a beat to land. Bounded,
    /// like the app's own waits: a broken trigger must fail, not hang.
    func waitForTitle(on session: BanyanSession) async {
        let deadline = Date().addingTimeInterval(5)
        while session.displayTitle != "fix the sidebar title", Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct EmptyTitleImportProcessTable: ProcessTableProvider {
    func snapshot() -> ProcessTable {
        ProcessTable(rows: [])
    }
}

private final class StubTitleHistoryBackend: SessionHistoryBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let imported: [ImportedAgentSession]
    private var loads = 0

    init(imported: [ImportedAgentSession]) {
        self.imported = imported
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads
    }

    func load(maxPerProvider limit: Int) -> [ImportedAgentSession] {
        lock.lock()
        loads += 1
        lock.unlock()
        return imported
    }

    func resumeCandidates(
        cwd: String,
        provider: CodingAgentProvider?,
        maxFilesScanned: Int
    ) -> [AgentResumeCandidate] {
        []
    }

    func sourceID(fromImportedSessionID id: String, provider: CodingAgentProvider) -> String? {
        nil
    }

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

    func transcriptPreview(
        from url: URL,
        provider: CodingAgentProvider,
        maxMessages: Int
    ) -> String {
        ""
    }
}
