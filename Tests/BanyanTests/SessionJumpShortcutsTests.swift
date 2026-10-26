import AppKit
import BanyanCore
import SwiftUI
import Testing
@testable import Banyan

@MainActor
@Suite struct SessionJumpShortcutsTests {
    let ids = (0..<100).map { "session-\($0)" }

    @Test func scrollingPastTheOldLimitReusesKeysForVisibleSessions() {
        let shortcuts = SessionJumpShortcuts()
        shortcuts.updateSessionIDs(ids)
        shortcuts.updateVisibleSessionIDs(Array(ids[60..<80]))

        #expect(shortcuts.sessionID(for: 1) == "session-60")
        #expect(shortcuts.label(for: "session-60") == "0")
        #expect(shortcuts.shortcutDisplay(for: "session-70") == "⌘⇧A")
        #expect(shortcuts.label(for: "session-0").isEmpty)
        #expect(shortcuts.sessionID(for: 21) == nil)
    }

    @Test func holdingCommandFreezesDestinationsAndLabelsUntilRelease() {
        let shortcuts = SessionJumpShortcuts()
        shortcuts.updateSessionIDs(ids)
        shortcuts.updateVisibleSessionIDs(Array(ids[0..<10]))
        shortcuts.setCommandHeld(true)
        shortcuts.updateVisibleSessionIDs(Array(ids[60..<70]))
        shortcuts.updateSessionIDs(Array(ids.dropFirst()))

        #expect(shortcuts.sessionID(for: 1) == "session-0")
        #expect(shortcuts.label(for: "session-0") == "0")
        #expect(shortcuts.label(for: "session-60").isEmpty)

        shortcuts.setCommandHeld(false)
        #expect(shortcuts.sessionID(for: 1) == "session-60")
        #expect(shortcuts.label(for: "session-60") == "0")
    }

    @Test func disablingRollingRestoresGlobalOrderAndReenablingUsesTheViewport() {
        let shortcuts = SessionJumpShortcuts()
        shortcuts.updateSessionIDs(ids)
        shortcuts.updateVisibleSessionIDs(Array(ids[60..<70]))
        shortcuts.setRollingEnabled(false)

        #expect(shortcuts.sessionIDs == Array(ids.prefix(JumpOverlayMonitor.maxSessionSlots)))
        #expect(shortcuts.label(for: "session-42") == "F12")
        #expect(shortcuts.label(for: "session-60").isEmpty)
        shortcuts.updateVisibleSessionIDs(Array(ids[80..<90]))
        #expect(shortcuts.sessionID(for: 1) == "session-0")

        shortcuts.setRollingEnabled(true)
        #expect(shortcuts.sessionID(for: 1) == "session-80")
    }

    @Test func backgroundReorderingOfTheSameVisibleRowsDoesNotChangeKeys() {
        let shortcuts = SessionJumpShortcuts()
        shortcuts.updateSessionIDs(ids)
        shortcuts.updateVisibleSessionIDs(Array(ids.prefix(10)))
        shortcuts.updateSessionIDs(Array(ids.reversed()))
        shortcuts.updateVisibleSessionIDs(Array(ids.prefix(10).reversed()))
        #expect(shortcuts.sessionIDs == Array(ids.prefix(10)))
    }

    @Test func pageStrideMatchesTheVisibleRows() {
        let shortcuts = SessionJumpShortcuts()
        shortcuts.updateSessionIDs(ids)

        #expect(shortcuts.pageStride == 1)

        shortcuts.updateVisibleSessionIDs(Array(ids[20..<35]))

        #expect(shortcuts.pageStride == 15)
    }

    @Test func anEmptyViewportDoesNotFallThroughToOffscreenSessions() {
        let shortcuts = SessionJumpShortcuts()
        shortcuts.updateSessionIDs(ids)
        shortcuts.updateVisibleSessionIDs(Array(ids.prefix(10)))
        shortcuts.updateVisibleSessionIDs([])
        #expect(shortcuts.sessionID(for: 1) == nil)
    }

    @Test func viewportIgnoresPrefetchedRowsAndZeroAreaIntersections() {
        let geometry = SessionSidebarGeometry(viewportSize: CGSize(width: 300, height: 100), rows: [
            "above": CGRect(x: 0, y: -30, width: 300, height: 30),
            "first": CGRect(x: 0, y: -10, width: 300, height: 30),
            "second": CGRect(x: 0, y: 25, width: 300, height: 30),
            "last": CGRect(x: 0, y: 90, width: 300, height: 30),
            "below": CGRect(x: 0, y: 100, width: 300, height: 30)
        ])
        #expect(geometry.visibleSessionIDs == ["first", "second", "last"])
    }
}

@Suite(.serialized) @MainActor
struct SessionJumpShortcutUITests {
    @Test func activationRestoresTheCommandFreezeAfterSwitchingApplications() throws {
        let center = NotificationCenter()
        var modifiers: NSEvent.ModifierFlags = .command
        let monitor = JumpOverlayMonitor(notificationCenter: center, currentModifierFlags: { modifiers })
        let shortcuts = SessionJumpShortcuts()
        let ids = (0..<100).map { "session-\($0)" }
        shortcuts.updateSessionIDs(ids)
        shortcuts.updateVisibleSessionIDs(Array(ids.prefix(10)))
        monitor.onCommandModifierChange = shortcuts.setCommandHeld
        monitor.start()
        defer { monitor.stop() }

        // Starting while Command is already down must preserve the displayed map.
        shortcuts.updateVisibleSessionIDs(Array(ids[30..<40]))
        #expect(shortcuts.sessionID(for: 1) == "session-0")

        // Cmd-Tab may deliver the release to the other app. Deactivation clears
        // the freeze so changes made in the background can settle.
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(shortcuts.sessionID(for: 1) == "session-30")
        modifiers = []
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        shortcuts.updateVisibleSessionIDs(Array(ids[40..<50]))
        #expect(shortcuts.sessionID(for: 1) == "session-40")

        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        modifiers = .command
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        shortcuts.updateVisibleSessionIDs(Array(ids[60..<70]))
        #expect(shortcuts.sessionID(for: 1) == "session-40")

        _ = monitor.handleEvent(try keyEvent(type: .flagsChanged, modifiers: []))
        #expect(shortcuts.sessionID(for: 1) == "session-60")

        monitor.stop()
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        shortcuts.updateVisibleSessionIDs(Array(ids[80..<90]))
        #expect(shortcuts.sessionID(for: 1) == "session-80")
    }

    @Test func keyboardDispatchUsesTheWindowsFrozenSessionIDs() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let store = fixture.makeStore()
        var ids: [String] = []
        for index in 0..<3 {
            let session = try await store.createPuckSession(
                binding: PuckSessionBinding(provider: "codex"),
                cwd: fixture.project.path, id: "shortcut-\(index)", select: false
            )
            ids.append(session.id)
        }
        let firstWindow = NSWindow()
        let secondWindow = NSWindow()
        let first = SessionJumpShortcuts()
        let second = SessionJumpShortcuts()
        first.register(window: firstWindow)
        second.register(window: secondWindow)
        first.setCommandHeld(false)
        second.setCommandHeld(false)
        first.updateSessionIDs(ids)
        second.updateSessionIDs(ids)
        first.updateVisibleSessionIDs([ids[1], ids[2]])
        second.updateVisibleSessionIDs([ids[0], ids[2]])

        #expect(store.selectSession(shortcutIndex: 1, in: firstWindow))
        #expect(store.selection.selectedSessionID == ids[1])
        #expect(store.selectSession(shortcutIndex: 1, in: secondWindow))
        #expect(store.selection.selectedSessionID == ids[0])

        let monitor = JumpOverlayMonitor()
        monitor.onCommandModifierChange = SessionJumpShortcuts.setCommandHeldInAllWindows
        monitor.onJump = { store.selectSession(shortcutIndex: $0, in: firstWindow) }
        #expect(monitor.handleEvent(try keyEvent(type: .flagsChanged, modifiers: .command)) != nil)
        first.updateVisibleSessionIDs([ids[2]])
        // A view update while holding Command must not unfreeze the map.
        first.register(window: firstWindow)
        #expect(monitor.handleEvent(try keyEvent(type: .keyDown, modifiers: .command, characters: "0")) == nil)
        #expect(store.selection.selectedSessionID == ids[1])

        #expect(monitor.handleEvent(try keyEvent(type: .flagsChanged, modifiers: [])) != nil)
        #expect(monitor.handleEvent(try keyEvent(type: .keyDown, modifiers: .command, characters: "0")) == nil)
        #expect(store.selection.selectedSessionID == ids[2])
        monitor.stop()

        first.updateSessionIDs(["removed-session", ids[2]])
        first.updateVisibleSessionIDs(["removed-session", ids[2]])
        #expect(!store.selectSession(shortcutIndex: 1, in: firstWindow))
        #expect(store.selection.selectedSessionID == ids[2])
    }

    @Test func nativeListUpdatesKeysAfterScrollingBeyondFortyFiveSessions() async throws {
        _ = NSApplication.shared
        let shortcuts = SessionJumpShortcuts()
        let ids = (0..<100).map { "session-\($0)" }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ShortcutListFixture(shortcuts: shortcuts, ids: ids))
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        #expect(shortcuts.sessionID(for: 1) == "session-0")
        #expect(shortcuts.sessionIDs.count < 15)

        let scrollView = try #require(firstScrollView(in: host))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 2_100))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await Task.sleep(for: .milliseconds(150))
        let firstVisible = try #require(shortcuts.sessionID(for: 1))
        let firstIndex = try #require(ids.firstIndex(of: firstVisible))
        #expect(firstIndex > JumpOverlayMonitor.maxSessionSlots)
        #expect(shortcuts.label(for: firstVisible) == "0")
        #expect(shortcuts.label(for: "session-0").isEmpty)

        shortcuts.setCommandHeld(true)
        let frozen = shortcuts.sessionIDs
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await Task.sleep(for: .milliseconds(150))
        #expect(shortcuts.sessionIDs == frozen)
        shortcuts.setCommandHeld(false)
        #expect(shortcuts.sessionID(for: 1) == "session-0")

        shortcuts.setRollingEnabled(false)
        #expect(shortcuts.sessionIDs == Array(ids.prefix(JumpOverlayMonitor.maxSessionSlots)))
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap { firstScrollView(in: $0) }.first
    }

    private func keyEvent(type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags,
                          characters: String = "") throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: type == .flagsChanged ? 55 : 29
        ))
    }
}

private struct ShortcutListFixture: View {
    @ObservedObject var shortcuts: SessionJumpShortcuts
    let ids: [String]

    var body: some View {
        List {
            Section {
                Text("Project")
                ForEach(ids, id: \.self) { id in
                    HStack {
                        Text(shortcuts.label(for: id))
                        Text(id)
                    }
                    .frame(height: 28)
                    .sessionJumpShortcutRow(id: id)
                }
            }
        }
        .listStyle(.sidebar)
        .sessionJumpShortcutViewport(shortcuts: shortcuts, sessionIDs: ids)
    }
}
