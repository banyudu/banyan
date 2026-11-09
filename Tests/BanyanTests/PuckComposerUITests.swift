import AppKit
import BanyanCore
import SwiftUI
import Testing
@testable import Banyan

/// Drives the mounted composer's text view with real key events.
@Suite(.serialized) @MainActor
struct PuckComposerUITests {
    private func mount(_ session: PuckSession, store: SessionStore) async throws -> (NSWindow, PuckComposerNSTextView) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -2_000, y: -2_000), size: NSSize(width: 960, height: 640)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PuckSessionDetail(session: session)
            .environmentObject(store)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        window.makeKeyAndOrderFront(nil)
        try await waitForPuckState { window.firstResponder is PuckComposerNSTextView }
        let field = try #require(window.firstResponder as? PuckComposerNSTextView)
        return (window, field)
    }

    @Test func returnSendsAndShiftReturnInsertsANewline() async throws {
        let daemon = FakePuckDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let store = fixture.makeStore()
        let summary = puckSummary(cwd: fixture.project.path, position: "idle")
        daemon.put(summary)
        store.openListedPuckSessions([summary])
        let session = try #require(store.sessions.first as? PuckSession)
        let (window, field) = try await mount(session, store: store)
        defer { window.close() }

        field.insertText("first line", replacementRange: field.selectedRange())
        try sendReturn(modifiers: .shift, to: window)
        field.insertText("second line", replacementRange: field.selectedRange())
        #expect(session.draft == "first line\nsecond line")

        try sendReturn(modifiers: [], to: window)
        try await waitForPuckState { daemon.turns.count == 1 }
        #expect(daemon.turns.first?.prompt == "first line\nsecond line")
        #expect(session.draft.isEmpty)
        session.stopFollowing()
    }

    @Test func escapeInterruptsTheRunningTurn() async throws {
        let daemon = FakePuckDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let store = fixture.makeStore()
        let summary = puckSummary(cwd: fixture.project.path, position: "running")
        daemon.put(summary)
        store.openListedPuckSessions([summary])
        let session = try #require(store.sessions.first as? PuckSession)
        let (window, _) = try await mount(session, store: store)
        defer { window.close() }

        try sendKey("\u{1b}", keyCode: 53, to: window)
        try await waitForPuckState { daemon.cancellations.count == 1 }
        session.stopFollowing()
    }

    @Test func pastedImagesBecomeAttachmentsAndPastedFilesBecomePaths() async throws {
        let daemon = FakePuckDaemon()
        daemon.capabilitiesResult = try puckImageCapabilities()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let store = fixture.makeStore()
        let summary = puckSummary(engine: "codex", cwd: fixture.project.path, position: "idle")
        daemon.put(summary)
        store.openListedPuckSessions([summary])
        let session = try #require(store.sessions.first as? PuckSession)
        let (window, field) = try await mount(session, store: store)
        defer { window.close() }
        try await waitForPuckState { session.acceptsImages }
        let coordinator = try #require(field.coordinator)

        let screenshot = NSPasteboard(name: NSPasteboard.Name("banyan-test-\(UUID().uuidString)"))
        defer { screenshot.releaseGlobally() }
        screenshot.clearContents()
        screenshot.setData(PuckComposerSessionTests.pngData(), forType: .png)
        #expect(coordinator.handle(screenshot, in: field))
        #expect(session.draftImages.count == 1)
        #expect(session.draft == "[Image #1] ")

        let notes = fixture.project.appendingPathComponent("notes file.txt")
        try "notes".write(to: notes, atomically: true, encoding: .utf8)
        let files = NSPasteboard(name: NSPasteboard.Name("banyan-test-\(UUID().uuidString)"))
        defer { files.releaseGlobally() }
        files.clearContents()
        files.writeObjects([notes as NSURL])
        #expect(coordinator.handle(files, in: field))
        #expect(session.draft == "[Image #1] '\(notes.path)'")
        #expect(session.draftImages.count == 1)

        let text = NSPasteboard(name: NSPasteboard.Name("banyan-test-\(UUID().uuidString)"))
        defer { text.releaseGlobally() }
        text.clearContents()
        text.setString("plain words", forType: .string)
        #expect(!coordinator.handle(text, in: field))
        session.stopFollowing()
    }

    @Test func anImagePlaceholderEditsAsOneUnit() async throws {
        let daemon = FakePuckDaemon()
        daemon.capabilitiesResult = try puckImageCapabilities()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let store = fixture.makeStore()
        let summary = puckSummary(engine: "codex", cwd: fixture.project.path, position: "idle")
        daemon.put(summary)
        store.openListedPuckSessions([summary])
        let session = try #require(store.sessions.first as? PuckSession)
        let (window, field) = try await mount(session, store: store)
        defer { window.close() }
        try await waitForPuckState { session.acceptsImages }
        let coordinator = try #require(field.coordinator)

        field.insertText("look here", replacementRange: field.selectedRange())
        field.setSelectedRange(NSRange(location: 5, length: 0))
        let screenshot = NSPasteboard(name: NSPasteboard.Name("banyan-test-\(UUID().uuidString)"))
        defer { screenshot.releaseGlobally() }
        screenshot.clearContents()
        screenshot.setData(PuckComposerSessionTests.pngData(), forType: .png)
        #expect(coordinator.handle(screenshot, in: field))
        #expect(session.draft == "look [Image #1] here")
        #expect(session.attachedDraftImages.map(\.number) == [1])

        // The caret steps over the placeholder instead of landing inside it.
        field.setSelectedRange(NSRange(location: 15, length: 0))
        field.setSelectedRange(NSRange(location: 12, length: 0))
        #expect(field.selectedRange() == NSRange(location: 5, length: 0))

        // Backspace at its end removes all of it.
        field.setSelectedRange(NSRange(location: 15, length: 0))
        field.deleteBackward(nil)
        #expect(session.draft == "look  here")
        #expect(session.attachedDraftImages.isEmpty)
        #expect(session.draftImages.count == 1, "kept so undo can bring it back")
        PuckDraftImage.discardStaged(session.draftImages)
        session.stopFollowing()
    }

    private func sendReturn(modifiers: NSEvent.ModifierFlags, to window: NSWindow) throws {
        try sendKey("\r", keyCode: 36, modifiers: modifiers, to: window)
    }

    private func sendKey(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
                         to window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ))
        window.sendEvent(event)
    }
}
