import Foundation
import Testing
@testable import BanyanCore

@Test func supervisorFastWindowExpiresEvenWhileStatusStaysExecuting() {
    let fixture = SupervisorCadenceFixture(count: 7)
    for second in stride(from: 0, through: 10, by: 2) { fixture.step(at: Double(second)) }
    #expect(fixture.states.values.allSatisfy { $0.nextDueAt > fixture.date(12) })
    #expect(fixture.nextInterval(at: 10) > 2)
    fixture.step(at: 12)
    #expect(fixture.processSnapshots == 6) // No new expensive inspection.
    #expect(fixture.backend.captures == 7) // Unchanged text was cached throughout.
}

@Test func supervisorSevenStableExecutingSessionsReduceInspectionAndScheduledWakeups() {
    let fixture = SupervisorCadenceFixture(count: 7)
    var second: TimeInterval = 0
    while second < 180 {
        fixture.step(at: second)
        second += fixture.nextInterval(at: second)
    }
    // Previously all seven executing rows were classified every two seconds:
    // 90 process snapshots/list-panes and 630 per-session classifications.
    #expect(fixture.backend.batches < 20)
    #expect(fixture.processSnapshots < 15)
    #expect(fixture.observations < 105)
    #expect(fixture.backend.captures == 7)
    #expect(fixture.backend.singlePaneLookups == 0)
    #expect(fixture.states.values.allSatisfy { $0.lastObservation?.status == .executing })
}

@Test func supervisorSelectedAttachedSessionKeepsBaseLatencyWhilePeersBackOff() {
    let fixture = SupervisorCadenceFixture(count: 7, selectedID: "0")
    for second in stride(from: 0, through: 100, by: 2) { fixture.step(at: Double(second)) }
    #expect(fixture.nextInterval(at: 100) == 2)
    #expect(fixture.states["0"]?.nextDueAt == fixture.date(102))
    #expect(fixture.observations < 160) // 357 without per-session deferral.
    fixture.backend.setText("Can I edit these files?", for: "0", activityAt: fixture.date(101))
    fixture.step(at: 102)
    #expect(fixture.states["0"]?.lastObservation?.status == .asking)
}

@Test func supervisorHiddenEvictedSessionsNoticeAttentionThroughBatchedActivity() {
    let fixture = SupervisorCadenceFixture(count: 7, baseInterval: 30)
    for second in stride(from: 0, through: 90, by: 30) { fixture.step(at: Double(second)) }
    #expect(fixture.states["0"]?.nextDueAt == fixture.date(150))
    // No PTY callback: only the tmux activity timestamp changes, on a session
    // whose classification is not due until 150. The 30s activity probe wakes it.
    fixture.backend.setText("Done. Enter your next prompt.", for: "0", activityAt: fixture.date(91))
    fixture.step(at: 120)
    #expect(fixture.states["0"]?.lastObservation?.status == .needInput)
    #expect(fixture.states["1"]?.nextDueAt == fixture.date(150))
    #expect(fixture.backend.captures == 8)
}

@Test func supervisorProcessExitWakesHiddenSessionWithoutOutput() {
    let fixture = SupervisorCadenceFixture(count: 7, baseInterval: 30)
    fixture.processes.append(.init(pid: 1002, parentPID: 1001, state: "S", elapsed: 5, commandName: "make", arguments: "make"))
    fixture.backend.setText("Done.", for: "0", activityAt: fixture.date(-100))
    for second in stride(from: 0, through: 90, by: 30) { fixture.step(at: Double(second)) }
    #expect(fixture.states["0"]?.lastObservation?.status == .executing)
    #expect(fixture.states["0"]?.lastObservation?.liveProcessIDs.contains(1002) == true)
    // This is the invalidation delivered by SupervisorProcessExitMonitor.
    fixture.processes.removeAll { $0.pid == 1002 }
    fixture.states["0"]?.noteActivity(at: fixture.date(91), invalidatesObservation: true)
    fixture.step(at: 93)
    #expect(fixture.states["0"]?.lastObservation?.status == .needInput)
    #expect(fixture.states["0"]?.lastObservation?.liveProcessIDs.contains(1002) == false)
}

@Test func supervisorEventsDuringInspectionSurviveOlderResults() {
    let fixture = SupervisorCadenceFixture(count: 1)
    fixture.step(at: 0)
    var state = fixture.states["0"]!
    let revision = state.revision
    let resultRevision = state.resultRevision
    state.noteActivity(at: fixture.date(1)) // PTY output does not suppress status results.
    #expect(state.resultRevision == resultRevision)
    state.record(state.lastObservation, pane: state.lastPane, startedRevision: revision,
                 at: fixture.date(5), baseInterval: 2, isSelectedAttached: false)
    #expect(state.nextDueAt == fixture.date(1))
    #expect(state.stableObservations == 0)
    state.noteActivity(at: fixture.date(6), invalidatesObservation: true)
    #expect(state.resultRevision != resultRevision) // A status/input/exit signal does.
}

@Test func supervisorInactiveSessionsRetainLongBackoffWithoutExtraActivityProbes() {
    let fixture = SupervisorCadenceFixture(count: 1, baseInterval: 6)
    fixture.backend.setText("Done.", for: "0", activityAt: fixture.date(-100))
    var second: TimeInterval = 0
    for _ in 0..<10 {
        fixture.step(at: second)
        second += fixture.nextInterval(at: second)
    }
    let state = fixture.states["0"]!
    #expect(state.lastObservation?.status == .needInput)
    #expect(state.nextProbeInterval(baseInterval: 6, status: .needInput, isSelectedAttached: false, at: fixture.date(second - 1)) < 2)
    #expect(state.nextDueAt.timeIntervalSince(fixture.date(0)) > 1000)
    #expect(fixture.backend.captures == 1)
}

@Test func supervisorStateChangesAndPaneResizeReopenFastWindow() {
    let fixture = SupervisorCadenceFixture(count: 1)
    for second in stride(from: 0, through: 10, by: 2) { fixture.step(at: Double(second)) }
    fixture.backend.setText("Can I continue?", for: "0", activityAt: fixture.date(11))
    fixture.step(at: 12)
    #expect(fixture.nextInterval(at: 12) == 2)
    #expect(fixture.states["0"]?.fastUntil == fixture.date(22))
    let pane = fixture.backend.panes["0"]!
    let resized = TmuxPaneSnapshot(paneID: pane.paneID, rootPID: pane.rootPID,
                                  currentCommand: pane.currentCommand, currentPath: pane.currentPath,
                                  isDead: false, isInMode: false, lastActivityAt: pane.lastActivityAt,
                                  width: 120, height: 40)
    #expect(fixture.states["0"]?.isDue(pane: resized, at: fixture.date(13)) == true)
}

@Test func supervisorSlowTickCoalescesDeadlinesAndRestsAfterCompletion() {
    var schedule = SessionSupervisorTickSchedule()
    let start = Date(timeIntervalSince1970: 0)
    let began = schedule.begin()
    #expect(began)
    for second in [2.0, 4.0, 6.0] {
        let overlapped = schedule.begin()
        #expect(!overlapped)
        #expect(schedule.nextFire(at: start.addingTimeInterval(second), interval: 2) == nil)
    }
    let completion = start.addingTimeInterval(7)
    schedule.finish(at: completion, minimumRest: 2)
    #expect(schedule.nextFire(at: completion, interval: 2) == start.addingTimeInterval(9))
    // A shorter activity deadline also respects the post-tick rest.
    #expect(schedule.nextFire(at: completion, interval: 1) == start.addingTimeInterval(9))
    #expect(schedule.nextFire(at: completion, interval: 30) == start.addingTimeInterval(37))
}

private final class SupervisorCadenceFixture {
    let backend: CadenceFixtureBackend
    let inputs: [SessionStatusObservationInput]
    let baseInterval: TimeInterval
    let selectedID: String?
    var states: [String: SessionSupervisorObservationState] = [:]
    var processes: [ProcessInfoRow]
    let cache = SupervisorInspectionCache()
    var processSnapshots = 0
    var observations = 0

    init(count: Int, baseInterval: TimeInterval = 2, selectedID: String? = nil) {
        self.baseInterval = baseInterval
        self.selectedID = selectedID
        inputs = (0..<count).map {
            .init(id: String($0), tmuxSessionName: String($0), command: "codex", status: .executing, isAwaitingAttach: false)
        }
        processes = (0..<count).map {
            .init(pid: 1001 + $0 * 10, parentPID: 1000 + $0 * 10, state: "S", elapsed: 5, commandName: "codex", arguments: "codex")
        }
        backend = CadenceFixtureBackend(count: count)
    }

    func date(_ second: TimeInterval) -> Date { Date(timeIntervalSince1970: 1000 + second) }

    func step(at second: TimeInterval) {
        let now = date(second)
        let panes = backend.primaryPaneSnapshots(named: Set(inputs.map(\.tmuxSessionName)))
        let due = inputs.filter { states[$0.id]?.isDue(pane: panes[$0.tmuxSessionName], at: now) != false }
        guard !due.isEmpty else { return }
        processSnapshots += 1
        let results = SessionStatusSynchronizer(backend: backend, processTable: .init(rows: processes), cache: cache)
            .observe(due, paneSnapshots: panes)
        observations += results.count
        for result in results {
            let revision = states[result.id]?.revision ?? 0
            states[result.id, default: .init()].record(
                result, pane: panes[result.id], startedRevision: revision, at: now,
                baseInterval: baseInterval, isSelectedAttached: result.id == selectedID
            )
        }
    }

    func nextInterval(at second: TimeInterval) -> TimeInterval {
        states.map { id, state in
            state.nextProbeInterval(baseInterval: baseInterval, status: state.lastObservation!.status,
                                    isSelectedAttached: id == selectedID, at: date(second))
        }.min() ?? baseInterval
    }
}

private final class CadenceFixtureBackend: AgentSupervisorBackend, @unchecked Sendable {
    var panes: [String: TmuxPaneSnapshot]
    private var textByPane: [String: String]
    private let lock = NSLock()
    private var captureCount = 0
    var captures: Int { lock.lock(); defer { lock.unlock() }; return captureCount }
    var batches = 0
    var singlePaneLookups = 0

    init(count: Int) {
        panes = Dictionary(uniqueKeysWithValues: (0..<count).map {
            (String($0), TmuxPaneSnapshot(paneID: "%\($0)", rootPID: 1000 + $0 * 10,
                                         currentCommand: "zsh", currentPath: "/tmp", isDead: false, isInMode: false,
                                         lastActivityAt: Date(timeIntervalSince1970: 900), width: 80, height: 24))
        })
        textByPane = Dictionary(uniqueKeysWithValues: (0..<count).map { ("%\($0)", "Esc to interrupt") })
    }

    func hasSession(named name: String) -> Bool { panes[name] != nil }
    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? {
        singlePaneLookups += 1
        return panes[name]
    }
    func primaryPaneSnapshots(named names: Set<String>) -> [String: TmuxPaneSnapshot] {
        batches += 1
        return panes.filter { names.contains($0.key) }
    }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        captureCount += 1
        return textByPane[paneID] ?? ""
    }
    func setText(_ text: String, for id: String, activityAt: Date) {
        let old = panes[id]!
        panes[id] = TmuxPaneSnapshot(paneID: old.paneID, rootPID: old.rootPID, currentCommand: old.currentCommand,
                                     currentPath: old.currentPath, isDead: false, isInMode: false,
                                     lastActivityAt: activityAt, width: old.width, height: old.height)
        textByPane[old.paneID] = text
    }
}
