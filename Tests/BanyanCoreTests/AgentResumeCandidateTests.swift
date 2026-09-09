import Foundation
import Testing
@testable import BanyanCore

/// Resume matching reads only provider/cwd/timestamps, so the scan that feeds it
/// must never pay for transcript bodies. These pin both halves: that the cheap
/// scan agrees with a full import about which conversation is resumable, and
/// that it stays cheap — no title parsing, no tail reads, bounded file count.

@Test func resumeCandidatesFindTheCodexConversationForAWorkingDirectory() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let wanted = try writeCodexRollout(
        home: home,
        day: "2026/07/01",
        id: "019efe8d-0514-72a2-ad62-daea0b976dcf",
        cwd: "/tmp/banyan-wanted",
        startedAt: "2026-07-01T10:00:00.000Z"
    )
    _ = try writeCodexRollout(
        home: home,
        day: "2026/07/01",
        id: "019efe8d-0514-72a2-ad62-daea0b976dd0",
        cwd: "/tmp/banyan-other",
        startedAt: "2026-07-01T10:00:00.000Z"
    )

    let candidates = AgentSessionHistoryImporter.resumeCandidates(
        homeDirectory: home,
        cwd: "/tmp/banyan-wanted",
        provider: .codex
    )

    #expect(candidates.count == 1)
    let candidate = try #require(candidates.first)
    #expect(candidate.sourceID == "019efe8d-0514-72a2-ad62-daea0b976dcf")
    #expect(candidate.cwd == "/tmp/banyan-wanted")
    #expect(candidate.provider == .codex)
    _ = wanted
}

@Test func resumeCandidatesReadOnlyTheCodexHeader() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    // A body far larger than the importer's 4 MB tail window. If the scan still
    // read transcript bodies this test would be the slow one in the suite; more
    // importantly, a candidate must come back without the body being parseable.
    let filler = String(repeating: "x", count: 200_000)
    let bodyLines = (0..<40).map { index in
        #"{"timestamp":"2026-07-01T10:0\#(index % 10):00.000Z","type":"event_msg","payload":{"type":"user_message","message":"\#(filler)"}}"#
    }
    _ = try writeCodexRollout(
        home: home,
        day: "2026/07/01",
        id: "019efe8d-0514-72a2-ad62-daea0b976dcf",
        cwd: "/tmp/banyan-large",
        startedAt: "2026-07-01T10:00:00.000Z",
        extraLines: bodyLines
    )

    let candidates = AgentSessionHistoryImporter.resumeCandidates(
        homeDirectory: home,
        cwd: "/tmp/banyan-large",
        provider: .codex
    )

    #expect(candidates.count == 1)
    #expect(candidates.first?.cwd == "/tmp/banyan-large")
}

@Test func resumeCandidatesScopeClaudeToItsEncodedProjectDirectory() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let projects = home.appendingPathComponent(".claude/projects")
    // Claude replaces every non-alphanumeric character in the path with "-".
    try writeClaudeTranscript(
        in: projects.appendingPathComponent("-tmp-banyan-wanted"),
        named: "session-wanted",
        cwd: "/tmp/banyan-wanted",
        timestamp: "2026-07-01T10:00:00.000Z"
    )
    try writeClaudeTranscript(
        in: projects.appendingPathComponent("-tmp-banyan-other"),
        named: "session-other",
        cwd: "/tmp/banyan-other",
        timestamp: "2026-07-01T10:00:00.000Z"
    )

    let candidates = AgentSessionHistoryImporter.resumeCandidates(
        homeDirectory: home,
        cwd: "/tmp/banyan-wanted",
        provider: .claude
    )

    #expect(candidates.count == 1)
    #expect(candidates.first?.sourceID == "session-wanted")
    #expect(candidates.first?.provider == .claude)
}

@Test func resumeCandidatesStillFindClaudeWhenTheDirectoryNameDoesNotEncodeTheCWD() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    // The directory encoding is undocumented and lossy, so a miss must fall back
    // to walking the projects tree rather than reporting nothing resumable.
    try writeClaudeTranscript(
        in: home.appendingPathComponent(".claude/projects/legacy-name"),
        named: "session-wanted",
        cwd: "/tmp/banyan-wanted",
        timestamp: "2026-07-01T10:00:00.000Z"
    )

    let candidates = AgentSessionHistoryImporter.resumeCandidates(
        homeDirectory: home,
        cwd: "/tmp/banyan-wanted",
        provider: .claude
    )

    #expect(candidates.map(\.sourceID) == ["session-wanted"])
}

@Test func resumeCandidatesSkipClaudeSubagentJournals() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let project = home.appendingPathComponent(".claude/projects/-tmp-banyan-wanted")
    try writeClaudeTranscript(
        in: project,
        named: "session-wanted",
        cwd: "/tmp/banyan-wanted",
        timestamp: "2026-07-01T10:00:00.000Z"
    )
    try writeClaudeTranscript(
        in: project.appendingPathComponent("subagents/workflows/workflow-a"),
        named: "journal",
        cwd: "/tmp/banyan-wanted",
        timestamp: "2026-07-01T10:00:00.000Z"
    )

    let candidates = AgentSessionHistoryImporter.resumeCandidates(
        homeDirectory: home,
        cwd: "/tmp/banyan-wanted",
        provider: .claude
    )

    #expect(candidates.map(\.sourceID) == ["session-wanted"])
}

@Test func resumeCandidatesHonourTheFileScanCeiling() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    for index in 0..<5 {
        _ = try writeCodexRollout(
            home: home,
            day: "2026/07/01",
            id: "019efe8d-0514-72a2-ad62-daea0b976d0\(index)",
            cwd: "/tmp/banyan-wanted",
            startedAt: "2026-07-01T10:00:00.000Z"
        )
    }

    let capped = AgentSessionHistoryImporter.resumeCandidates(
        homeDirectory: home,
        cwd: "/tmp/banyan-wanted",
        provider: .codex,
        maxFilesScanned: 2
    )

    #expect(capped.count == 2)
}

@Test func resumeCandidatesAgreeWithTheFullImportOnTheResumeTarget() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let sessionCreatedAt = try #require(isoDate("2026-07-01T10:00:30.000Z"))
    _ = try writeCodexRollout(
        home: home,
        day: "2026/07/01",
        id: "019efe8d-0514-72a2-ad62-daea0b976dcf",
        cwd: "/tmp/banyan-wanted",
        startedAt: "2026-07-01T10:00:00.000Z"
    )
    _ = try writeCodexRollout(
        home: home,
        day: "2026/06/01",
        id: "019efe8d-0514-72a2-ad62-daea0b976dd0",
        cwd: "/tmp/banyan-wanted",
        startedAt: "2026-06-01T10:00:00.000Z"
    )

    let cheap = AgentSessionMatcher.bestHistoryResumeMatch(
        sessionCWD: "/tmp/banyan-wanted",
        sessionCreatedAt: sessionCreatedAt,
        sessionUpdatedAt: sessionCreatedAt,
        sessionResetAt: nil,
        provider: .codex,
        in: AgentSessionHistoryImporter.resumeCandidates(
            homeDirectory: home,
            cwd: "/tmp/banyan-wanted",
            provider: .codex
        )
    )
    let full = AgentSessionMatcher.bestHistoryResumeMatch(
        sessionCWD: "/tmp/banyan-wanted",
        sessionCreatedAt: sessionCreatedAt,
        sessionUpdatedAt: sessionCreatedAt,
        sessionResetAt: nil,
        provider: .codex,
        in: AgentSessionHistoryImporter.load(homeDirectory: home, maxPerProvider: .max)
    )

    #expect(cheap?.sourceID == "019efe8d-0514-72a2-ad62-daea0b976dcf")
    #expect(cheap?.sourceID == full?.sourceID)
}

// MARK: - Fixtures

private func temporaryHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-resume-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

@discardableResult
private func writeCodexRollout(
    home: URL,
    day: String,
    id: String,
    cwd: String,
    startedAt: String,
    extraLines: [String] = []
) throws -> URL {
    let directory = home.appendingPathComponent(".codex/sessions/\(day)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("rollout-\(startedAt.prefix(10))T10-00-00-\(id).jsonl")
    let meta = #"{"timestamp":"\#(startedAt)","type":"session_meta","payload":{"id":"\#(id)","timestamp":"\#(startedAt)","cwd":"\#(cwd)"}}"#
    try ([meta] + extraLines)
        .joined(separator: "\n")
        .write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func writeClaudeTranscript(
    in directory: URL,
    named name: String,
    cwd: String,
    timestamp: String
) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Claude opens a transcript with settings rows that carry no cwd.
    try [
        #"{"type":"last-prompt","prompt":"hello"}"#,
        #"{"type":"mode","mode":"default"}"#,
        #"{"type":"user","timestamp":"\#(timestamp)","cwd":"\#(cwd)","message":{"role":"user","content":"Resume me"}}"#
    ]
    .joined(separator: "\n")
    .write(to: directory.appendingPathComponent("\(name).jsonl"), atomically: true, encoding: .utf8)
}

private func isoDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
}
