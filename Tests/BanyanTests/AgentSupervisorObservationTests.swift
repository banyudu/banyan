import Foundation
import BanyanCore
import Testing
@testable import Banyan


@Test func supervisorCarriesTheCaptureItsBlockedVerdictWasMadeFrom() {
    // `/output` parses the prompt from this text rather than taking its own
    // capture: a second read is a different moment, and the whole point of gating
    // on the supervisor is that the verdict and the text agree.
    let dialog = supervisorFreshClaudePane.replacingOccurrences(
        of: "─────────────────────────────────────── ↯ ─",
        with: [
            "❯ delete the build directory",
            "",
            " Do you want to proceed?",
            " ❯ 1. Yes",
            "   2. No",
            "",
            "─────────────────────────────────────── ↯ ─"
        ].joined(separator: "\n")
    )

    let result = makeTestSupervisor(visibleText: dialog, processes: [supervisorTestAgentProcess("claude")]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .executing
    )

    #expect(result?.status == .asking)
    #expect(result?.visibleText == dialog)
}

@Test func supervisorCarriesNoCaptureForVerdictsMadeFromTheProcessTreeAlone() {
    // A pane whose agent has exited was never read, so there is no text a prompt
    // could honestly be attributed to.
    let closed = makeTestSupervisor(pane: supervisorTestPane(isDead: true)).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .running
    )
    let busy = makeTestSupervisor(
        visibleText: "",
        processes: [
            supervisorTestAgentProcess("claude"),
            supervisorTestProcess(pid: 102, parentPID: 101, commandName: "/usr/bin/make", arguments: "make -j8", elapsed: 3)
        ]
    ).inspect(tmuxSessionName: "agent", launchCommand: "claude", currentStatus: .running)

    #expect(closed?.status == .closed)
    #expect(closed?.visibleText == nil)
    #expect(busy?.status == .executing)
    #expect(busy?.visibleText == nil)
}

@Test func supervisorSkipsTheCaptureWhileThePaneProducesNoOutput() {
    // The dominant per-tick cost at scale is one `tmux capture-pane` fork/exec
    // per live agent pane. A pane that has produced no output since the last
    // capture cannot classify differently, so the supervisor must reuse the text
    // it already has rather than spawn for it again.
    let backend = CountingSupervisorBackend(visibleText: "❯ ")
    let cache = SupervisorInspectionCache()
    let supervisor = AgentSupervisor(
        backend: backend,
        processTable: ProcessTable(rows: [supervisorTestAgentProcess("claude")]),
        cache: cache
    )
    let quiet = Date(timeIntervalSince1970: 1_000)

    func inspect(activityAt: Date) -> AgentSupervisor.Result? {
        supervisor.inspect(
            tmuxSessionName: "banyan-test",
            launchCommand: "claude",
            currentStatus: .running,
            paneSnapshot: supervisorTestPane(lastActivityAt: activityAt)
        )
    }

    #expect(inspect(activityAt: quiet)?.status == .needInput)
    #expect(inspect(activityAt: quiet)?.status == .needInput)
    #expect(inspect(activityAt: quiet)?.status == .needInput)
    #expect(backend.captureCount == 1)

    // New output invalidates it, and the fresh text decides the status.
    backend.visibleText = "esc to interrupt"
    #expect(inspect(activityAt: quiet.addingTimeInterval(1))?.status == .executing)
    #expect(backend.captureCount == 2)
}

@Test func supervisorWithoutACacheAlwaysCapturesThePane() {
    // The prompt-answering path builds its own supervisor with no cache: it must
    // read the pane it is about to type into, not a memo of it.
    let backend = CountingSupervisorBackend(visibleText: "❯ ")
    let supervisor = AgentSupervisor(
        backend: backend,
        processTable: ProcessTable(rows: [supervisorTestAgentProcess("claude")])
    )
    let quiet = Date(timeIntervalSince1970: 1_000)

    for _ in 0..<3 {
        _ = supervisor.inspect(
            tmuxSessionName: "banyan-test",
            launchCommand: "claude",
            currentStatus: .running,
            paneSnapshot: supervisorTestPane(lastActivityAt: quiet)
        )
    }

    #expect(backend.captureCount == 3)
}

private final class CountingSupervisorBackend: AgentSupervisorBackend, @unchecked Sendable {
    var visibleText: String
    private(set) var captureCount = 0

    init(visibleText: String) {
        self.visibleText = visibleText
    }

    func hasSession(named name: String) -> Bool { true }

    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? { nil }

    func captureVisibleText(paneID: String, lineLimit: Int) -> String {
        captureCount += 1
        return visibleText
    }
}

/// The status dot must stay as fresh as it was. Reusing a capture cannot delay
/// `idle -> executing`, because that transition is decided by the process tree —
/// a command appearing below the agent — and the process tree is read afresh
/// every observation. Proven here with a warm cache: the pane is silent
/// throughout (a command that prints nothing yet bumps no tmux activity), and
/// the very next inspection still reports `.executing` without re-reading it.
@Test func cachedPaneStillReportsExecutingTheMomentAProcessAppears() {
    let backend = CountingSupervisorBackend(visibleText: "❯ ")
    let cache = SupervisorInspectionCache()
    let quiet = Date(timeIntervalSince1970: 1_000)

    func inspect(processes: [ProcessInfoRow]) -> AgentSupervisor.Result? {
        AgentSupervisor(
            backend: backend,
            processTable: ProcessTable(rows: processes),
            cache: cache
        ).inspect(
            tmuxSessionName: "banyan-test",
            launchCommand: "claude",
            currentStatus: .running,
            paneSnapshot: supervisorTestPane(lastActivityAt: quiet)
        )
    }

    let idle = [supervisorTestAgentProcess("claude")]
    #expect(inspect(processes: idle)?.status == .needInput)
    #expect(backend.captureCount == 1)

    let working = idle + [
        supervisorTestProcess(pid: 102, parentPID: 101, commandName: "/usr/bin/make", arguments: "make", elapsed: 1)
    ]
    #expect(inspect(processes: working)?.status == .executing)
    #expect(inspect(processes: idle)?.status == .needInput)
    // Still one capture: neither transition needed the pane re-read.
    #expect(backend.captureCount == 1)
}

@Test func supervisorPublishesLiveProcessIDsForExitDrivenObservation() {
    let result = makeTestSupervisor(
        processes: [
            supervisorTestAgentProcess("codex"),
            supervisorTestProcess(pid: 102, parentPID: 101, commandName: "make", arguments: "make", elapsed: 3),
            supervisorTestProcess(pid: 103, parentPID: 101, commandName: "make", arguments: "make", elapsed: 3, state: "Z")
        ]
    ).inspect(tmuxSessionName: "agent", launchCommand: "codex", currentStatus: .executing)
    #expect(result?.status == .executing)
    #expect(result?.liveProcessIDs == [101, 102])
}
