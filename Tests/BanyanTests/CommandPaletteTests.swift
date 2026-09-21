@testable import Banyan
import AppKit
import Foundation
import Testing

private func navigationItems() -> [CommandPaletteItem] {
    NavigationCommandPaletteItems.items(
        onNextSession: {},
        onPreviousSession: {},
        onNextNeedingAttention: {},
        onPreviousNeedingAttention: {},
        onNextWorkable: {}
    )
}

@Test func commandPaletteAdvertisesTheAttentionShortcutsThatAreActuallyBound() {
    let items = navigationItems()

    let next = items.first { $0.id == "navigation.next-needs-attention" }
    let previous = items.first { $0.id == "navigation.previous-needs-attention" }

    #expect(next?.title == "Next Session Needing Attention")
    #expect(next?.shortcut == "⌘⌥J")
    #expect(previous?.title == "Previous Session Needing Attention")
    #expect(previous?.shortcut == "⌘⌥K")

    // The advertised label has to be the chord the key monitor consumes.
    #expect(SessionAttentionShortcuts.direction(
        for: "j",
        modifiers: [.command, .option]
    ) == .next)
    #expect(SessionAttentionShortcuts.direction(
        for: "k",
        modifiers: [.command, .option]
    ) == .previous)
}

@Test func commandPaletteKeepsTheExistingNavigationRows() {
    let ids = navigationItems().map(\.id)

    #expect(ids == [
        "navigation.next-session",
        "navigation.previous-session",
        "navigation.next-needs-attention",
        "navigation.previous-needs-attention",
        "navigation.next-workable"
    ])
}

@Test func commandPaletteRecognizesLinearIssueIdentifiers() {
    #expect(CommandPaletteTargetResolver.linearIssueID(in: "ENG-123") == "ENG-123")
    #expect(CommandPaletteTargetResolver.linearIssueID(in: "open ENG-123") == "ENG-123")
    #expect(CommandPaletteTargetResolver.linearIssueID(in: "not-an-issue") == nil)
}

@Test func commandPaletteBuildsGitHubPullRequestURLFromRepositoryReference() {
    let url = CommandPaletteTargetResolver.pullRequestURL(
        in: "banyudu/banyan#456",
        fallback: nil
    )
    #expect(url?.absoluteString == "https://github.com/banyudu/banyan/pull/456")
}

@Test func commandPaletteUsesSelectedRepositoryForBarePullRequestNumber() {
    let fallback = URL(string: "https://github.com/banyudu/banyan/pull/16")
    let url = CommandPaletteTargetResolver.pullRequestURL(in: "#456", fallback: fallback)
    #expect(url?.absoluteString == "https://github.com/banyudu/banyan/pull/456")
}

@Test func commandPaletteAcceptsGitHubPullRequestURL() {
    let url = CommandPaletteTargetResolver.pullRequestURL(
        in: "https://github.com/banyudu/banyan/pull/456",
        fallback: nil
    )
    #expect(url?.absoluteString == "https://github.com/banyudu/banyan/pull/456")
}

@Test func commandPaletteRejectsInvalidPullRequestTargets() {
    #expect(CommandPaletteTargetResolver.pullRequestURL(in: "#0", fallback: nil) == nil)
    #expect(CommandPaletteTargetResolver.pullRequestURL(in: "banyudu/banyan", fallback: nil) == nil)
    #expect(CommandPaletteTargetResolver.pullRequestURL(in: "https://example.com/pr/1", fallback: nil) == nil)
}

@Test func commandPaletteSelectionStepsThroughOptions() {
    #expect(CommandPaletteView.nextSelectedIndex(selectedIndex: 0, count: 3, direction: .down) == 1)
    #expect(CommandPaletteView.nextSelectedIndex(selectedIndex: 1, count: 3, direction: .up) == 0)
}

@Test func commandPaletteSelectionLoopsAroundAtEitherEnd() {
    #expect(CommandPaletteView.nextSelectedIndex(selectedIndex: 2, count: 3, direction: .down) == 0)
    #expect(CommandPaletteView.nextSelectedIndex(selectedIndex: 0, count: 3, direction: .up) == 2)
}

@Test func commandPaletteSelectionHandlesEdgeCases() {
    #expect(CommandPaletteView.nextSelectedIndex(selectedIndex: 0, count: 1, direction: .down) == 0)
    #expect(CommandPaletteView.nextSelectedIndex(selectedIndex: 0, count: 1, direction: .up) == 0)
    #expect(CommandPaletteView.nextSelectedIndex(selectedIndex: 0, count: 0, direction: .down) == 0)
}

@Test func commandPaletteTabTrapMatchesPlainTabOnly() {
    #expect(CommandPaletteTabTrap.matches(keyCode: 48, modifiers: [], isRepeat: false))
    #expect(CommandPaletteTabTrap.matches(keyCode: 48, modifiers: [.shift], isRepeat: false))
    #expect(!CommandPaletteTabTrap.matches(keyCode: 48, modifiers: [.command], isRepeat: false))
    #expect(!CommandPaletteTabTrap.matches(keyCode: 48, modifiers: [.control], isRepeat: false))
    #expect(!CommandPaletteTabTrap.matches(keyCode: 48, modifiers: [.option], isRepeat: false))
    #expect(!CommandPaletteTabTrap.matches(keyCode: 48, modifiers: [], isRepeat: true))
    #expect(!CommandPaletteTabTrap.matches(keyCode: 49, modifiers: [], isRepeat: false))
}

private func paletteAgentFixtures() -> [NewSessionLaunch] {
    [
        NewSessionLaunch(id: "claude", label: "Claude", providerName: "claude", iconName: nil, command: "claude"),
        NewSessionLaunch(id: "codex", label: "Codex", providerName: "codex", iconName: nil, command: "codex")
    ]
}

@Test func commandPaletteAgentLoopStepsThroughAutoAndProfiles() {
    let agents = paletteAgentFixtures()
    #expect(CommandPaletteView.nextAgentID(selectedID: nil, agents: agents, direction: .down) == "claude")
    #expect(CommandPaletteView.nextAgentID(selectedID: "claude", agents: agents, direction: .down) == "codex")
    #expect(CommandPaletteView.nextAgentID(selectedID: "codex", agents: agents, direction: .up) == "claude")
    #expect(CommandPaletteView.nextAgentID(selectedID: "claude", agents: agents, direction: .up) == nil)
}

@Test func commandPaletteAgentLoopWrapsAroundAtEitherEnd() {
    let agents = paletteAgentFixtures()
    #expect(CommandPaletteView.nextAgentID(selectedID: "codex", agents: agents, direction: .down) == nil)
    #expect(CommandPaletteView.nextAgentID(selectedID: nil, agents: agents, direction: .up) == "codex")
}

@Test func commandPaletteAgentLoopHandlesEdgeCases() {
    let agents = paletteAgentFixtures()
    #expect(CommandPaletteView.nextAgentID(selectedID: "stale-id", agents: agents, direction: .down) == "claude")
    #expect(CommandPaletteView.nextAgentID(selectedID: nil, agents: [], direction: .down) == nil)
    #expect(CommandPaletteView.nextAgentID(selectedID: "claude", agents: [], direction: .up) == nil)
}
