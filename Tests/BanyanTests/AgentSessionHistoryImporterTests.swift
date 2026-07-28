import Foundation
import BanyanCore
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
    #expect(session.segmentPromptTitle == "Newest sidebar title after new")
}

@Test func codexTranscriptClearedWithoutNewPromptHasNoSegmentTitle() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let id = "019efe8d-0514-72a2-ad62-daea0b976dcf"
    let sessionDirectory = home.appendingPathComponent(".codex/sessions/2026/07/01")
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    try write(
        [
            #"{"timestamp":"2026-07-01T10:00:00.000Z","type":"session_meta","payload":{"session_id":"\#(id)","cwd":"/tmp/banyan-codex","timestamp":"2026-07-01T10:00:00.000Z"}}"#,
            #"{"timestamp":"2026-07-01T10:00:10.000Z","type":"event_msg","payload":{"type":"user_message","message":"Old sidebar title"}}"#,
            #"{"timestamp":"2026-07-01T10:05:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"/clear"}}"#
        ].joined(separator: "\n"),
        to: sessionDirectory.appendingPathComponent("rollout-2026-07-01T10-00-00-\(id).jsonl")
    )

    let imported = AgentSessionHistoryImporter.load(homeDirectory: home, maxPerProvider: 10)

    let session = try #require(imported.first { $0.id == "history-codex-\(id)" })
    // Display title keeps the pre-clear prompt as a fallback for the sidebar,
    // but the current segment has no prompt yet, so live sessions won't
    // resurrect the stale title onto a freshly cleared conversation.
    #expect(session.title == "Old sidebar title")
    #expect(session.segmentPromptTitle == nil)
    // A reset with no prompt since lets live sessions actively drop the stale
    // title, even when the keystroke path missed the /clear.
    #expect(session.segmentWasCleared)
}

@Test func codexTranscriptWithPromptAfterClearIsNotMarkedCleared() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let id = "019efe8d-0514-72a2-ad62-daea0b976aaa"
    let sessionDirectory = home.appendingPathComponent(".codex/sessions/2026/07/01")
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    try write(
        [
            #"{"timestamp":"2026-07-01T10:00:00.000Z","type":"session_meta","payload":{"session_id":"\#(id)","cwd":"/tmp/banyan-codex","timestamp":"2026-07-01T10:00:00.000Z"}}"#,
            #"{"timestamp":"2026-07-01T10:00:10.000Z","type":"event_msg","payload":{"type":"user_message","message":"Old sidebar title"}}"#,
            #"{"timestamp":"2026-07-01T10:05:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"/clear"}}"#,
            #"{"timestamp":"2026-07-01T10:05:20.000Z","type":"event_msg","payload":{"type":"user_message","message":"Fresh title after clear"}}"#
        ].joined(separator: "\n"),
        to: sessionDirectory.appendingPathComponent("rollout-2026-07-01T10-00-00-\(id).jsonl")
    )

    let imported = AgentSessionHistoryImporter.load(homeDirectory: home, maxPerProvider: 10)

    let session = try #require(imported.first { $0.id == "history-codex-\(id)" })
    #expect(session.segmentPromptTitle == "Fresh title after clear")
    // A prompt after the reset re-titles the segment, so it is not "cleared".
    #expect(session.segmentWasCleared == false)
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
    #expect(session.segmentPromptTitle == "Newest Claude title after new")
}

@Test func claudeTranscriptTitleIgnoresLocalCommandCaveat() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let projects = home.appendingPathComponent(".claude/projects/-tmp-banyan-claude")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let transcript = projects.appendingPathComponent("867ceb9b-12de-47ff-a70e-e562c00c8bf5.jsonl")
    try write(
        [
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat: The messages below were generated by the user while running local commands.</local-command-caveat>"},"timestamp":"2026-07-01T11:00:00.000Z","cwd":"/tmp/banyan-claude","sessionId":"867ceb9b-12de-47ff-a70e-e562c00c8bf5"}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>fable</command-args>"},"timestamp":"2026-07-01T11:00:01.000Z","cwd":"/tmp/banyan-claude","sessionId":"867ceb9b-12de-47ff-a70e-e562c00c8bf5"}"#,
            #"{"type":"user","message":{"role":"user","content":"Review recent session display bugs"},"timestamp":"2026-07-01T11:00:20.000Z","cwd":"/tmp/banyan-claude","sessionId":"867ceb9b-12de-47ff-a70e-e562c00c8bf5"}"#
        ].joined(separator: "\n"),
        to: transcript
    )

    let imported = AgentSessionHistoryImporter.load(homeDirectory: home, maxPerProvider: 10)

    let session = try #require(imported.first { $0.id == "history-claude-867ceb9b-12de-47ff-a70e-e562c00c8bf5" })
    #expect(session.title == "Review recent session display bugs")
}

@Test func defaultImportOnlyLoadsTenRecentSessionsPerProvider() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let projects = home.appendingPathComponent(".claude/projects/-tmp-banyan-claude")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let baseDate = Date(timeIntervalSince1970: 1_788_000_000)

    for index in 0..<12 {
        let sourceID = String(format: "867ceb9b-12de-47ff-a70e-e562c00c8b%02d", index)
        let transcript = projects.appendingPathComponent("\(sourceID).jsonl")
        try write(
            #"{"type":"user","message":{"role":"user","content":"Claude recent cap \#(index)"},"timestamp":"2026-07-01T11:00:00.000Z","cwd":"/tmp/banyan-claude","sessionId":"\#(sourceID)"}"#,
            to: transcript
        )
        try FileManager.default.setAttributes(
            [.modificationDate: baseDate.addingTimeInterval(TimeInterval(index))],
            ofItemAtPath: transcript.path
        )
    }

    let imported = AgentSessionHistoryImporter.load(homeDirectory: home)
        .filter { $0.provider == .claude }

    #expect(imported.count == 10)
    #expect(imported.contains { $0.title == "Claude recent cap 11" })
    #expect(imported.contains { $0.title == "Claude recent cap 2" })
    #expect(!imported.contains { $0.title == "Claude recent cap 1" })
    #expect(!imported.contains { $0.title == "Claude recent cap 0" })
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

@Test func transcriptPreviewSkipsClaudeLocalCommandMessages() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let transcript = home.appendingPathComponent("claude.jsonl")
    try write(
        [
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat: The messages below were generated by the user while running local commands.</local-command-caveat>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Set model to Fable 5</local-command-stdout>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"Please inspect the app."}}"#
        ].joined(separator: "\n"),
        to: transcript
    )

    let preview = AgentSessionHistoryImporter.transcriptPreview(from: transcript, provider: .claude)

    #expect(!preview.contains("local-command-caveat"))
    #expect(!preview.contains("Set model to Fable"))
    #expect(preview == "User: Please inspect the app.")
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
