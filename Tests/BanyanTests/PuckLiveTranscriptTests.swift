import AppKit
import BanyanCore
import SwiftUI
import Testing
import Vision
@testable import Banyan

@Suite(.serialized) @MainActor
struct PuckLiveTranscriptTests {
    @Test func mountedTranscriptShowsSubmissionAndFollowsStreamingHistory() async throws {
        let daemon = FakePuckDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let store = fixture.makeStore()
        let summary = puckSummary(cwd: fixture.project.path)
        daemon.put(summary)
        store.applyPuckSummaries([summary])
        let session = try #require(store.sessions.first as? PuckSession)
        let window = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 900, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { session.stopFollowing(); store.stopPuckObservation(); window.close() }
        // Keep the same view mounted throughout: replacing it would conceal a
        // stalled transcript that only recovers when the session is reopened.
        let host = NSHostingView(rootView: PuckSessionDetail(session: session)
            .environmentObject(store).preferredColorScheme(.dark))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        try await waitForPuckState { session.followState == .following }

        let gate = daemon.holdTurns()
        defer { gate.signal() }
        session.draft = "Hello visible transcript"
        session.send(session.draft)
        #expect(try await visibleText(host).contains("Hello visible transcript"))
        #expect(session.admissionTurnInFlight)
        gate.signal()
        try await waitForPuckState { !session.admissionTurnInFlight }

        daemon.push(.events([
            PuckSessionEvent(cursor: 1, kind: "user_message", text: "Hello visible transcript"),
        ]), to: session.id)
        var answer = ""
        for index in 1...40 {
            let delta = "Streaming paragraph \(index).\n\n"
            answer += delta
            daemon.push(.events([
                PuckSessionEvent(cursor: 1, kind: "text_delta", text: delta, transient: true),
            ]), to: session.id)
            try await Task.sleep(for: .milliseconds(4))
        }
        answer += "Stream finished marker"
        daemon.push(.events([
            PuckSessionEvent(cursor: 2, kind: "assistant_message", text: answer, itemID: "reply"),
        ]), to: session.id)
        try await waitForPuckState { session.timeline.items.last?.text == answer }
        #expect(try await visibleText(host).contains("Stream finished marker"))

        daemon.push(.history(PuckHistoryPage(session: session.id, source: "engine", items: [
            PuckHistoryItem(id: "reply", kind: "assistant", text: answer),
            PuckHistoryItem(id: "prompt", kind: "user", text: "Hello visible transcript"),
        ], nextCursor: nil)), to: session.id)
        daemon.push(.summary(summary), to: session.id)
        try await waitForPuckState { session.historyItems.count == 2 && session.events.isEmpty }
        #expect(try await visibleText(host).contains("Stream finished marker"))
        #expect(session.timeline.items.count == 2)
    }

    private func visibleText(_ host: NSView) async throws -> String {
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BANYAN_PUCK_RENDER_DIR"]
            ?? NSTemporaryDirectory() + "banyan-puck-transcript-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("live-scroll.png"))
        return try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(data: png).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }
}
