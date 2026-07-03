import Testing
@testable import BanyanCore

@Test func displayLabelUsesProjectBranchAndExplicitTitle() {
    let label = SessionDisplayLabel.make(
        project: "banyan",
        branch: "main",
        title: "what's the label",
        id: "session",
        command: ""
    )

    #expect(label == "banyan · main · \"what's the label\"")
}

@Test func displayLabelFallsBackFromGenericTitleToShell() {
    let label = SessionDisplayLabel.make(
        project: "banyan",
        branch: "main",
        title: "Shell",
        id: "Shell-2",
        command: ""
    )

    #expect(label == "banyan · main · \"shell\"")
}

@Test func displayLabelIgnoresHostTitleAndUsesAgentPrompt() {
    let label = SessionDisplayLabel.make(
        project: "banyan",
        branch: "main",
        title: "banyudu@Yudus-MacBook-Pro.local",
        id: "session",
        command: "codex implement the sidebar label"
    )

    #expect(label == "banyan · main · \"implement the sidebar label\"")
}
