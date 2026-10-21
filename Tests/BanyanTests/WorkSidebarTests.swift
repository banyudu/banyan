import AppKit
import BanyanCore
import SwiftUI
import Testing
@testable import Banyan

private func workFixture() throws -> WorkitOverview {
    let entries: [[String: Any]] = [
        ["id": "a", "revision": 4, "title": "Restore interrupted uploads", "issueURL": "https://github.com/example/project/issues/1", "sessionID": "visible", "stage": "implementing", "group": "working", "detail": "Retry handling implemented; checking interrupted transfers.", "lastProgressAt": "2026-01-01T08:15:00Z", "createdAt": "2026-01-01T08:00:00Z", "progress": ["passed": 1, "total": 3], "nextAction": "Run the interrupted upload fixture.", "evidence": []],
        ["id": "b", "revision": 5, "title": "Confirm the serving version", "issueURL": "https://github.com/example/project/issues/2", "sessionID": "missing", "stage": "waiting-deploy", "group": "waiting", "detail": "PR merged; waiting for the scheduled deployment.", "lastProgressAt": "2026-01-01T08:20:00Z", "createdAt": "2026-01-01T08:00:00Z", "nextWakeAt": "2026-01-01T08:21:00Z", "progress": ["passed": 0, "total": 2], "nextAction": "Wait for the serving source and version probe.", "prURL": "https://github.com/example/project/pull/3", "evidence": []],
        ["id": "c", "revision": 6, "title": "Review the migration scope", "stage": "needs-you", "group": "needs-you", "detail": "The issue requires an owner decision.", "createdAt": "2026-01-01T08:00:00Z", "progress": ["passed": 0, "total": 2], "nextAction": "Confirm which records belong in the migration.", "evidence": []]
    ]
    return try WorkitOverview.decode(JSONSerialization.data(withJSONObject: ["version": 1, "generatedAt": "2026-01-01T08:20:00Z", "total": 3, "truncated": false, "jobs": entries]))
}

private actor WorkFixtureClient: WorkitOverviewClient {
    var fails = false
    func fail() { fails = true }
    func fetch() async throws -> WorkitOverview {
        if fails { throw WorkitOverviewError.unavailable }
        return try workFixture()
    }
}

@Suite @MainActor struct WorkSidebarTests {
    @Test func failedRefreshRetainsResultsAndExplainsStaleness() async throws {
        let client = WorkFixtureClient()
        let model = WorkSidebarModel(client: client)
        await model.refresh()
        #expect(model.snapshot?.jobs.count == 3)
        #expect(model.error == nil)
        await client.fail()
        await model.refresh()
        #expect(model.snapshot?.jobs.count == 3)
        #expect(model.error != nil)
        #expect(!model.isRefreshing)
    }

    @Test func workRendersWithoutLiveSessionsOrServices() async throws {
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 360, height: 960), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: WorkJobList(snapshot: try workFixture(), sessionIDs: ["visible"], openSession: { _ in }))
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 960)
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 5000)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("banyan-work-render")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("overview.png"))
    }
}
