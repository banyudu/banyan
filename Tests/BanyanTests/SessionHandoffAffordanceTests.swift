import AppKit
import BanyanCore
import Foundation
import Testing
@testable import Banyan

/// The worktree handoff affordance (the sidebar button and ⇧⌥⌘H) needs both
/// halves: the "Show the worktree handoff action" preference, off by default,
/// and an installed handoff executable. Installing the command used to be the
/// whole switch, which left the button in every eligible row for people who had
/// moved off the workflow.
@MainActor
@Suite struct SessionHandoffAffordanceTests {
    @Test func installingACommandIsNotEnoughOnItsOwn() throws {
        let fixture = try HandoffAffordanceFixture()
        let store = fixture.makeStore()

        #expect(store.enableHandoffAction == false)
        #expect(!store.isHandoffAvailable)
    }

    @Test func enablingThePreferenceRevealsAnInstalledCommand() throws {
        let fixture = try HandoffAffordanceFixture()
        let store = fixture.makeStore()

        store.enableHandoffAction = true
        #expect(store.isHandoffAvailable)

        store.enableHandoffAction = false
        #expect(!store.isHandoffAvailable)
    }

    @Test func enablingThePreferenceWithoutACommandStaysHidden() throws {
        let fixture = try HandoffAffordanceFixture(installsCommand: false)
        let store = fixture.makeStore()

        store.enableHandoffAction = true

        #expect(!store.isHandoffAvailable)
    }

    @Test func thePreferenceSurvivesARelaunch() throws {
        let fixture = try HandoffAffordanceFixture()
        let store = fixture.makeStore()
        store.enableHandoffAction = true

        // A second store over the same state is the relaunch: the saved
        // preference has to bring the affordance back without being re-toggled.
        let relaunched = fixture.makeStore()

        #expect(relaunched.enableHandoffAction)
        #expect(relaunched.isHandoffAvailable)
    }

    @Test func theShortcutStaysSilentWhileThePreferenceIsOff() throws {
        let fixture = try HandoffAffordanceFixture()
        let store = fixture.makeStore()

        store.handleHandoffShortcut()

        // Nothing dispatched, and no "install ~/bin/handoff" notice for a
        // workflow the user deliberately turned off.
        #expect(store.handoffNotice == nil)
        #expect(store.pendingHandoffJobs.isEmpty)
    }

    @Test func theShortcutStillExplainsAMissingCommandWhenEnabled() throws {
        let fixture = try HandoffAffordanceFixture(installsCommand: false)
        let store = fixture.makeStore()
        store.enableHandoffAction = true

        store.handleHandoffShortcut()

        #expect(store.handoffNotice?.contains("Handoff is not configured") == true)
    }

    @Test func dispatchingIsRefusedWhileThePreferenceIsOff() throws {
        let fixture = try HandoffAffordanceFixture()
        let store = fixture.makeStore()

        #expect(!store.dispatchHandoff(id: "any-session", bypassEligibility: true))
        #expect(store.pendingHandoffJobs.isEmpty)
    }
}

@MainActor
private struct HandoffAffordanceFixture {
    let root: URL
    let home: URL
    let project: URL
    let persistence: SessionPersistence
    private let commandPath: String

    init(installsCommand: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("banyan-handoff-affordance-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        persistence = SessionPersistence(
            databaseURL: root.appendingPathComponent("state.sqlite"),
            legacyJSONURL: root.appendingPathComponent("sessions.json")
        )

        let command = home.appendingPathComponent("handoff")
        if installsCommand {
            try "#!/bin/sh\nexit 0\n".write(to: command, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: command.path
            )
        }
        commandPath = command.path
    }

    func makeStore() -> SessionStore {
        // The store reads `NSApp` for its background-refresh budget, which is nil
        // in a test process until the shared application exists.
        _ = NSApplication.shared
        return SessionStore(
            persistence: persistence,
            tmuxBackend: banyanTestTmuxBackend,
            sessionBackend: banyanTestTmuxBackend,
            processTable: HandoffAffordanceTestProcessTable(),
            historyBackend: HandoffAffordanceTestHistoryBackend(),
            detector: AgentStateDetector(rules: []),
            host: HostRuntimeContext(
                environment: [
                    "HOME": home.path,
                    "PATH": "/usr/bin:/bin",
                    "SHELL": "/bin/zsh",
                    SessionHandoffPolicy.commandEnvironmentKey: commandPath
                ],
                homeDirectory: home,
                currentDirectory: project.path
            ),
            telemetry: banyanTestTelemetry,
            attentionNotifier: AttentionNotifier()
        )
    }
}

private struct HandoffAffordanceTestProcessTable: ProcessTableProvider {
    func snapshot() -> ProcessTable {
        ProcessTable(rows: [])
    }
}

private struct HandoffAffordanceTestHistoryBackend: SessionHistoryBackend {
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
