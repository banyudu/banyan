import AppKit
import Testing
@testable import Banyan

@MainActor
@Test func terminalSwitcherKeepsOnlyTheSelectedTerminalVisible() {
    let first = makeSwitcherSession(id: "first")
    let second = makeSwitcherSession(id: "second")
    let switcher = TerminalSwitcherContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let focusRequestID = UUID()

    update(switcher, sessions: [first, second], selectedID: first.id, focusRequestID: focusRequestID)

    #expect(first.loadedTerminalView != nil)
    #expect(second.loadedTerminalView == nil)
    let firstContainer = switcher.subviews.compactMap { $0 as? TerminalContainerView }.first
    #expect(firstContainer != nil)

    update(switcher, sessions: [first, second], selectedID: second.id, focusRequestID: focusRequestID)

    #expect(second.loadedTerminalView != nil)
    let visibleAfterSecond = switcher.subviews.compactMap { $0 as? TerminalContainerView }.filter { !$0.isHidden }
    let secondContainer = visibleAfterSecond.first
    #expect(secondContainer != nil)
    #expect(secondContainer !== firstContainer)
    #expect(firstContainer?.window === switcher.window)
    #expect(firstContainer?.isHidden == true)
    #expect(visibleAfterSecond.count == 1)

    switcher.switchImmediately(to: first.id, selectionChangedAt: nil, clickAt: nil)

    let visibleAfterRevisit = switcher.subviews.compactMap { $0 as? TerminalContainerView }.filter { !$0.isHidden }
    #expect(visibleAfterRevisit.first === firstContainer)
    #expect(visibleAfterRevisit.count == 1)
    #expect(secondContainer?.isHidden == true)
}

@MainActor
@Test func terminalSwitcherForwardsHistorySelectionWithoutWaitingForTerminalPaint() async {
    let live = makeSwitcherSession(id: "live")
    let switcher = TerminalSwitcherContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let focusRequestID = UUID()

    update(switcher, sessions: [live], selectedID: live.id, focusRequestID: focusRequestID)

    var didForwardSelection = false
    switcher.switchImmediately(
        to: "closed-history",
        selectionChangedAt: nil,
        clickAt: nil,
        afterPaint: { didForwardSelection = true }
    )
    update(
        switcher,
        sessions: [live],
        selectedID: "closed-history",
        focusRequestID: focusRequestID
    )
    try? await Task.sleep(for: .milliseconds(10))

    let visibleContainers = switcher.subviews
        .compactMap { $0 as? TerminalContainerView }
        .filter { !$0.isHidden }
    #expect(didForwardSelection)
    #expect(visibleContainers.isEmpty)
}

/// A terminal retains its own live viewport while hidden. Returning to a
/// terminal that is already at the live bottom must not restore an old
/// scrollback row when its next output arrives.
@MainActor
@Test func terminalSwitcherDoesNotRestoreStaleScrollbackAfterReturningToBottom() async {
    let first = makeSwitcherSession(id: "first")
    let second = makeSwitcherSession(id: "second")
    let switcher = TerminalSwitcherContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let focusRequestID = UUID()

    update(switcher, sessions: [first, second], selectedID: first.id, focusRequestID: focusRequestID)
    switcher.layoutSubtreeIfNeeded()
    let terminal = first.terminalView
    terminal.setFrameSize(NSSize(width: 800, height: 600))
    terminal.resizeSubviews(withOldSize: .zero)
    terminal.resize(cols: 80, rows: 25)
    terminal.changeScrollback(50)
    for index in 0..<200 {
        terminal.feed(text: "line-\(index)\\r\\n")
    }
    #expect(terminal.canScroll)
    terminal.scrollUp(lines: 12)
    #expect(terminal.scrollPosition < 1)

    update(switcher, sessions: [first, second], selectedID: second.id, focusRequestID: focusRequestID)
    update(switcher, sessions: [first, second], selectedID: first.id, focusRequestID: focusRequestID)
    terminal.scrollDown(lines: 10_000)
    #expect(terminal.scrollPosition == 1)

    update(switcher, sessions: [first, second], selectedID: second.id, focusRequestID: focusRequestID)
    update(switcher, sessions: [first, second], selectedID: first.id, focusRequestID: focusRequestID)
    let bytes = Array("live output\\r\\n".utf8)
    terminal.dataReceived(slice: bytes[...])
    try? await Task.sleep(for: .milliseconds(30))

    #expect(terminal.scrollPosition == 1)
}

/// A cross-project switch freezes the outgoing container's geometry so tmux can
/// reflow the incoming terminal off screen. Every resize during that freeze — the
/// contextual issue panel appearing or disappearing — must still be applied to the
/// frozen container before it is revealed again, or it stays permanently narrower
/// than the switcher and paints an empty strip beside the terminal.
@MainActor
@Test func terminalSwitcherRestoresFrozenContainerGeometryAfterProjectSwitch() async {
    let first = makeSwitcherSession(id: "first", projectGroupID: "project-a")
    let second = makeSwitcherSession(id: "second", projectGroupID: "project-b")
    let switcher = TerminalSwitcherContainer(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
    let focusRequestID = UUID()

    update(switcher, sessions: [first, second], selectedID: first.id, focusRequestID: focusRequestID)
    switcher.layoutSubtreeIfNeeded()
    let firstContainer = switcher.subviews.compactMap { $0 as? TerminalContainerView }.first
    #expect(firstContainer?.frame.width == 1200)

    switcher.switchImmediately(to: second.id, selectionChangedAt: nil, clickAt: nil)
    update(switcher, sessions: [first, second], selectedID: second.id, focusRequestID: focusRequestID)

    // The issue panel for the incoming project claims part of the detail column.
    switcher.setFrameSize(NSSize(width: 820, height: 600))
    switcher.layoutSubtreeIfNeeded()

    let deadline = Date().addingTimeInterval(3)
    while firstContainer?.isHidden == false, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(50))
    }

    #expect(firstContainer?.isHidden == true)
    #expect(firstContainer?.frame == switcher.bounds)
}

/// Revealing a cached container re-asserts its geometry, so a container that
/// drifted while it was hidden never paints at a stale width.
@MainActor
@Test func terminalSwitcherResizesDriftedContainerBeforeRevealingIt() {
    let first = makeSwitcherSession(id: "first")
    let second = makeSwitcherSession(id: "second")
    let switcher = TerminalSwitcherContainer(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
    let focusRequestID = UUID()

    update(switcher, sessions: [first, second], selectedID: first.id, focusRequestID: focusRequestID)
    update(switcher, sessions: [first, second], selectedID: second.id, focusRequestID: focusRequestID)
    switcher.layoutSubtreeIfNeeded()

    let firstContainer = switcher.subviews.compactMap { $0 as? TerminalContainerView }.first
    firstContainer?.frame = NSRect(x: 0, y: 0, width: 440, height: 600)

    switcher.switchImmediately(to: first.id, selectionChangedAt: nil, clickAt: nil)

    #expect(firstContainer?.isHidden == false)
    #expect(firstContainer?.frame == switcher.bounds)
}

@Test func terminalEditingShortcutsDoNotCaptureShiftedJumpChords() {
    #expect(TerminalContainerView.isPlainCommandTerminalShortcut(.command))
    #expect(!TerminalContainerView.isPlainCommandTerminalShortcut([.command, .shift]))
    #expect(!TerminalContainerView.isPlainCommandTerminalShortcut([.command, .option]))
    #expect(!TerminalContainerView.isPlainCommandTerminalShortcut([.command, .control]))
}

@Test func terminalFindShortcutRequiresPlainCommand() {
    #expect(TerminalContainerView.isPlainCommandTerminalShortcut([.command]))
    #expect(!TerminalContainerView.isPlainCommandTerminalShortcut([.command, .shift]))
    #expect(!TerminalContainerView.isPlainCommandTerminalShortcut([.command, .option]))
    #expect(!TerminalContainerView.isPlainCommandTerminalShortcut([.command, .control]))
}

@MainActor
private func update(
    _ switcher: TerminalSwitcherContainer,
    sessions: [BanyanSession],
    selectedID: String,
    focusRequestID: UUID
) {
    switcher.update(
        switchRequestedAt: nil,
        selectionChangedAt: nil,
        clickAt: nil,
        sessions: sessions,
        selectedSessionID: selectedID,
        theme: .system,
        fontFamily: "Menlo",
        fontSize: 13,
        focusRequestID: focusRequestID,
        onUserSubmittedInput: { _, _ in },
        onTerminalReady: { _ in }
    )
}

@MainActor
private func makeSwitcherSession(id: String, projectGroupID: String? = nil) -> BanyanSession {
    let session = BanyanSession(
        id: id,
        title: id,
        cwd: NSTemporaryDirectory(),
        command: "",
        isRestored: true,
        theme: .system,
        tmuxBackend: banyanTestTmuxBackend,
        telemetry: banyanTestTelemetry,
        host: banyanTestHost
    )
    if let projectGroupID {
        session.projectGroupID = projectGroupID
    }
    return session
}
