import Foundation
import Testing
@testable import BanyanCore

@Test func sharedHistoryImporterLoadsCodexMetadata() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-history-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }

    let sessionDirectory = home.appendingPathComponent(".codex/sessions/2026/07/01")
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    let id = "019efe8d-0514-72a2-ad62-daea0b976dcf"
    let transcript = sessionDirectory.appendingPathComponent("rollout-2026-07-01T10-00-00-\(id).jsonl")
    try [
        #"{"timestamp":"2026-07-01T10:00:00.000Z","type":"session_meta","payload":{"cwd":"/tmp/banyan-codex"}}"#,
        #"{"timestamp":"2026-07-01T10:00:10.000Z","type":"event_msg","payload":{"type":"user_message","message":"Load shared history"}}"#
    ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

    let imported = AgentSessionHistoryImporter.load(homeDirectory: home, maxPerProvider: 10)
    let session = try #require(imported.first)

    #expect(session.id == "history-codex-\(id)")
    #expect(session.title == "Load shared history")
    #expect(session.cwd == "/tmp/banyan-codex")
}

@Test func sharedHistoryImporterIgnoresClaudeWorkflowJournals() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-history-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }

    let projectsDirectory = home.appendingPathComponent(".claude/projects")
    let projectDirectory = projectsDirectory.appendingPathComponent("project-a")
    let workflowJournal = projectDirectory
        .appendingPathComponent("subagents/workflows/workflow-a/journal.jsonl")
    let secondWorkflowJournal = projectsDirectory
        .appendingPathComponent("project-b/subagents/workflows/workflow-b/journal.jsonl")
    let topLevelSession = projectDirectory.appendingPathComponent("session-a.jsonl")

    for url in [workflowJournal, secondWorkflowJournal, topLevelSession] {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
    try #"{"type":"user","timestamp":"2026-07-01T10:00:00.000Z","cwd":"/tmp/claude-project","message":{"role":"user","content":"Keep this session"}}"#
        .write(to: topLevelSession, atomically: true, encoding: .utf8)
    try "not a Claude session".write(to: workflowJournal, atomically: true, encoding: .utf8)
    try "not a Claude session".write(to: secondWorkflowJournal, atomically: true, encoding: .utf8)

    let imported = AgentSessionHistoryImporter.load(homeDirectory: home, maxPerProvider: 10)

    #expect(imported.count == 1)
    #expect(imported.first?.id == "history-claude-session-a")
    #expect(imported.first?.title == "Keep this session")
}

@Test func sharedHistoryImporterPrefersTheCodexGeneratedThreadName() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-history-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }

    let sessionDirectory = home.appendingPathComponent(".codex/sessions/2026/07/01")
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    let id = "019efe8d-0514-72a2-ad62-daea0b976dcf"
    let transcript = sessionDirectory.appendingPathComponent("rollout-2026-07-01T10-00-00-\(id).jsonl")
    try [
        #"{"timestamp":"2026-07-01T10:00:00.000Z","type":"session_meta","payload":{"cwd":"/tmp/banyan-codex"}}"#,
        #"{"timestamp":"2026-07-01T10:00:10.000Z","type":"event_msg","payload":{"type":"user_message","message":"I want you to rework the history importer"}}"#
    ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

    try [
        #"{"id":"\#(id)","thread_name":"I want you to rework the history i","updated_at":"2026-07-01T10:00:10.000Z"}"#,
        #"{"id":"\#(id)","thread_name":"Rework history importer","updated_at":"2026-07-01T10:00:16.000Z"}"#
    ].joined(separator: "\n").write(
        to: home.appendingPathComponent(".codex/session_index.jsonl"),
        atomically: true,
        encoding: .utf8
    )

    let session = try #require(AgentSessionHistoryImporter.load(homeDirectory: home, maxPerProvider: 10).first)

    #expect(session.agentGeneratedTitle == "Rework history importer")
    #expect(session.title == "Rework history importer")
    // The prompt-derived title stays available for the post-/clear fallback.
    #expect(session.segmentPromptTitle == "I want you to rework the history importer")
}

@Test func sharedHistoryImporterFallsBackToThePromptBeforeCodexNamesTheThread() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-history-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }

    let sessionDirectory = home.appendingPathComponent(".codex/sessions/2026/07/01")
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    let id = "019efe8d-0514-72a2-ad62-daea0b976dcf"
    let transcript = sessionDirectory.appendingPathComponent("rollout-2026-07-01T10-00-00-\(id).jsonl")
    try [
        #"{"timestamp":"2026-07-01T10:00:00.000Z","type":"session_meta","payload":{"cwd":"/tmp/banyan-codex"}}"#,
        #"{"timestamp":"2026-07-01T10:00:10.000Z","type":"event_msg","payload":{"type":"user_message","message":"Rework the history importer"}}"#
    ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

    // Only the placeholder row exists so far.
    try #"{"id":"\#(id)","thread_name":"Rework the history importer","updated_at":"2026-07-01T10:00:10.000Z"}"#
        .write(
            to: home.appendingPathComponent(".codex/session_index.jsonl"),
            atomically: true,
            encoding: .utf8
        )

    let session = try #require(AgentSessionHistoryImporter.load(homeDirectory: home, maxPerProvider: 10).first)

    #expect(session.agentGeneratedTitle == nil)
    #expect(session.title == "Rework the history importer")
}
