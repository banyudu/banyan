import BanyanCore
import Foundation
import Network
import Testing
@testable import Banyan

@MainActor
@Suite struct StartupResumeRecoveryTests {
    @Test func launchRecreatesExactCodexAndClaudeConversationsInBackground() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let backend = StartupResumeTestBackend()
        let now = Date()
        let codexID = "11111111-2222-3333-4444-555555555555"
        let claudeID = "claude-session-saved"
        fixture.persistence.save([
            SessionSnapshot(
                id: "codex-active", tmuxSessionName: "banyan-codex-active",
                title: "Codex work", reportedTitle: nil, cwd: fixture.project.path,
                command: "'codex' 'Original codex prompt'", status: .needInput,
                tone: .blue, agentSessionID: codexID, createdAt: now, updatedAt: now
            ),
            SessionSnapshot(
                id: "claude-active", tmuxSessionName: "banyan-claude-active",
                title: "Claude work", reportedTitle: nil, cwd: fixture.project.path,
                command: "'claude' 'Original claude prompt'", status: .executing,
                tone: .purple, agentSessionID: claudeID, createdAt: now, updatedAt: now
            )
        ])

        let history = DefaultSessionHistoryBackend(homeDirectory: fixture.home)
        var server: ControlServer?
        let store = fixture.makeStore(
            historyBackend: history,
            tmuxBackend: backend,
            sessionBackend: backend,
            makeControlServer: { store, host in
                let created = ControlServer(store: store, host: host, port: NWEndpoint.Port.any)
                server = created
                return created
            }
        )
        defer {
            server?.stop()
            store.stopPuckObservation()
            store.flushPendingSessionSaves()
        }

        store.startRuntimeIfNeeded()

        let expectedCodex = try #require(AgentSessionHistory.resumeCommand(
            provider: .codex, sourceID: codexID, cwd: fixture.project.path
        ))
        let expectedClaude = try #require(AgentSessionHistory.resumeCommand(
            provider: .claude, sourceID: claudeID, cwd: fixture.project.path
        ))
        let codex = try #require(store.sessions.first { $0.id == "codex-active" } as? TerminalSession)
        let claude = try #require(store.sessions.first { $0.id == "claude-active" } as? TerminalSession)
        #expect(codex.command == expectedCodex)
        #expect(claude.command == expectedClaude)
        #expect(!codex.needsRecovery && !claude.needsRecovery)

        try await waitForPuckState { Set(backend.launched) == Set([expectedCodex, expectedClaude]) }
        #expect(Set(backend.launchedNames) == Set(["banyan-codex-active", "banyan-claude-active"]))
        #expect(backend.launched.allSatisfy { !$0.contains("Original") })
        #expect(backend.launchedThemeStyles.count == 2)
        #expect(backend.launchedThemeStyles.allSatisfy { $0?.contains("fg=#") == true })
        #expect(store.autoRecoverRestoredAgentSessionsIfNeeded().isEmpty)
        #expect(backend.launched.count == 2)
    }

    @Test func launchLeavesUnsafeOrUnauthorizedRowsForManualRecovery() throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let backend = StartupResumeTestBackend()
        let now = Date()
        let missingFolder = fixture.root.appendingPathComponent("missing-project").path
        fixture.persistence.save([
            SessionSnapshot(
                id: "no-id", tmuxSessionName: "banyan-no-id", title: "No ID",
                reportedTitle: nil, cwd: fixture.project.path, command: "'codex'",
                status: .running, tone: .blue, createdAt: now, updatedAt: now
            ),
            SessionSnapshot(
                id: "completed", tmuxSessionName: "banyan-completed", title: "Completed",
                reportedTitle: nil, cwd: fixture.project.path, command: "'codex'",
                status: .completed, tone: .green, agentSessionID: "completed-id",
                createdAt: now, updatedAt: now
            ),
            SessionSnapshot(
                id: "failed", tmuxSessionName: "banyan-failed", title: "Failed",
                reportedTitle: nil, cwd: fixture.project.path, command: "'claude'",
                status: .failed, tone: .red, agentSessionID: "failed-id",
                createdAt: now, updatedAt: now
            ),
            SessionSnapshot(
                id: "missing-folder", tmuxSessionName: "banyan-missing-folder", title: "Missing folder",
                reportedTitle: nil, cwd: missingFolder, command: "'codex'",
                status: .running, tone: .blue, agentSessionID: "missing-folder-id",
                createdAt: now, updatedAt: now
            ),
            SessionSnapshot(
                id: "parked", tmuxSessionName: "banyan-parked", title: "Parked",
                reportedTitle: nil, cwd: fixture.project.path, command: "'codex'",
                status: .needInput, tone: .blue, agentSessionID: "parked-id",
                isSuspended: true, createdAt: now, updatedAt: now
            )
        ])

        let store = fixture.makeStore(tmuxBackend: backend, sessionBackend: backend)
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        #expect(store.autoRecoverRestoredAgentSessionsIfNeeded().isEmpty)

        #expect(backend.launched.isEmpty)
        #expect(Set(store.recoverySessions.map(\.id)) == Set([
            "no-id", "completed", "failed", "missing-folder", "parked"
        ]))
        #expect(store.autoRecoverRestoredAgentSessionsIfNeeded().isEmpty)
        #expect(backend.launched.isEmpty)
    }
}

private final class StartupResumeTestBackend: TmuxSessionStoreBackend, TmuxClientBackend, @unchecked Sendable {
    var launched: [String] = []
    var launchedNames: [String] = []
    var launchedThemeStyles: [String?] = []
    var executableURL: URL { URL(fileURLWithPath: "/usr/bin/false") }

    func attachArguments(for name: String) -> [String] { [] }
    func hasSession(named name: String) -> Bool { false }
    func agentAdmissionPane(named name: String) -> AgentAdmissionPaneInspection { .absent }
    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? { nil }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String { "" }
    func captureCurrentVisibleText(paneID: String) -> String { "" }
    func listBanyanSessions() -> [String] { [] }
    func ensureSession(named name: String, cwd: String, command: String, banyanSessionID: String?) throws {
        try ensureSession(SessionLaunchRequest(
            sessionName: name,
            cwd: cwd,
            command: command,
            banyanSessionID: banyanSessionID
        ))
    }
    func ensureSession(_ request: SessionLaunchRequest) throws {
        launchedNames.append(request.sessionName)
        launched.append(request.command)
        launchedThemeStyles.append(request.terminalThemeStyle)
    }
    func killSession(named name: String) {}
    func sendKeys(paneID: String, keys: [TmuxKey]) throws {}
    func sendLiteral(paneID: String, text: String) throws {}
    func configureTerminalTheme(style: String, for sessionName: String?) {}
    func refreshClients(attachedTo name: String) {}
    func scrollHistory(paneID: String, lines: Int, up: Bool, onScrollPosition: (@Sendable (Int) -> Void)?) {}
}
