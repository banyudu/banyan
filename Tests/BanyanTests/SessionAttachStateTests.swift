import Foundation
import BanyanCore
import Testing
@testable import Banyan

@MainActor
@Test func normalInactiveDetachDoesNotRequireManualAttach() {
    let session = makeAttachStateSession(isRestored: false)

    session.detachTerminalClient()

    #expect(!session.isProcessStarted)
    #expect(!session.isRestored)
    #expect(!session.needsManualAttach)
}

@MainActor
@Test func freshSessionIsNotMarkedStartedBeforeItsBackingSessionExists() {
    let session = makeAttachStateSession(isRestored: false)

    #expect(!session.isProcessStarted)
    #expect(session.status == .running)
}

@MainActor
@Test func restoredRunningSessionDoesNotRequireManualAttachBeforeSelection() {
    let session = makeAttachStateSession(isRestored: true)

    #expect(!session.needsManualAttach)
}

@MainActor
@Test func failedAttachRequiresManualAttach() {
    let session = makeAttachStateSession(isRestored: true, status: .failed)

    #expect(session.needsManualAttach)
}

@MainActor
@Test func submittedInputPromotesIdleAgentSessionToExecuting() {
    let session = makeAttachStateSession(isRestored: false, status: .longRunningShell, command: "codex")

    session.noteUserSubmittedInput()

    #expect(session.status == .executing)
    #expect(session.tone == .blue)
}

@MainActor
@Test func submittedInputDoesNotPromotePlainShellSession() {
    let session = makeAttachStateSession(isRestored: false, status: .longRunningShell, command: "")

    session.noteUserSubmittedInput()

    #expect(session.status == .longRunningShell)
}

@MainActor
@Test func submittedInputTitlesUnpinnedAgentSession() {
    let session = makeAttachStateSession(isRestored: false, status: .longRunningShell, command: "codex")

    session.noteUserSubmittedInput("find workable linear issues for me")

    #expect(session.displayTitle == "find workable linear issues for me")
    #expect(session.reportedTitle == "find workable linear issues for me")
}

@MainActor
@Test func submittedInputIgnoresTrivialAgentResponsesForTitles() {
    let session = makeAttachStateSession(isRestored: false, status: .longRunningShell, command: "codex")

    session.noteUserSubmittedInput("y")

    #expect(session.reportedTitle == nil)
}

@MainActor
@Test func transcriptResetDropsStaleTitleWhenKeystrokePathMissedClear() {
    let session = makeAttachStateSession(isRestored: false, status: .longRunningShell, command: "codex")
    session.noteUserSubmittedInput("find workable linear issues for me")
    #expect(session.reportedTitle == "find workable linear issues for me")

    // Simulates the supervisor observing a /clear in the transcript that the
    // keystroke monitor never captured (autocomplete/paste/unfocused/closed).
    session.noteConversationResetFromTranscript()

    #expect(session.reportedTitle == nil)
    #expect(session.generatedTitle == nil)
}

@MainActor
@Test func transcriptResetKeepsPinnedTitle() {
    let session = makeAttachStateSession(isRestored: false, status: .longRunningShell, command: "codex")
    session.noteUserSubmittedInput("find workable linear issues for me")
    session.title = "Pinned name"
    session.isTitlePinned = true

    session.noteConversationResetFromTranscript()

    #expect(session.displayTitle == "Pinned name")
}

@MainActor
@Test func issueBindingFollowsTheWorkingDirectoryIntoAnotherIssuesWorktree() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("clawly")
    let worktree = root.appendingPathComponent("yudu-eng-7420-12edc9")
    for directory in [repo, worktree] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // Bound deliberately, the way `banyanctl mark --title-url` does it.
    let session = makeIssueBindingSession(cwd: repo.path)
    session.mark(titleURL: "https://linear.app/2en/issue/ENG-7664")
    #expect(session.titleLinkLabel == "ENG-7664")

    session.updateCurrentDirectory(worktree.path)

    #expect(session.titleLinkLabel == "ENG-7420")
    #expect(session.titleURL == "https://linear.app/2en/issue/ENG-7420")
}

@MainActor
@Test func issueChipNeverNamesADifferentIssueThanTheLinkItOpens() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let worktree = root.appendingPathComponent("yudu-eng-7420-12edc9")
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

    // A title left over from the issue this pane used to be working on.
    let session = makeIssueBindingSession(cwd: worktree.path)
    session.mark(title: "ENG-7664 监听 main 分支 CI 失败")

    #expect(session.titleURL == "https://linear.app/2en/issue/ENG-7420")
    #expect(session.titleLinkLabel == "ENG-7420")
}

@MainActor
@Test func detectedIssueBindingIsDroppedOnceTheDirectoryNoLongerSupportsIt() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("clawly")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

    // A restored session carrying a binding detected in an earlier chapter (its pane
    // has since moved back to the main checkout), which used to stick forever.
    let session = makeIssueBindingSession(
        cwd: repo.path,
        titleURL: "https://linear.app/2en/issue/ENG-7664",
        titleURLWasAutoDetected: true
    )

    // Restoring on a checkout that no longer supports the persisted automatic
    // binding clears it immediately; no cwd change is required.
    #expect(session.titleURL == nil)
    #expect(session.titleLinkLabel == nil)
}

@MainActor
@Test func sameDirectoryBranchSwitchRefreshesDetectedIssueBinding() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("clawly")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try runGit(["init", "-b", "main"], cwd: repo)
    try runGit(["config", "user.email", "test@example.com"], cwd: repo)
    try runGit(["config", "user.name", "Banyan Tests"], cwd: repo)
    try "initial".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try runGit(["add", "README.md"], cwd: repo)
    try runGit(["commit", "-m", "initial"], cwd: repo)
    try runGit(["checkout", "-b", "yudu/ENG-7944-fix"], cwd: repo)

    let session = makeIssueBindingSession(cwd: repo.path)
    #expect(session.titleLinkLabel == "ENG-7944")

    try runGit(["checkout", "main"], cwd: repo)
    session.updateCurrentDirectory(repo.path)

    #expect(session.titleURL == nil)
    #expect(session.titleLinkLabel == nil)
}

@MainActor
@Test func explicitIssueBindingSurvivesWhenTheDirectorySaysNothing() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("clawly")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

    let session = makeIssueBindingSession(
        cwd: repo.path,
        titleURL: "https://linear.app/2en/issue/ENG-7664",
        titleURLWasAutoDetected: false
    )

    session.updateCurrentDirectory(repo.path)

    #expect(session.titleLinkLabel == "ENG-7664")
}

@MainActor
@Test func repeatedDegradedGitLookupsKeepTheLastTrustworthyProjectGroup() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("banyan")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try runGit(["init"], cwd: repo)
    try runGit(["remote", "add", "origin", "git@github.com:banyudu/banyan.git"], cwd: repo)

    let session = makeIssueBindingSession(cwd: repo.path)
    let trustworthyGroupID = session.projectGroupID
    let missingDirectory = root.appendingPathComponent("missing")

    session.updateCurrentDirectory(missingDirectory.path)
    session.updateCurrentDirectory(missingDirectory.path)

    #expect(session.projectGroupID == trustworthyGroupID)
    #expect(session.projectGroupTitle == "banyudu/banyan")
}

@Test func legacySnapshotsWithoutBindingProvenanceDecodeAsDetected() throws {
    let json = """
    {
        "id": "session-167",
        "title": "~/dev/2enai/clawly",
        "titleURL": "https://linear.app/2en/issue/ENG-7664",
        "cwd": "/Users/banyudu/dev/2enai/clawly",
        "command": "",
        "status": "running",
        "tone": "blue",
        "createdAt": 771000000,
        "updatedAt": 771000000
    }
    """
    let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))

    #expect(snapshot.titleURLWasAutoDetected)
}

@Test func codingAgentIdleStatusOnlyIncludesWaitingStates() {
    let idleStatuses: Set<SessionStatus> = [.needInput, .asking, .review]

    for status in SessionStatus.allCases {
        #expect(status.isCodingAgentIdle == idleStatuses.contains(status))
    }
}

@MainActor
@Test func handoffEligibilityRequiresIdleCodingAgentInWorktree() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let worktree = try createGitWorktree(in: root)

    let idleSession = makeHandoffSession(
        id: "idle-handoff",
        cwd: worktree.path,
        command: "codex",
        status: .needInput
    )
    let reviewSession = makeHandoffSession(
        id: "review-handoff",
        cwd: worktree.path,
        command: "codex",
        status: .review
    )
    let executingSession = makeHandoffSession(
        id: "executing-handoff",
        cwd: worktree.path,
        command: "codex",
        status: .executing
    )
    let shellSession = makeHandoffSession(
        id: "shell-handoff",
        cwd: worktree.path,
        command: "zsh",
        status: .needInput
    )

    #expect(idleSession.canDispatchHandoff)
    #expect(reviewSession.canDispatchHandoff)
    #expect(!executingSession.canDispatchHandoff)
    #expect(!shellSession.canDispatchHandoff)
}

@MainActor
@Test func killBackingSessionKillsUnderlyingTmuxSession() throws {
    let tmux = banyanTestTmuxBackend
    let id = "close-kills-\(UUID().uuidString.lowercased())"
    let tmuxSessionName = TmuxBackend.sessionName(for: id)
    try tmux.ensureSession(named: tmuxSessionName, cwd: "/tmp", command: "")
    defer {
        tmux.killSession(named: tmuxSessionName)
    }

    let session = BanyanSession(
        id: id,
        tmuxSessionName: tmuxSessionName,
        title: "Close kills",
        cwd: "/tmp",
        command: "",
        isRestored: true,
        theme: .system,
        tmuxBackend: banyanTestTmuxBackend,
        telemetry: banyanTestTelemetry,
        host: banyanTestHost
    )

    #expect(tmux.hasSession(named: tmuxSessionName))

    session.killBackingSession()

    #expect(session.status == .closed)
    #expect(!tmux.hasSession(named: tmuxSessionName))
}

@MainActor
private func makeAttachStateSession(
    isRestored: Bool,
    status: SessionStatus = .running,
    command: String = ""
) -> BanyanSession {
    BanyanSession(
        id: "attach-state",
        title: "/tmp",
        cwd: "/tmp",
        command: command,
        status: status,
        isRestored: isRestored,
        theme: .system,
        tmuxBackend: banyanTestTmuxBackend,
        telemetry: banyanTestTelemetry,
        host: banyanTestHost
    )
}

@MainActor
private func makeIssueBindingSession(
    cwd: String,
    titleURL: String? = nil,
    titleURLWasAutoDetected: Bool? = nil
) -> BanyanSession {
    BanyanSession(
        id: "issue-binding",
        title: "Session",
        titleURL: titleURL,
        titleURLWasAutoDetected: titleURLWasAutoDetected,
        cwd: cwd,
        command: "",
        theme: .system,
        tmuxBackend: banyanTestTmuxBackend,
        telemetry: banyanTestTelemetry,
        host: banyanTestHost
    )
}

@MainActor
private func makeHandoffSession(
    id: String,
    cwd: String,
    command: String,
    status: SessionStatus
) -> BanyanSession {
    BanyanSession(
        id: id,
        title: "Handoff",
        cwd: cwd,
        command: command,
        status: status,
        isRestored: true,
        theme: .system,
        tmuxBackend: banyanTestTmuxBackend,
        telemetry: banyanTestTelemetry,
        host: banyanTestHost
    )
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BanyanTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func createGitWorktree(in root: URL) throws -> URL {
    let main = root.appendingPathComponent("repo")
    let worktree = root.appendingPathComponent("repo-worktree")
    try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
    try runGit(["init"], cwd: main)
    try runGit(["config", "user.email", "test@example.com"], cwd: main)
    try runGit(["config", "user.name", "Banyan Tests"], cwd: main)
    try "test".write(to: main.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try runGit(["add", "README.md"], cwd: main)
    try runGit(["commit", "-m", "Initial commit"], cwd: main)
    try runGit(["worktree", "add", "-b", "feature", worktree.path], cwd: main)
    return worktree
}

@discardableResult
private func runGit(_ arguments: [String], cwd: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = cwd
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if process.terminationStatus != 0 {
        let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw GitTestError(arguments: arguments, message: message)
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

private struct GitTestError: Error, CustomStringConvertible {
    let arguments: [String]
    let message: String

    var description: String {
        "git \(arguments.joined(separator: " ")) failed: \(message)"
    }
}
