import AppKit
import BanyanCore
import Foundation
import SwiftUI
import Testing
@testable import Banyan

@MainActor
@Suite struct SessionCostHoverUITests {
    @Test func constructionDefersAndCoalescesTranscriptReads() async throws {
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
        let row = makeRow(session: session, selection: selection, sessionCost: access)

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

        try await Task.sleep(for: .milliseconds(500))
        #expect(sourceCalls == 1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sourceCalls == 1)
    }

    @Test func residentExpensiveEstimateUpdatesShortcutBadge() async throws {
        let maxGoldBias = try await badgeChannelBias(
            amount: Decimal(string: "71.5")!
        ) { color in
            color.redComponent - color.blueComponent
        }
        #expect(maxGoldBias > 0.05, "Expensive badge should have a gold fill, got bias \(maxGoldBias)")
    }

    @Test func criticalEstimateUsesRedShortcutBadge() async throws {
        let maxRedBias = try await badgeChannelBias(amount: 150) { color in
            color.redComponent - color.greenComponent
        }
        #expect(maxRedBias > 0.3, "Critical badge should have a red fill, got bias \(maxRedBias)")
    }

    @Test func costEstimateFadesOutAfterBriefReveal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("banyan-cost-visibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = HostRuntimeContext(
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: root,
            currentDirectory: root.path
        )
        let session = BanyanSession(
            id: "cost-visibility-row",
            title: "A row with a visible cost estimate",
            cwd: root.path,
            command: "",
            status: .needInput,
            telemetry: banyanTestTelemetry,
            host: host
        )
        let source = SessionCostTranscriptSource(
            provider: .codex,
            transcriptURL: root.appendingPathComponent("unused.jsonl"),
            sessionKey: "codex:cost-visibility-row"
        )
        let gutter = SessionCostGutter(
            session: session,
            isHovered: true,
            source: { source },
            estimate: { _ in .complete(amount: Decimal(string: "0.31")!, tint: .codex) },
            onEstimate: { _ in }
        )

        let size = NSSize(width: 420, height: 48)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -2_000, y: -2_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: gutter.frame(width: size.width, height: size.height))
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        var visiblePixels = 0
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(50))
            visiblePixels = max(visiblePixels, try costTintPixelCount(in: hosting))
        }
        #expect(visiblePixels > 0, "The cost estimate should be visible after hover settles")

        try await Task.sleep(for: .milliseconds(700))
        let hiddenPixels = try costTintPixelCount(in: hosting)
        #expect(hiddenPixels < visiblePixels / 2, "The cost estimate should fade out after a brief reveal")
    }

    private func badgeChannelBias(
        amount: Decimal,
        metric: (NSColor) -> CGFloat
    ) async throws -> CGFloat {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("banyan-cost-tier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = HostRuntimeContext(
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: root,
            currentDirectory: root.path
        )
        let sessionID = "cost-row-\(UUID().uuidString)"
        let session = BanyanSession(
            id: sessionID,
            title: "A cost row",
            cwd: root.path,
            command: "",
            status: .needInput,
            telemetry: banyanTestTelemetry,
            host: host
        )
        let selection = SessionSelection()
        let shortcuts = SessionJumpShortcuts()
        shortcuts.setRollingEnabled(false)
        shortcuts.updateSessionIDs([session.id])
        #expect(!shortcuts.label(for: session.id).isEmpty)
        let access = SessionCostAccess(
            source: {
                SessionCostTranscriptSource(
                    provider: .codex,
                    transcriptURL: root.appendingPathComponent("unused.jsonl"),
                    sessionKey: "codex:\(sessionID)"
                )
            },
            estimate: { _ in
                .complete(amount: amount, tint: .codex)
            }
        )
        let row = makeRow(
            session: session,
            selection: selection,
            jumpShortcuts: shortcuts,
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
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: row.equatable())
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        try await Task.sleep(for: .milliseconds(700))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        let scaleX = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        var maxBias = -CGFloat.greatestFiniteMagnitude
        for x in Int(4 * scaleX)..<Int(22 * scaleX) {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                maxBias = max(maxBias, metric(color))
            }
        }
        return maxBias
    }

    private func costTintPixelCount<V: View>(in hosting: NSHostingView<V>) throws -> Int {
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        let scaleX = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        let minX = Int((hosting.bounds.width - 170) * scaleX)
        let maxX = Int((hosting.bounds.width - 20) * scaleX)
        var count = 0
        for x in minX..<maxX {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let cyanBias = min(
                    color.greenComponent - color.redComponent,
                    color.blueComponent - color.redComponent
                )
                if cyanBias > 0.25 { count += 1 }
            }
        }
        return count
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

    @Test func storeResolvesLiveTranscriptWithoutImportingHistory() throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let sourceID = "11111111-2222-4333-8444-555555555555"
        let createdAt = try #require(
            ISO8601DateFormatter().date(from: "2026-10-28T17:16:13Z")
        )
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: createdAt)
        let year = try #require(components.year)
        let month = try #require(components.month)
        let day = try #require(components.day)
        let directory = fixture.home
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
            .appendingPathComponent(String(format: "%04d", year))
            .appendingPathComponent(String(format: "%02d", month))
            .appendingPathComponent(String(format: "%02d", day))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcript = directory.appendingPathComponent(
            "rollout-2026-10-29T01-16-16-\(sourceID).jsonl"
        )
        try "{}\n".write(to: transcript, atomically: true, encoding: .utf8)

        let store = fixture.makeStore(
            historyBackend: DefaultSessionHistoryBackend(homeDirectory: fixture.home)
        )
        let session = BanyanSession(
            id: "live-cost-row",
            title: "Live cost row",
            cwd: fixture.project.path,
            command: "codex",
            status: .needInput,
            agentSessionID: sourceID,
            createdAt: createdAt,
            agentProvider: .codex,
            telemetry: banyanTestTelemetry,
            host: banyanTestHost
        )

        let source = try #require(store.sessionCostTranscriptSource(for: session))
        #expect(source.provider == .codex)
        #expect(
            source.transcriptURL.resolvingSymlinksInPath()
                == transcript.resolvingSymlinksInPath()
        )
        #expect(source.sessionKey == "codex:\(sourceID)")
    }

    private func makeRow(
        session: BanyanSession,
        selection: SessionSelection,
        jumpKeyLabel: String = "",
        jumpShortcuts: SessionJumpShortcuts? = nil,
        sessionCost: SessionCostAccess? = nil
    ) -> SessionRow {
        SessionRow(
            session: session,
            selection: selection,
            launchProfile: nil,
            depth: 0,
            titleOverride: nil,
            isHistory: false,
            isParent: false,
            showsDisclosureGutter: false,
            isFolded: false,
            jumpKeyLabel: jumpKeyLabel,
            jumpShortcuts: jumpShortcuts,
            workState: SessionWorkState(),
            actionOwner: ObjectIdentifier(selection),
            openWorkSession: { _ in },
            onSelect: {},
            onToggleFold: {},
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
            sessionCost: sessionCost
        )
    }
}
