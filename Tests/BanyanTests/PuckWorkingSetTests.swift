import AppKit
import BanyanCore
import Foundation
import SwiftUI
import Testing
@testable import Banyan

/// The sidebar is the user's Puck working set. `puckd` also holds sessions
/// other frontends and background tasks started; those stay out of the
/// sidebar and its shortcuts until the user opens one, and their asks stay
/// discoverable. Hiding a row never touches the daemon's session.

private func backgroundSummaries(_ count: Int, cwd: String) -> [PuckSessionSummary] {
    (0..<count).map { index in
        puckSummary(id: String(format: "00000000-0000-4000-8000-%012d", index), cwd: cwd,
                    position: index.isMultiple(of: 3) ? "hibernated" : "idle", historyItems: 4)
    }
}

@MainActor
@Test func backgroundDiscoveryAddsNoRowsOrShortcuts() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    defer { store.stopPuckObservation() }
    store.sidebarScope = .all
    store.loadPersistedSessionsIfNeeded()
    let summaries = backgroundSummaries(40, cwd: fixture.project.path)
    summaries.forEach { daemon.put($0) }

    // A catalog reconciliation...
    store.applyPuckSummaries(try daemon.list())
    #expect(store.sessions.isEmpty)
    #expect(store.unifiedSidebarGroups.flatMap(\.items).isEmpty)
    #expect(store.sidebarSessionIDs(limit: 10).isEmpty)
    #expect(store.backgroundPuckSummaries.count == 40)

    // ...and a watch snapshot both leave them in the background.
    store.startPuckObservation()
    try await waitForPuckState { daemon.watchCount == 1 }
    daemon.publishWatch(.snapshot(summaries + [puckSummary(id: "late-arrival", cwd: fixture.project.path, position: "running")]))
    try await waitForPuckState { store.backgroundPuckSummaries.count == 41 }
    #expect(store.sessions.isEmpty)
    #expect(store.sidebarSessionIDs(limit: 10).isEmpty)
    #expect(store.showsPuckBackgroundEntry)
    // Live work sorts ahead of finished sessions in the background list.
    #expect(store.backgroundPuckSummaries.first?.id == "late-arrival")
}

@MainActor
@Test func explicitlyOpeningABackgroundSessionGivesOneUsableRow() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    store.sidebarScope = .all
    let summary = puckSummary(cwd: fixture.project.path, historyItems: 1)
    daemon.put(summary, transcript: [PuckSessionEvent(cursor: 1, kind: "turn_done", text: "earlier answer")])
    store.applyPuckSummaries(try daemon.list())

    store.openPuckSession(id: summary.id)
    store.openPuckSession(id: summary.id)

    let session = try #require(store.sessions.first as? PuckSession)
    #expect(store.sessions.count == 1)
    #expect(store.selectedSessionID == session.id)
    #expect(store.sidebarSessionIDs(limit: 10) == [session.id])
    #expect(store.backgroundPuckSummaries.isEmpty)
    #expect(session.status == .review)

    session.startFollowing()
    defer { session.stopFollowing() }
    try await waitForPuckState { session.followState == .following }
    #expect(session.events.map(\.displayText) == ["earlier answer"])
    session.send("continue from here")
    try await waitForPuckState { daemon.turns.count == 1 }
    #expect(daemon.turns == [FakePuckDaemon.Turn(id: session.id, prompt: "continue from here")])
}

@MainActor
@Test func theWorkingSetSurvivesRestartAndWatchReconnect() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let opened = puckSummary(id: "opened", cwd: fixture.project.path, historyItems: 2)
    let hidden = puckSummary(id: "hidden", cwd: fixture.project.path, historyItems: 2)
    let untouched = puckSummary(id: "untouched", cwd: fixture.project.path, historyItems: 2)
    [opened, hidden, untouched].forEach { daemon.put($0) }
    let store = fixture.makeStore()
    store.loadPersistedSessionsIfNeeded()
    store.applyPuckSummaries(try daemon.list())
    store.openPuckSession(id: opened.id)
    store.openPuckSession(id: hidden.id)
    try store.remove(id: hidden.id)
    store.flushPendingSessionSaves()

    let relaunched = fixture.makeStore()
    defer { relaunched.stopPuckObservation() }
    relaunched.loadPersistedSessionsIfNeeded()
    #expect(relaunched.sessions.map(\.id) == [opened.id])
    relaunched.applyPuckSummaries(try daemon.list())
    relaunched.startPuckObservation()
    try await waitForPuckState { relaunched.isPuckWatchConnected }
    daemon.dropWatchers()
    try await waitForPuckState { daemon.watchCount >= 2 && relaunched.isPuckWatchConnected }
    daemon.publishWatch(.snapshot(try daemon.list()))
    try await Task.sleep(for: .milliseconds(100))

    #expect(relaunched.sessions.map(\.id) == [opened.id])
    #expect(Set(relaunched.backgroundPuckSummaries.map(\.id)) == [hidden.id, untouched.id])
}

/// Rows written by builds that adopted every listed session, as they sit in
/// `state.sqlite` before this build first launches.
private func legacyRow(_ id: String, cwd: String, status: SessionStatus = .needInput,
                       titlePinned: Bool = false, parent: String? = nil) -> SessionSnapshot {
    SessionSnapshot(id: id, tmuxSessionName: nil, title: titlePinned ? "Release notes" : "Codex session",
                    reportedTitle: nil, isTitlePinned: titlePinned, cwd: cwd, command: "", status: status,
                    tone: .yellow, parentSessionID: parent, createdAt: Date(), updatedAt: Date(),
                    backend: .puck, puck: PuckSessionBinding(provider: "codex"))
}

@MainActor
@Test func legacyImportedRowsCanBeRemovedTogetherWithoutTouchingTheDaemon() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let cwd = fixture.project.path
    let clutter = (0..<6).map { "clutter-\($0)" }
    let kept = ["named", "selected", "child"]
    fixture.persistence.save(clutter.map { legacyRow($0, cwd: cwd) } + [
        legacyRow("named", cwd: cwd, titlePinned: true),
        legacyRow("selected", cwd: cwd),
        legacyRow("child", cwd: cwd, parent: "named"),
    ])
    let running = puckSummary(id: "clutter-0", cwd: cwd, position: "running", historyItems: 3)
    daemon.put(running)
    for id in clutter.dropFirst() + kept { daemon.put(puckSummary(id: id, cwd: cwd, historyItems: 3)) }

    let store = fixture.makeStore()
    store.loadPersistedSessionsIfNeeded()
    store.userSelect(id: "selected")
    // Earlier builds read history as needing input; nothing here asked.
    #expect(store.sessions.allSatisfy { $0.status != .needInput })
    #expect(store.legacyPuckSessionIDs == Set(clutter + kept))
    // Generic titles are not evidence: the user chooses among unknown rows,
    // while rows with evidence of deliberate use are not offered.
    #expect(Set(store.legacyPuckCleanupCandidates.map(\.id)) == Set(clutter))
    store.applyPuckSummaries(try daemon.list())
    #expect(store.agentAdmission.running.contains("clutter-0"))

    let removed = store.removeLegacyPuckRows(ids: Set(clutter + kept))
    #expect(removed == clutter.count)
    #expect(Set(store.sessions.map(\.id)) == Set(kept))
    #expect(daemon.cancellations.isEmpty)
    #expect(Set(try daemon.list().map(\.id)) == Set(clutter + kept))
    // The hidden turn keeps its slot until the daemon reports it finished.
    #expect(store.agentAdmission.running.contains("clutter-0"))
    #expect(Set(store.backgroundPuckSummaries.map(\.id)) == Set(clutter))

    // Reconciliation does not bring them back, nor does a relaunch.
    store.applyPuckSummaries(try daemon.list())
    #expect(Set(store.sessions.map(\.id)) == Set(kept))
    store.flushPendingSessionSaves()
    let relaunched = fixture.makeStore()
    relaunched.loadPersistedSessionsIfNeeded()
    relaunched.applyPuckSummaries(try daemon.list())
    #expect(Set(relaunched.sessions.map(\.id)) == Set(kept))
    #expect(relaunched.legacyPuckSessionIDs == Set(kept))
    // Any removed session is still the daemon's, and opens again.
    relaunched.openPuckSession(id: "clutter-3")
    #expect(relaunched.sessions.contains { $0.id == "clutter-3" && $0.status == .review })
}

@MainActor
@Test func rowsCreatedOrOpenedByThisBuildAreNeverLegacy() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    fixture.persistence.save([legacyRow("older", cwd: fixture.project.path)])
    daemon.put(puckSummary(id: "older", cwd: fixture.project.path))
    let store = fixture.makeStore()
    store.loadPersistedSessionsIfNeeded()
    #expect(store.legacyPuckSessionIDs == ["older"])
    let created = try await store.createPuckSession(binding: PuckSessionBinding(provider: "codex"),
                                                    cwd: fixture.project.path, select: false)
    // Opening the older row from a link says it is the user's work.
    store.openPuckSession(id: "older")
    #expect(store.legacyPuckSessionIDs.isEmpty)
    store.flushPendingSessionSaves()

    let relaunched = fixture.makeStore()
    relaunched.loadPersistedSessionsIfNeeded()
    #expect(Set(relaunched.sessions.map(\.id)) == ["older", created.id])
    #expect(relaunched.legacyPuckSessionIDs.isEmpty)
    #expect(relaunched.legacyPuckCleanupCandidates.isEmpty)
}

@MainActor
@Test func backgroundAsksStayDiscoverableAndAnswerable() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let approval = PuckPendingApproval(callID: "call-7", tool: "shell", arguments: "make release", expiresAtMS: .max)
    let asking = puckSummary(id: "asking", cwd: fixture.project.path, position: "parked", pendingApproval: approval)
    let quiet = backgroundSummaries(5, cwd: fixture.project.path)
    (quiet + [asking]).forEach { daemon.put($0) }
    store.applyPuckSummaries(try daemon.list())

    #expect(store.sessions.isEmpty)
    #expect(store.backgroundPuckAskCount == 1)
    #expect(store.backgroundPuckSummaries.first?.id == asking.id)
    let ask = PuckSessionEvent(cursor: 9, kind: "approval_pending", callID: "call-7", route: "interactive")
    #expect(store.routePuckWatchEvent(id: asking.id, event: ask))
    // A stale call is not an ask anyone needs to hear about.
    #expect(!store.routePuckWatchEvent(id: asking.id, event: PuckSessionEvent(
        cursor: 10, kind: "approval_pending", callID: "call-6", route: "interactive")))

    // Opening it from the background list reaches the existing approval flow.
    store.openPuckSession(id: asking.id)
    let session = try #require(store.sessions.first as? PuckSession)
    #expect(session.status == .asking)
    #expect(session.pendingApproval?.callID == "call-7")
    session.decide("approve")
    try await waitForPuckState { daemon.decisions == ["approve"] }

    // Hiding a row with an ask still leaves the ask discoverable.
    let second = PuckPendingApproval(callID: "call-8", tool: "shell", arguments: "deploy", expiresAtMS: .max)
    daemon.put(asking.with(position: "parked", pendingApproval: .some(second)))
    store.applyPuckSummaries(try daemon.list())
    try store.remove(id: asking.id)
    #expect(store.backgroundPuckAskCount == 1)
    #expect(store.routePuckWatchEvent(id: asking.id, event: PuckSessionEvent(
        cursor: 11, kind: "approval_pending", callID: "call-8", route: "interactive")))
}

@MainActor
@Test func hidingARowLeavesItsTurnAndHistoryInTheDaemon() async throws {
    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    let store = fixture.makeStore()
    let summary = puckSummary(cwd: fixture.project.path, historyItems: 1)
    daemon.put(summary, transcript: [PuckSessionEvent(cursor: 1, kind: "turn_done", text: "kept")])
    store.applyPuckSummaries(try daemon.list())
    let session = try #require(store.openPuckSession(summary, select: false))
    try await session.startTurn("long task")
    #expect(session.status == .executing)

    store.requestClose(id: session.id)
    store.confirmPendingClose()
    #expect(session.status == .closed)
    try store.remove(id: session.id)
    #expect(daemon.cancellations.isEmpty)
    #expect(try daemon.get(session.id).position == "running")
    #expect(store.agentAdmission.running.contains(session.id))
    #expect(store.backgroundPuckSummaries.map(\.id) == [session.id])

    store.openPuckSession(id: session.id)
    let reopened = try #require(store.sessions.first as? PuckSession)
    #expect(reopened === session)
    #expect(reopened.status == .executing)
    reopened.startFollowing()
    defer { reopened.stopFollowing() }
    try await waitForPuckState { reopened.followState == .following }
    #expect(reopened.events.map(\.displayText) == ["kept"])
}

@MainActor
@Test func backgroundEntryStaysCompactAndRendersItsSurfaces() throws {
    #expect(PuckBackgroundSessionsEntry.label(count: 46, askCount: 0, cleanupCount: 0) == "46 background Puck sessions")
    #expect(PuckBackgroundSessionsEntry.label(count: 46, askCount: 2, cleanupCount: 0) == "2 background Puck asks")
    #expect(PuckBackgroundSessionsEntry.label(count: 0, askCount: 0, cleanupCount: 1) == "Review 1 auto-added Puck row")

    let daemon = FakePuckDaemon()
    let fixture = try PuckStoreFixture(daemon: daemon)
    fixture.persistence.save([legacyRow("older", cwd: fixture.project.path)])
    let store = fixture.makeStore()
    let empty = NSHostingView(rootView: PuckBackgroundSessionsEntry(store: store))
    empty.layoutSubtreeIfNeeded()
    #expect(!store.showsPuckBackgroundEntry)
    #expect(empty.fittingSize.height == 0)

    store.loadPersistedSessionsIfNeeded()
    store.applyPuckSummaries(backgroundSummaries(30, cwd: fixture.project.path))
    #expect(store.showsPuckBackgroundEntry)
    let entry = NSHostingView(rootView: PuckBackgroundSessionsEntry(store: store))
    entry.layoutSubtreeIfNeeded()
    // One line, however many sessions sit behind it.
    #expect(entry.fittingSize.height > 0 && entry.fittingSize.height < 60)
    let list = NSHostingView(rootView: PuckBackgroundSessionsList(store: store) {})
    list.layoutSubtreeIfNeeded()
    #expect(list.fittingSize.height > 0)
    let sheet = NSHostingView(rootView: PuckCleanupSheet().environmentObject(store))
    sheet.layoutSubtreeIfNeeded()
    #expect(sheet.fittingSize.width > 0)
}
