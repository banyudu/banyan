import AppKit
import BanyanCore
import Foundation
import SwiftUI
import Testing
@testable import Banyan

@MainActor
@Suite struct SessionCostHoverUITests {
    @Test func constructionDoesNotStartReadingTheTranscript() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("banyan-cost-hover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = HostRuntimeContext(
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: root,
            currentDirectory: root.path
        )
        let session = BanyanSession(
            id: "cost-row",
            title: "A row with a long enough title to keep the trailing edge clear",
            cwd: root.path,
            command: "",
            status: .needInput,
            telemetry: banyanTestTelemetry,
            host: host
        )
        let selection = SessionSelection()
        let workState = SessionWorkState()
        let overviewStatus = WorkOverviewStatus()
        var sourceCalls = 0
        let access = SessionCostAccess(
            source: {
                sourceCalls += 1
                return SessionCostTranscriptSource(
                    provider: .codex,
                    transcriptURL: root.appendingPathComponent("unused.jsonl"),
                    sessionKey: "codex:cost-row"
                )
            },
            estimate: { _ in .unavailable(.noUsage) }
        )
        let row = SessionRow(
            session: session,
            selection: selection,
            launchProfile: nil,
            depth: 0,
            titleOverride: nil,
            isHistory: false,
            isParent: false,
            showsDisclosureGutter: false,
            isCollapsed: false,
            hiddenChildCount: 0,
            jumpKeyLabel: "",
            workState: workState,
            overviewStatus: overviewStatus,
            actionOwner: ObjectIdentifier(selection),
            refreshWork: {},
            openWorkSession: { _ in },
            onSelect: {},
            onToggleCollapse: {},
            onRevealHidden: {},
            onClose: {},
            onRestart: {},
            onRespawn: {},
            onRecover: {},
            isHandoffAvailable: false,
            isHandoffPending: false,
            onHandoff: {},
            onCodexRemoteHandoff: {},
            onRemove: {},
            onChooseParent: {},
            onToggleSuspended: {},
            onSetFrozen: { _ in },
            onSetDeepSuspended: { _ in },
            onFocusTerminal: {},
            onReopenHistory: {},
            sessionCost: access
        )

        let size = NSSize(width: 420, height: 48)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -2_000, y: -2_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: row.equatable())
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        window.acceptsMouseMovedEvents = true
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        #expect(sourceCalls == 0)
    }

    @Test func gutterOwnsOnlyTheReservedTrailingStrip() {
        let width: CGFloat = 240
        let gutter = SessionRowHoverRegion.costGutterWidth

        #expect(SessionRowHoverRegion.region(
            at: CGPoint(x: width - gutter - 0.5, y: 12),
            rowWidth: width,
            hasSessionCost: true
        ) == .row)
        #expect(SessionRowHoverRegion.region(
            at: CGPoint(x: width - gutter, y: 12),
            rowWidth: width,
            hasSessionCost: true
        ) == .costGutter)
        #expect(SessionRowHoverRegion.region(
            at: CGPoint(x: width - 1, y: 12),
            rowWidth: width,
            hasSessionCost: true
        ) == .costGutter)
        #expect(SessionRowHoverRegion.region(
            at: CGPoint(x: width - 1, y: 12),
            rowWidth: width,
            hasSessionCost: false
        ) == .row)
        #expect(SessionRowHoverRegion.region(
            at: nil,
            rowWidth: width,
            hasSessionCost: true
        ) == nil)
        #expect(SessionRowHoverRegion.region(
            at: CGPoint(x: width - 1, y: 12),
            rowWidth: 0,
            hasSessionCost: true
        ) == nil)
    }
}
