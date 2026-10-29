import Foundation
import Testing
@testable import BanyanCore

@Test func liveCodexTranscriptLookupUsesLocalCreationDayAndExactID() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-transcript-lookup-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceID = "01a18383-333d-77d2-8976-163019138221"
    let directory = root
        .appendingPathComponent(".codex/sessions/2026/10/29")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let transcript = directory.appendingPathComponent(
        "rollout-2026-10-29T01-16-16-\(sourceID).jsonl"
    )
    try "{}\n".write(to: transcript, atomically: true, encoding: .utf8)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 60 * 60))
    let createdAt = try #require(ISO8601DateFormatter().date(from: "2026-10-28T17:16:13Z"))

    let resolved = try #require(AgentSessionHistoryImporter.transcriptURL(
        homeDirectory: root,
        provider: .codex,
        sourceID: sourceID,
        cwd: "/Users/example/project",
        createdAt: createdAt,
        calendar: calendar
    ))
    #expect(resolved.resolvingSymlinksInPath() == transcript.resolvingSymlinksInPath())
}

@Test func liveClaudeTranscriptLookupUsesEncodedProjectDirectory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-transcript-lookup-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceID = "session-uuid"
    let cwd = "/Users/example/project"
    let directory = root
        .appendingPathComponent(".claude/projects/-Users-example-project")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let transcript = directory.appendingPathComponent("\(sourceID).jsonl")
    try "{}\n".write(to: transcript, atomically: true, encoding: .utf8)

    let resolved = try #require(AgentSessionHistoryImporter.transcriptURL(
        homeDirectory: root,
        provider: .claude,
        sourceID: sourceID,
        cwd: cwd,
        createdAt: Date()
    ))
    #expect(resolved.resolvingSymlinksInPath() == transcript.resolvingSymlinksInPath())
}
