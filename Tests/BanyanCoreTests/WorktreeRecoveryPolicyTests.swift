import Foundation
import Testing
@testable import BanyanCore

/// Fixtures mirror the shapes seen in a repository that names worktree
/// directories after their branch: the plain convention, plus the three ways
/// real directories drift from it.

private func local(_ name: String) -> WorktreeBranchCandidate {
    WorktreeBranchCandidate(name: name, ref: name, isRemote: false)
}

private func remote(_ name: String, _ remoteName: String = "origin") -> WorktreeBranchCandidate {
    WorktreeBranchCandidate(name: name, ref: "\(remoteName)/\(name)", isRemote: true)
}

@Test func registeredBranchOutranksTheDirectoryName() {
    // Git still knows the branch, so the name is not consulted at all -- which
    // is what protects the case where a worktree was moved onto a new branch.
    let resolution = WorktreeRecoveryPolicy.resolve(
        worktreePath: "/repo/.worktrees/yudu-eng-1234-6ad858",
        recordedBranch: nil,
        registeredBranch: "yudu/eng-1234-claim-surface",
        candidates: [local("yudu/eng-1234-claim-surface"), local("yudu/eng-1234-6ad858")]
    )

    guard case .plan(let plan) = resolution else {
        Issue.record("expected a plan, got \(resolution)")
        return
    }
    #expect(plan.branch == "yudu/eng-1234-claim-surface")
    #expect(plan.startPoint == nil)
    #expect(plan.source == .registered)
}

@Test func directoryNameMatchesTheBranchItEncodes() {
    let resolution = WorktreeRecoveryPolicy.resolve(
        worktreePath: "/repo/.worktrees/yudu-eng-1234-b357ad",
        recordedBranch: nil,
        registeredBranch: nil,
        candidates: [local("yudu/eng-1234"), local("main"), local("yudu/eng-1234-b357ad")]
    )

    guard case .plan(let plan) = resolution else {
        Issue.record("expected a plan, got \(resolution)")
        return
    }
    #expect(plan.branch == "yudu/eng-1234-b357ad")
    #expect(plan.source == .inferred(tier: 1))
}

@Test func aRemoteOnlyBranchIsRecreatedFromItsTrackingRef() {
    let resolution = WorktreeRecoveryPolicy.resolve(
        worktreePath: "/repo/.worktrees/yudu-eng-1234-b357ad",
        recordedBranch: nil,
        registeredBranch: nil,
        candidates: [local("main"), remote("yudu/eng-1234-b357ad")]
    )

    guard case .plan(let plan) = resolution else {
        Issue.record("expected a plan, got \(resolution)")
        return
    }
    #expect(plan.branch == "yudu/eng-1234-b357ad")
    #expect(plan.startPoint == "origin/yudu/eng-1234-b357ad")
}

@Test func aLocalBranchWinsOverTheSameBranchOnARemote() {
    let resolution = WorktreeRecoveryPolicy.resolve(
        worktreePath: "/repo/.worktrees/yudu-eng-1234-b357ad",
        recordedBranch: nil,
        registeredBranch: nil,
        candidates: [remote("yudu/eng-1234-b357ad"), local("yudu/eng-1234-b357ad")]
    )

    guard case .plan(let plan) = resolution else {
        Issue.record("expected a plan, got \(resolution)")
        return
    }
    #expect(plan.startPoint == nil, "a local branch needs no start point")
}

@Test func aDirectoryThatDroppedTheOwnerPrefixStillResolves() {
    // Seen in practice: dir `eng-1893-agents-kernel`, branch
    // `banyudu/eng-1893-agents-kernel`.
    let resolution = WorktreeRecoveryPolicy.resolve(
        worktreePath: "/repo/.worktrees/eng-1893-agents-kernel",
        recordedBranch: nil,
        registeredBranch: nil,
        candidates: [local("main"), local("banyudu/eng-1893-agents-kernel")]
    )

    guard case .plan(let plan) = resolution else {
        Issue.record("expected a plan, got \(resolution)")
        return
    }
    #expect(plan.branch == "banyudu/eng-1893-agents-kernel")
    #expect(plan.source == .inferred(tier: 2))
}

@Test func aTruncatedDirectoryFallsBackToTheIssueID() {
    // Seen in practice: dir `yudu-eng-1642`, branch `yudu/eng-1642-digest-owner`.
    let resolution = WorktreeRecoveryPolicy.resolve(
        worktreePath: "/repo/.worktrees/yudu-eng-1642",
        recordedBranch: nil,
        registeredBranch: nil,
        candidates: [local("main"), local("yudu/eng-1642-digest-owner")]
    )

    guard case .plan(let plan) = resolution else {
        Issue.record("expected a plan, got \(resolution)")
        return
    }
    #expect(plan.branch == "yudu/eng-1642-digest-owner")
    #expect(plan.source == .inferred(tier: 3))
}

@Test func aStricterTierWinsBeforeTheIssueIDFallbackIsTried() {
    // Two branches share the issue ID, but only one encodes to the directory.
    // Falling straight to the issue ID would call this ambiguous.
    let resolution = WorktreeRecoveryPolicy.resolve(
        worktreePath: "/repo/.worktrees/yudu-eng-1234-b357ad",
        recordedBranch: nil,
        registeredBranch: nil,
        candidates: [local("yudu/eng-1234-b357ad"), local("yudu/eng-1234-other-slug")]
    )

    guard case .plan(let plan) = resolution else {
        Issue.record("expected a plan, got \(resolution)")
        return
    }
    #expect(plan.branch == "yudu/eng-1234-b357ad")
    #expect(plan.source == .inferred(tier: 1))
}

@Test func severalEqualMatchesAreReportedRatherThanGuessed() {
    let resolution = WorktreeRecoveryPolicy.resolve(
        worktreePath: "/repo/.worktrees/yudu-eng-1234",
        recordedBranch: nil,
        registeredBranch: nil,
        candidates: [local("yudu/eng-1234-one"), local("yudu/eng-1234-two")]
    )

    guard case .ambiguous(let branches) = resolution else {
        Issue.record("expected ambiguity, got \(resolution)")
        return
    }
    #expect(branches == ["yudu/eng-1234-one", "yudu/eng-1234-two"])
}

@Test func aWorktreeWhoseBranchIsGoneIsNotRecoverable() {
    let resolution = WorktreeRecoveryPolicy.resolve(
        worktreePath: "/repo/.worktrees/yudu-eng-1234-b357ad",
        recordedBranch: nil,
        registeredBranch: nil,
        candidates: [local("main"), local("yudu/eng-9999-other")]
    )

    #expect(resolution == .noCandidate)
}

@Test func aRecordedBranchThatNoLongerExistsIsNotInvented() {
    // The branch Banyan saw while the session ran has since been deleted.
    // Creating it from nothing would produce an empty worktree, not a recovery.
    let resolution = WorktreeRecoveryPolicy.resolve(
        worktreePath: "/repo/.worktrees/yudu-eng-1234-b357ad",
        recordedBranch: "yudu/eng-1234-b357ad",
        registeredBranch: nil,
        candidates: [local("main")]
    )

    #expect(resolution == .noCandidate)
}
