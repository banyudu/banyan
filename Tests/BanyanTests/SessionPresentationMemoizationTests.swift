import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

/// `displayTitle` and `titleLinkLabel` cache their result against their inputs. The
/// risk that buys is staleness: if an input is missing from the cache key, the cached
/// value survives a change it should not have. These pin the invalidation for every
/// mutable input the two keys claim to cover.
@MainActor
private func makeMemoSession() -> BanyanSession {
    BanyanSession(
        id: "memo-\(UUID().uuidString)",
        title: "initial",
        cwd: NSTemporaryDirectory(),
        command: "",
        isRestored: true,
        theme: .system,
        tmuxBackend: banyanTestTmuxBackend,
        telemetry: banyanTestTelemetry,
        host: banyanTestHost
    )
}

@MainActor
@Test func displayTitleIsStableAcrossRepeatedReads() {
    let session = makeMemoSession()
    let first = session.displayTitle
    #expect(session.displayTitle == first)
    #expect(session.displayTitle == first)
}

@MainActor
@Test func displayTitleInvalidatesWhenTitleChanges() {
    let session = makeMemoSession()
    session.isTitlePinned = true
    session.title = "before"
    let before = session.displayTitle

    session.title = "after"
    #expect(session.displayTitle != before)
    #expect(session.displayTitle.contains("after"))
}

@MainActor
@Test func displayTitleInvalidatesWhenPinningChanges() {
    let session = makeMemoSession()
    session.title = "pinned-title"
    // An agent provider plus a reported title is what gives the unpinned path
    // something else to return; without it both paths fall through to `title` and
    // pinning would not be observable at all.
    session.command = "claude"
    session.reportedTitle = "reported-title"

    session.isTitlePinned = true
    let pinned = session.displayTitle
    session.isTitlePinned = false
    let unpinned = session.displayTitle

    // Pinning decides whether the reported title may override the set one, so the
    // two readings must differ — proving isTitlePinned is part of the key.
    #expect(pinned == "pinned-title")
    #expect(unpinned == "reported-title")
}

@MainActor
@Test func titleLinkLabelInvalidatesWhenTitleURLChanges() {
    let session = makeMemoSession()
    session.titleURL = "https://linear.app/2en/issue/TASK-1111"
    #expect(session.titleLinkLabel == "TASK-1111")

    session.titleURL = "https://linear.app/2en/issue/TASK-2222"
    #expect(session.titleLinkLabel == "TASK-2222")
}

@MainActor
@Test func titleLinkLabelInvalidatesWhenTitleChanges() {
    let session = makeMemoSession()
    session.titleURL = nil
    session.title = "working on TASK-3333"
    #expect(session.titleLinkLabel == "TASK-3333")

    session.title = "working on TASK-4444"
    #expect(session.titleLinkLabel == "TASK-4444")
}

@MainActor
@Test func titleLinkLabelInvalidatesWhenBranchChanges() {
    let session = makeMemoSession()
    session.titleURL = nil
    session.title = "no issue here"
    session.displayBranch = "yudu/task-5555-something"
    #expect(session.titleLinkLabel == "TASK-5555")

    // displayBranch is a plain `var`, not @Published, so nothing else would catch a
    // stale reading here — the key must cover it.
    session.displayBranch = "yudu/task-6666-something"
    #expect(session.titleLinkLabel == "TASK-6666")
}

@MainActor
@Test func agentProviderInvalidatesWhenCommandChanges() {
    let session = makeMemoSession()
    session.command = "claude"
    #expect(session.agentProvider == .claude)

    session.command = "codex"
    #expect(session.agentProvider == .codex)

    session.command = "zsh"
    #expect(session.agentProvider == nil)
}

@MainActor
@Test func agentProviderInvalidatesWhenDetectedProviderChanges() {
    let session = makeMemoSession()
    session.command = ""
    session.detectedAgentProvider = .claude
    #expect(session.agentProvider == .claude)

    session.detectedAgentProvider = .codex
    #expect(session.agentProvider == .codex)
}

@MainActor
@Test func displayAgentProviderInvalidatesWhenStatusChanges() {
    let session = makeMemoSession()
    // Launched as claude, but the supervisor has not confirmed a live agent process.
    session.command = "claude"
    session.detectedAgentProvider = nil

    session.status = .executing
    let executing = session.displayAgentProvider

    // `.running` means the supervisor sees a bare shell, so the row must stop showing
    // the agent — status has to be part of the key or this stays stale at .claude.
    session.status = .running
    let running = session.displayAgentProvider

    #expect(executing == .claude)
    #expect(running == nil)
}

@MainActor
@Test func titleLinkLabelInvalidatesWhenCwdChanges() {
    let session = makeMemoSession()
    session.titleURL = nil
    session.title = "no issue here"
    session.displayBranch = nil
    session.cwd = "/tmp/task-7777-worktree"
    #expect(session.titleLinkLabel == "TASK-7777")

    session.cwd = "/tmp/task-8888-worktree"
    #expect(session.titleLinkLabel == "TASK-8888")
}
