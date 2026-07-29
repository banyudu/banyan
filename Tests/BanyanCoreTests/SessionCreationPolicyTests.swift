import Testing
@testable import BanyanCore

@Test func creationPolicyNormalizesShellSessionDefaults() {
    let plan = SessionCreationPolicy.plan(
        proposedID: " feature/sidebar ",
        proposedTitle: nil,
        proposedTitleURL: "  ",
        proposedCWD: "/tmp",
        proposedCommand: nil,
        proposedParentSessionID: " parent ",
        currentDirectory: "/does/not/exist",
        homeDirectory: "/home/yudu"
    )

    #expect(plan.baseID == "feature-sidebar")
    #expect(plan.title == "/tmp")
    #expect(plan.titleURL == nil)
    #expect(!plan.isTitlePinned)
    #expect(plan.cwd == "/tmp")
    #expect(plan.command == "")
    #expect(plan.parentSessionID == "parent")
}

@Test func creationPolicyPreservesExplicitTitleAndCommand() {
    let plan = SessionCreationPolicy.plan(
        proposedID: nil,
        proposedTitle: "  Keep this title  ",
        proposedTitleURL: "https://linear.app/acme/issue/ENG-1",
        proposedCWD: "/does/not/exist",
        proposedCommand: "codex",
        proposedParentSessionID: nil,
        currentDirectory: "/tmp",
        homeDirectory: "/home/yudu"
    )

    #expect(plan.baseID == "Keep-this-title")
    #expect(plan.title == "  Keep this title  ")
    #expect(plan.titleURL == "https://linear.app/acme/issue/ENG-1")
    #expect(plan.isTitlePinned)
    #expect(plan.cwd == "/home/yudu")
    #expect(plan.command == "codex")
}
