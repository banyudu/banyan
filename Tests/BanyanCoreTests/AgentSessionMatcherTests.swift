import Foundation
import Testing
@testable import BanyanCore

private func imported(
    id: String,
    provider: CodingAgentProvider = .codex,
    cwd: String = "/tmp/banyan",
    createdAt: Date,
    updatedAt: Date? = nil
) -> ImportedAgentSession {
    ImportedAgentSession(
        id: id,
        provider: provider,
        sourceID: id,
        title: id,
        cwd: cwd,
        transcriptURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
        createdAt: createdAt,
        updatedAt: updatedAt ?? createdAt
    )
}

@Test func matcherUsesCreationWindowForLivePromptTitles() {
    let base = Date(timeIntervalSince1970: 1_787_500_000)
    let match = imported(id: "near", createdAt: base.addingTimeInterval(30))
    let distant = imported(id: "distant", createdAt: base.addingTimeInterval(600))

    let result = AgentSessionMatcher.bestPromptTitleMatch(
        sessionCWD: "/tmp/banyan/.",
        sessionCreatedAt: base,
        sessionResetAt: nil,
        provider: .codex,
        in: [distant, match]
    )

    #expect(result?.id == "near")
}

@Test func matcherFallsBackToNearestActivityInTheSameDirectory() {
    let base = Date(timeIntervalSince1970: 1_787_500_000)
    let older = imported(
        id: "older",
        cwd: "/tmp/project",
        createdAt: base.addingTimeInterval(-86_400),
        updatedAt: base.addingTimeInterval(3_500)
    )
    let current = imported(
        id: "current",
        cwd: "/tmp/project",
        createdAt: base.addingTimeInterval(-86_400),
        updatedAt: base.addingTimeInterval(3_590)
    )

    let result = AgentSessionMatcher.bestHistoryResumeMatch(
        sessionCWD: "/tmp/project",
        sessionCreatedAt: base,
        sessionUpdatedAt: base.addingTimeInterval(3_600),
        sessionResetAt: nil,
        provider: .codex,
        in: [older, current]
    )

    #expect(result?.id == "current")
}

@Test func matcherAssignsEachImportedSessionAtMostOnce() {
    let base = Date(timeIntervalSince1970: 1_787_500_000)
    let sessions = [
        AgentSessionMatchInput(id: "a", cwd: "/tmp/banyan", createdAt: base, resetAt: nil, provider: .codex),
        AgentSessionMatchInput(id: "b", cwd: "/tmp/banyan", createdAt: base.addingTimeInterval(10), resetAt: nil, provider: .codex)
    ]
    let candidates = [imported(id: "only", createdAt: base.addingTimeInterval(5))]

    let result = AgentSessionMatcher.bestPromptTitleAssignments(for: sessions, in: candidates)

    #expect(result.count == 1)
    #expect(result.values.first?.id == "only")
}
