import AppKit
import BanyanCore
import SwiftUI
import Testing
@testable import Banyan

@Suite @MainActor struct SessionWorkUITests {
    @Test func equatableRowsKeepSessionSelectionAndWorkUpdatesLive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host = HostRuntimeContext(environment: ["PATH": "/usr/bin:/bin"], homeDirectory: root, currentDirectory: root.path)
        let session = BanyanSession(id: "row", title: "Original title", cwd: root.path,
            command: "", status: .needInput, telemetry: banyanTestTelemetry, host: host)
        session.isTitlePinned = true
        let selection = SessionSelection()
        let shortcuts = SessionJumpShortcuts()
        shortcuts.updateSessionIDs(["other", session.id])
        shortcuts.updateVisibleSessionIDs(["other", session.id])
        let overviewStatus = WorkOverviewStatus()
        let workState = SessionWorkState()
        func row() -> SessionRow {
            SessionRow(session: session, selection: selection, launchProfile: nil, depth: 0,
                titleOverride: nil, isHistory: false, isParent: false, showsDisclosureGutter: false,
                isCollapsed: false, hiddenChildCount: 0, jumpKeyLabel: "", jumpShortcuts: shortcuts,
                workState: workState,
                overviewStatus: overviewStatus, actionOwner: ObjectIdentifier(selection),
                refreshWork: {}, openWorkSession: { _ in }, onSelect: {}, onToggleCollapse: {}, onRevealHidden: {},
                onClose: {}, onRestart: {}, onRespawn: {}, onRecover: {}, isHandoffAvailable: false,
                isHandoffPending: false, onHandoff: {}, onCodexRemoteHandoff: {}, onRemove: {},
                onChooseParent: {}, onToggleSuspended: {}, onSetFrozen: { _ in }, onSetDeepSuspended: { _ in },
                onFocusTerminal: {}, onReopenHistory: {})
        }
        let original = row()
        #expect(original == row()) // Fresh action closures do not dirty an unchanged row.
        overviewStatus.updatedAt = "2026-01-01T01:00:00Z"
        overviewStatus.error = "Refresh unavailable"
        #expect(original == row()) // Only an open details popup observes this metadata.
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 420, height: 48),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: original.equatable())
        window.contentView = view
        func pixels() async throws -> Data {
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        let initial = try await pixels()
        shortcuts.updateVisibleSessionIDs([session.id])
        #expect(original == row()) // Viewport changes only dirty the badge.
        #expect(shortcuts.sessionID(for: 1) == session.id)
        let remapped = try await pixels()
        #expect(remapped != initial)
        session.title = "Changed title is visible"
        let renamed = try await pixels()
        #expect(renamed != remapped)
        selection.selectedSessionID = session.id
        let selected = try await pixels()
        #expect(selected != renamed)
        let summary = try #require(SessionWorkTree.summaries(nodes: [
            .init(id: session.id, parentID: nil, title: session.title, status: session.status,
                workflow: .init(owner: "workit", jobID: "job", revision: 1, state: .needsYou))
        ], overview: nil)[session.id])
        workState.update(summary)
        #expect(original == row()) // The row's own observation bypasses parent equality.
        let updatedWork = try await pixels()
        #expect(updatedWork != selected)
        selection.selectedSessionID = "another-row"
        let deselected = try await pixels()
        #expect(deselected != updatedWork)
        selection.requestRenameSelectedSession()
        #expect(try await pixels() == deselected) // A rename event for another row is ignored.
        selection.selectedSessionID = session.id
        let reselected = try await pixels()
        selection.requestRenameSelectedSession()
        #expect(try await pixels() != reselected) // The selected row still enters inline rename.
    }

    @Test func compactSessionTreeAndDetailsRenderWithoutLiveServices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("banyan-session-work-render")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = HostRuntimeContext(environment: ["PATH": "/usr/bin:/bin"], homeDirectory: root, currentDirectory: root.path)
        let parent = BanyanSession(id: "group", title: "Database cleanup", cwd: root.path, command: "", status: .needInput,
            telemetry: banyanTestTelemetry, host: host)
        let worker = BanyanSession(id: "worker", title: "Restore interrupted uploads",
            titleURL: "https://github.com/example/project/issues/1", cwd: root.path, command: "", status: .needInput,
            parentSessionID: parent.id, agentProvider: .codex, telemetry: banyanTestTelemetry, host: host)
        worker.workflow = .init(owner: "workit", jobID: "upload", revision: 3, state: .needsYou)
        let review = BanyanSession(id: "review", title: "Review retry behavior", cwd: root.path, command: "", status: .executing,
            parentSessionID: worker.id, agentProvider: .codex, telemetry: banyanTestTelemetry, host: host)
        let job: [String: Any] = ["id": "upload", "revision": 3, "sessionID": "worker", "title": worker.title,
            "stage": "needs-you", "group": "needs-you", "detail": "PR merged. The previous stop is still retained.",
            "display": ["kind": "blocked", "label": "Tool error"], "stopReason": "The conversation control command timed out.",
            "createdAt": "2026-01-01T00:00:00Z", "lastProgressAt": "2026-01-01T00:00:00Z",
            "progress": ["passed": 2, "total": 3], "nextAction": "Inspect the original conversation and repair the connection. Check whether the previous continuation arrived before resuming.",
            "issueURL": "https://github.com/example/project/issues/1", "prURL": "https://github.com/example/project/pull/2",
            "evidence": ["https://github.com/example/project/actions/runs/1"]]
        let feed = try WorkitOverview.decode(JSONSerialization.data(withJSONObject: ["version": 1, "generatedAt": "2026-01-01T00:01:00Z", "total": 1, "truncated": false, "jobs": [job]]))
        let sessions = [parent, worker, review]
        let summaries = SessionWorkTree.summaries(nodes: sessions.map {
            .init(id: $0.id, parentID: $0.parentSessionID, title: $0.title, status: $0.status, workflow: $0.workflow)
        }, overview: feed)
        let selection = SessionSelection()
        let overviewStatus = WorkOverviewStatus()
        overviewStatus.updatedAt = feed.generatedAt
        let workStates = summaries.mapValues { SessionWorkState(summary: $0) }
        let rows = VStack(alignment: .leading, spacing: 8) {
            Text("example/project").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                SessionRow(session: session, selection: selection, launchProfile: nil, depth: index,
                    titleOverride: nil, isHistory: false, isParent: index < 2, showsDisclosureGutter: true,
                    isCollapsed: false, hiddenChildCount: 0, jumpKeyLabel: String(index),
                    workState: workStates[session.id]!, overviewStatus: overviewStatus,
                    actionOwner: ObjectIdentifier(selection),
                    refreshWork: {}, openWorkSession: { _ in }, onSelect: {}, onToggleCollapse: {}, onRevealHidden: {},
                    onClose: {}, onRestart: {}, onRespawn: {}, onRecover: {}, isHandoffAvailable: false,
                    isHandoffPending: false, onHandoff: {}, onCodexRemoteHandoff: {}, onRemove: {},
                    onChooseParent: {}, onToggleSuspended: {},
                    onSetFrozen: { _ in }, onSetDeepSuspended: { _ in }, onFocusTerminal: {}, onReopenHistory: {}).equatable()
            }
        }.padding(12)
        try await render(rows, size: NSSize(width: 340, height: 170), to: root.appendingPathComponent("sessions.png"))
        let details = SessionWorkDetailsView(summary: try #require(summaries[worker.id]), error: nil,
            updatedAt: feed.generatedAt, refresh: {}, openSession: { _ in })
        try await render(details, size: NSSize(width: 400, height: 600), to: root.appendingPathComponent("details.png"))
        let recovery = SessionWorkTree.summaries(nodes: sessions.map {
            .init(id: $0.id, parentID: $0.parentSessionID, title: $0.title, status: $0.status,
                  workflow: $0.workflow, recoveryError: $0.id == parent.id)
        }, overview: feed)
        let recoveryParent = try #require(recovery[parent.id])
        #expect(!recoveryParent.own.managed && recoveryParent.own.needsAttention)
        try await render(SessionWorkDetailsView(summary: recoveryParent, error: nil, updatedAt: nil,
            refresh: {}, openSession: { _ in }), size: NSSize(width: 400, height: 400),
            to: root.appendingPathComponent("recovery-parent.png"))
    }

    private func render<V: View>(_ content: V, size: NSSize, to url: URL) async throws {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -2000, y: -2000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        let view = NSHostingView(rootView: content.preferredColorScheme(.dark).background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view; view.frame = NSRect(origin: .zero, size: size)
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 2000)
        try png.write(to: url)
    }
}
