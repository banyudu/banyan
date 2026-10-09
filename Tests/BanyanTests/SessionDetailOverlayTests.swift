import AppKit
import BanyanCore
import Combine
import SwiftUI
import Testing
import Vision
@testable import Banyan

@Suite(.serialized)
@MainActor
struct SessionDetailOverlayTests {
    @Test func clearingDeepSuspendErrorRemovesWarningWithoutStoreChange() async throws {
        let fixture = try OverlayFixture(error: "Closed session cannot resume an agent")
        defer { fixture.window.close() }
        let initial = try await fixture.visibleText()
        #expect(initial.contains("Deep suspend unavailable"))
        #expect(initial.contains("Dismiss"))
        #expect(!initial.contains("Resume Agent"))

        var storeChanges = 0
        let observation = fixture.store.objectWillChange.sink { storeChanges += 1 }
        defer { observation.cancel() }
        // The Dismiss action only clears this property. No store publication or
        // replacement root view should be needed to remove the visible warning.
        fixture.session.deepSuspendError = nil
        let dismissed = try await fixture.visibleText()
        #expect(!dismissed.contains("Deep suspend unavailable"))
        #expect(!dismissed.contains("Dismiss"))
        #expect(storeChanges == 0)

        fixture.session.deepSuspendError = "Another suspension was refused"
        #expect(try await fixture.visibleText().contains("Another suspension was refused"))
    }

    @Test func suspendedOverlayTracksRecoveryStateWithoutStoreChange() async throws {
        let fixture = try OverlayFixture()
        defer { fixture.window.close() }
        _ = try await fixture.visibleText()

        fixture.session.isDeepSuspended = true
        let suspended = try await fixture.visibleText()
        #expect(suspended.contains("Agent suspended"))
        #expect(suspended.contains("Resume Agent"))
        #expect(!suspended.contains("Dismiss"))

        fixture.session.isDeepResuming = true
        #expect(try await fixture.visibleText().contains("Resuming agent"))
        fixture.session.isDeepResuming = false
        fixture.session.isDeepSuspended = false
        #expect(try await fixture.visibleText().isEmpty)
    }

    @Test func closedSessionSelectionAndInputDoNotCreateResumeWarning() throws {
        let fixture = try OverlayFixture()
        defer { fixture.window.close() }
        fixture.session.status = .closed
        fixture.store.selection.bind(to: fixture.store)

        fixture.store.selection.selectedSessionID = fixture.session.id
        fixture.store.resumeFrozenForInteraction(id: fixture.session.id)
        #expect(fixture.session.deepSuspendError == nil)
        #expect(fixture.session.terminalView.permitsInput?() == false)
        #expect(fixture.session.deepSuspendError == nil)
        // Explicit resume requests must still reject a closed session.
        #expect(throws: (any Error).self) { try fixture.session.beginDeepResume() }
    }
}

@MainActor
private struct OverlayFixture {
    let store: SessionStore
    let session: TerminalSession
    let window: NSWindow
    let hosting: NSView

    init(error: String? = nil) throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let backend = AdmissionTerminalBackend()
        store = fixture.makeStore(sessionBackend: backend)
        session = store.spawn(id: "overlay", title: "Overlay fixture", cwd: fixture.project.path,
            command: "", select: false)
        session.deepSuspendError = error
        // Keep the same root mounted throughout each test. A root replacement
        // would hide the missing observation that made Dismiss appear inert.
        hosting = NSHostingView(rootView: SessionDetailOverlay(session: session)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .environmentObject(store))
        window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 640, height: 320),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
    }

    func visibleText() async throws -> String {
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        return try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(data: png).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }
}
