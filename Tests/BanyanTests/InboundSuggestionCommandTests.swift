import BanyanCore
import Foundation
import Testing
@testable import Banyan

/// The seam between the inbound suggestion channel and the palette: an approved
/// suggestion runs as a synthetic `PaletteCommand`, which is what keeps the spawn,
/// the background runner, the log file and the result banner shared rather than
/// duplicated.
@Test func approvedSuggestionBecomesARootPaletteCommand() {
    let suggestion = InboundSuggestion(
        key: "stale-review:TASK-123",
        title: "TASK-123 has no reviewer",
        detail: "In Review for 6 days",
        target: "TASK-123",
        command: "workit TASK-123",
        run: .background
    )

    let command = SessionStore.paletteCommand(for: suggestion)

    #expect(command.id == "suggestion.stale-review-TASK-123")
    #expect(command.title == "TASK-123 has no reviewer")
    #expect(command.command == "workit TASK-123")
    #expect(command.run == .background)
    // Always top-level: an out-of-process suggester cannot see what is selected.
    #expect(command.parent == .root)
}

@Test func suggestionCommandIDSurvivesAKeyThatIsNotFilenameSafe() {
    let suggestion = InboundSuggestion(
        key: "https://github.com/example/repo/issues/7",
        title: "Review the open PR",
        command: "gh pr view 7"
    )

    let command = SessionStore.paletteCommand(for: suggestion)

    #expect(command.id == "suggestion.https---github-com-example-repo-issues-7")
    // The id names the run's log file, so it has to stay one path component.
    #expect(!command.id.contains("/"))
}

@Test func suggestionCommandStillExpandsTargetPlaceholders() {
    let suggestion = InboundSuggestion(
        title: "Review {{target}}",
        target: "TASK-123",
        command: "workit {{target}} {{agentFlag}}"
    )

    let command = SessionStore.paletteCommand(for: suggestion)

    #expect(command.expandedTitle(target: suggestion.target, query: nil, agent: nil) == "Review TASK-123")
    #expect(
        command.expandedCommand(target: suggestion.target, query: nil, agent: "codex")
            == "workit TASK-123 --agent codex"
    )
}
