import Foundation
import Testing
@testable import Banyan

@Test func importsCodexSessionIndexRowsWithMetadata() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let id = "019efe8d-0514-72a2-ad62-daea0b976dcf"
    let codex = home.appendingPathComponent(".codex")
    let sessionDirectory = codex.appendingPathComponent("sessions/2026/07/01")
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

    try write(
        #"{"id":"\#(id)","thread_name":"Implement history sidebar","updated_at":"2026-07-01T10:05:00.123Z"}"#,
        to: codex.appendingPathComponent("session_index.jsonl")
    )
    try write(
        [
            #"{"timestamp":"2026-07-01T10:00:00.000Z","type":"session_meta","payload":{"session_id":"\#(id)","cwd":"/tmp/banyan-codex","timestamp":"2026-07-01T10:00:00.000Z"}}"#,
            ##"{"timestamp":"2026-07-01T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /tmp/banyan-codex"}]}}"##,
            #"{"timestamp":"2026-07-01T10:00:10.000Z","type":"event_msg","payload":{"type":"user_message","message":"Use the first prompt as the sidebar title\n\nIgnore the generated thread name."}}"#
        ].joined(separator: "\n"),
        to: sessionDirectory.appendingPathComponent("rollout-2026-07-01T10-00-00-\(id).jsonl")
    )

    let imported = AgentSessionHistoryImporter.load(homeDirectory: home, maxPerProvider: 10)

    let session = try #require(imported.first { $0.id == "history-codex-\(id)" })
    #expect(session.provider == .codex)
    #expect(session.title == "Use the first prompt as the sidebar title")
    #expect(session.cwd == "/tmp/banyan-codex")
}

@Test func importsRecentCodexTranscriptWhenIndexIsMissing() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let id = "019efe8d-0514-72a2-ad62-daea0b976dcf"
    let sessionDirectory = home.appendingPathComponent(".codex/sessions/2026/07/01")
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    try write(
        [
            #"{"timestamp":"2026-07-01T10:00:00.000Z","type":"session_meta","payload":{"session_id":"\#(id)","cwd":"/tmp/banyan-codex","timestamp":"2026-07-01T10:00:00.000Z"}}"#,
            #"{"timestamp":"2026-07-01T10:00:10.000Z","type":"event_msg","payload":{"type":"user_message","message":"Import transcript files even without an index"}}"#
        ].joined(separator: "\n"),
        to: sessionDirectory.appendingPathComponent("rollout-2026-07-01T10-00-00-\(id).jsonl")
    )

    let imported = AgentSessionHistoryImporter.load(homeDirectory: home, maxPerProvider: 10)

    let session = try #require(imported.first { $0.id == "history-codex-\(id)" })
    #expect(session.title == "Import transcript files even without an index")
    #expect(session.cwd == "/tmp/banyan-codex")
}

@Test func codexTranscriptTitleUsesPromptAfterLatestClearOrNew() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let id = "019efe8d-0514-72a2-ad62-daea0b976dcf"
    let sessionDirectory = home.appendingPathComponent(".codex/sessions/2026/07/01")
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    try write(
        [
            #"{"timestamp":"2026-07-01T10:00:00.000Z","type":"session_meta","payload":{"session_id":"\#(id)","cwd":"/tmp/banyan-codex","timestamp":"2026-07-01T10:00:00.000Z"}}"#,
            #"{"timestamp":"2026-07-01T10:00:10.000Z","type":"event_msg","payload":{"type":"user_message","message":"Old sidebar title"}}"#,
            #"{"timestamp":"2026-07-01T10:05:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"/clear"}}"#,
            #"{"timestamp":"2026-07-01T10:05:20.000Z","type":"event_msg","payload":{"type":"user_message","message":"New sidebar title after clear"}}"#,
            #"{"timestamp":"2026-07-01T10:10:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"/new"}}"#,
            #"{"timestamp":"2026-07-01T10:10:20.000Z","type":"event_msg","payload":{"type":"user_message","message":"Newest sidebar title after new"}}"#
        ].joined(separator: "\n"),
        to: sessionDirectory.appendingPathComponent("rollout-2026-07-01T10-00-00-\(id).jsonl")
    )

    let imported = AgentSessionHistoryImporter.load(homeDirectory: home, maxPerProvider: 10)

    let session = try #require(imported.first { $0.id == "history-codex-\(id)" })
    #expect(session.title == "Newest sidebar title after new")
}

@Test func importsClaudeProjectLogsFromFirstHumanPrompt() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let projects = home.appendingPathComponent(".claude/projects/-tmp-banyan-claude")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let transcript = projects.appendingPathComponent("867ceb9b-12de-47ff-a70e-e562c00c8bf5.jsonl")
    try write(
        [
            #"{"type":"mode","mode":"normal","sessionId":"867ceb9b-12de-47ff-a70e-e562c00c8bf5"}"#,
            #"{"type":"user","message":{"role":"user","content":"Add imported sessions to the sidebar\n\nKeep tmux sessions separate."},"timestamp":"2026-07-01T11:00:00.000Z","cwd":"/tmp/banyan-claude","sessionId":"867ceb9b-12de-47ff-a70e-e562c00c8bf5"}"#
        ].joined(separator: "\n"),
        to: transcript
    )

    let imported = AgentSessionHistoryImporter.load(homeDirectory: home, maxPerProvider: 10)

    let session = try #require(imported.first { $0.id == "history-claude-867ceb9b-12de-47ff-a70e-e562c00c8bf5" })
    #expect(session.provider == .claude)
    #expect(session.title == "Add imported sessions to the sidebar")
    #expect(session.cwd == "/tmp/banyan-claude")
}

@Test func claudeTranscriptTitleUsesPromptAfterLatestClearOrNew() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let projects = home.appendingPathComponent(".claude/projects/-tmp-banyan-claude")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let transcript = projects.appendingPathComponent("867ceb9b-12de-47ff-a70e-e562c00c8bf5.jsonl")
    try write(
        [
            #"{"type":"user","message":{"role":"user","content":"Old Claude title"},"timestamp":"2026-07-01T11:00:00.000Z","cwd":"/tmp/banyan-claude","sessionId":"867ceb9b-12de-47ff-a70e-e562c00c8bf5"}"#,
            #"{"type":"user","message":{"role":"user","content":"/clear"},"timestamp":"2026-07-01T11:05:00.000Z","cwd":"/tmp/banyan-claude","sessionId":"867ceb9b-12de-47ff-a70e-e562c00c8bf5"}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Claude title after clear"}]},"timestamp":"2026-07-01T11:05:20.000Z","cwd":"/tmp/banyan-claude","sessionId":"867ceb9b-12de-47ff-a70e-e562c00c8bf5"}"#,
            #"{"type":"user","message":{"role":"user","content":"/new"},"timestamp":"2026-07-01T11:10:00.000Z","cwd":"/tmp/banyan-claude","sessionId":"867ceb9b-12de-47ff-a70e-e562c00c8bf5"}"#,
            #"{"type":"user","message":{"role":"user","content":"Newest Claude title after new"},"timestamp":"2026-07-01T11:10:20.000Z","cwd":"/tmp/banyan-claude","sessionId":"867ceb9b-12de-47ff-a70e-e562c00c8bf5"}"#
        ].joined(separator: "\n"),
        to: transcript
    )

    let imported = AgentSessionHistoryImporter.load(homeDirectory: home, maxPerProvider: 10)

    let session = try #require(imported.first { $0.id == "history-claude-867ceb9b-12de-47ff-a70e-e562c00c8bf5" })
    #expect(session.title == "Newest Claude title after new")
}

@Test func transcriptPreviewExtractsReadableClaudeMessages() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let transcript = home.appendingPathComponent("claude.jsonl")
    try write(
        [
            #"{"type":"user","message":{"role":"user","content":"Please inspect the app."}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will inspect the sidebar."}]}}"#
        ].joined(separator: "\n"),
        to: transcript
    )

    let preview = AgentSessionHistoryImporter.transcriptPreview(from: transcript, provider: .claude)

    #expect(preview.contains("User: Please inspect the app."))
    #expect(preview.contains("Assistant: I will inspect the sidebar."))
}

@Test func resumeCommandsUseProviderNativeResumeSyntax() {
    let codex = AgentSessionHistoryImporter.resumeCommand(
        provider: .codex,
        sourceID: "019efe8d-0514-72a2-ad62-daea0b976dcf",
        cwd: "/tmp/project with spaces",
        prompt: "continue here"
    )
    let claude = AgentSessionHistoryImporter.resumeCommand(
        provider: .claude,
        sourceID: "867ceb9b-12de-47ff-a70e-e562c00c8bf5",
        cwd: "/tmp/project",
        prompt: "continue here"
    )

    #expect(codex == "'codex' 'resume' '-C' '/tmp/project with spaces' '019efe8d-0514-72a2-ad62-daea0b976dcf' 'continue here'")
    #expect(claude == "'claude' '--resume' '867ceb9b-12de-47ff-a70e-e562c00c8bf5' 'continue here'")
}

private func makeTemporaryHome() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("banyan-history-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
}
