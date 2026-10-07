import AppKit
import BanyanCore
import Testing
@testable import Banyan
@testable import SwiftTerm

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
@Test func terminalSwitcherDetachesHiddenClientAfterGrace() async {
    let first = makeSwitcherSession(id: "first")
    let second = makeSwitcherSession(id: "second")
    let switcher = TerminalSwitcherContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    switcher.inactiveClientDetachDelay = 0.03
    let focusRequestID = UUID()

    update(switcher, sessions: [first, second], selectedID: first.id, focusRequestID: focusRequestID)
    first.terminalView.startProcess(executable: "/bin/cat", environment: [])
    first.isProcessStarted = true
    #expect(first.terminalView.process.running)

    update(switcher, sessions: [first, second], selectedID: second.id, focusRequestID: focusRequestID)
    #expect(!first.terminalView.displayUpdatesEnabled)
    try? await Task.sleep(for: .milliseconds(100))

    #expect(!first.terminalView.process.running)
    #expect(first.isInactiveTerminalClientDetached)
    #expect(first.isProcessStarted)
}

@MainActor
@Test func terminalSwitcherCancelsDetachWhenReturningDuringGrace() async {
    let first = makeSwitcherSession(id: "first")
    let second = makeSwitcherSession(id: "second")
    let switcher = TerminalSwitcherContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    switcher.inactiveClientDetachDelay = 0.03
    let focusRequestID = UUID()

    update(switcher, sessions: [first, second], selectedID: first.id, focusRequestID: focusRequestID)
    first.terminalView.startProcess(executable: "/bin/cat", environment: [])
    defer { first.terminalView.terminate() }
    first.isProcessStarted = true

    update(switcher, sessions: [first, second], selectedID: second.id, focusRequestID: focusRequestID)
    update(switcher, sessions: [first, second], selectedID: first.id, focusRequestID: focusRequestID)
    try? await Task.sleep(for: .milliseconds(100))

    #expect(first.terminalView.process.running)
    #expect(!first.isInactiveTerminalClientDetached)
    #expect(first.terminalView.displayUpdatesEnabled)
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
@Test(.timeLimit(.minutes(1)))
func terminalSwitcherRestoresFrozenContainerGeometryAfterProjectSwitch() async throws {
    let first = makeSwitcherSession(id: "first", projectGroupID: "project-a")
    let second = makeSwitcherSession(id: "second", projectGroupID: "project-b")
    let switcher = TerminalSwitcherContainer(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
    let focusRequestID = UUID()

    update(switcher, sessions: [first, second], selectedID: first.id, focusRequestID: focusRequestID)
    switcher.layoutSubtreeIfNeeded()
    let firstContainer = try #require(switcher.subviews.compactMap { $0 as? TerminalContainerView }.first)
    #expect(firstContainer.frame.width == 1200)
    // Observe completion rather than racing a wall-clock deadline against the
    // synchronizer's main-queue timer when the full app suite saturates the actor.
    let completedLayouts = AsyncStream<Void> { continuation in
        firstContainer.onLayout = { [weak firstContainer] in
            guard let firstContainer, firstContainer.isHidden,
                  firstContainer.frame == switcher.bounds else { return }
            continuation.yield(())
            continuation.finish()
        }
    }
    defer { firstContainer.onLayout = nil }

    switcher.switchImmediately(to: second.id, selectionChangedAt: nil, clickAt: nil)
    update(switcher, sessions: [first, second], selectedID: second.id, focusRequestID: focusRequestID)

    // The issue panel for the incoming project claims part of the detail column.
    switcher.setFrameSize(NSSize(width: 820, height: 600))
    switcher.layoutSubtreeIfNeeded()

    for await _ in completedLayouts { break }

    #expect(firstContainer.isHidden)
    #expect(firstContainer.frame == switcher.bounds)
}

/// A queued launch has no tmux redraw to wait for. Selection must stop showing
/// and routing input to the old project before the new empty surface is ready.
@MainActor
@Test(arguments: [false, true])
func terminalSwitcherRevealsQueuedAndCancelledProjectsWithoutOutput(cancelled: Bool) async throws {
    _ = NSApplication.shared
    let source = makeSwitcherSession(id: "source", projectGroupID: "project-a")
    let target = makeSwitcherSession(id: "target", projectGroupID: "project-b")
    target.agentLaunchQueue = .init(cancelled: cancelled)
    target.agentQueuePosition = cancelled ? nil : 1
    let switcher = TerminalSwitcherContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let window = NSWindow(contentRect: switcher.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = switcher
    defer { window.close() }
    let focusRequestID = UUID()
    let sessions = [source, target]
    update(switcher, sessions: sessions, selectedID: source.id, focusRequestID: focusRequestID)
    switcher.layoutSubtreeIfNeeded()
    source.terminalView.feed(text: "Synthetic source project content")
    #expect(switcherTerminalText(source).contains("Synthetic source project content"))
    #expect(window.makeFirstResponder(source.terminalView))

    switcher.switchImmediately(to: target.id, selectionChangedAt: .now(), clickAt: nil)
    #expect(visibleSwitcherSessionIDs(switcher).isEmpty)
    #expect(window.firstResponder !== source.terminalView)
    update(switcher, sessions: sessions, selectedID: target.id, focusRequestID: focusRequestID)
    switcher.layoutSubtreeIfNeeded()
    let targetView = try #require(target.loadedTerminalView)
    #expect(visibleSwitcherSessionIDs(switcher) == [target.id])
    #expect(targetView.alphaValue == 1)
    #expect(!switcherTerminalText(target).contains("Synthetic source project content"))
    #expect(!targetView.process.running)
    await Task.yield() // An already scheduled outgoing focus request cannot win.
    #expect(window.firstResponder !== source.terminalView)

    // Cancellation must keep the target surface visible, without launching it.
    target.agentQueuePosition = nil
    target.agentLaunchQueue = .init(cancelled: true)
    update(switcher, sessions: sessions, selectedID: target.id, focusRequestID: UUID())
    #expect(visibleSwitcherSessionIDs(switcher) == [target.id])
    #expect(target.loadedTerminalView === targetView && !targetView.process.running)
    switcher.switchImmediately(to: source.id, selectionChangedAt: nil, clickAt: nil)
    update(switcher, sessions: sessions, selectedID: source.id, focusRequestID: focusRequestID)
    try await waitForPuckState { visibleSwitcherSessionIDs(switcher) == [source.id] }
    #expect(window.firstResponder === source.terminalView)
    switcher.switchImmediately(to: target.id, selectionChangedAt: nil, clickAt: nil)
    #expect(visibleSwitcherSessionIDs(switcher) == [target.id]) // Cached cancelled surface reveals synchronously.
    #expect(window.firstResponder !== source.terminalView)
    update(switcher, sessions: sessions, selectedID: target.id, focusRequestID: focusRequestID)

    // A later grant uses this same surface; switching back and returning resumes
    // the normal cross-project readiness path instead of retaining queue policy.
    target.agentLaunchQueue = nil
    target.isProcessStarted = true
    targetView.feed(text: "Synthetic admitted target content")
    update(switcher, sessions: sessions, selectedID: target.id, focusRequestID: focusRequestID)
    #expect(visibleSwitcherSessionIDs(switcher) == [target.id])
    #expect(target.loadedTerminalView === targetView)
    switcher.switchImmediately(to: source.id, selectionChangedAt: nil, clickAt: nil)
    #expect(visibleSwitcherSessionIDs(switcher) == [target.id])
    update(switcher, sessions: sessions, selectedID: source.id, focusRequestID: focusRequestID)
    try await waitForPuckState { visibleSwitcherSessionIDs(switcher) == [source.id] }
    #expect(window.firstResponder === source.terminalView)
    switcher.switchImmediately(to: target.id, selectionChangedAt: nil, clickAt: nil)
    #expect(visibleSwitcherSessionIDs(switcher) == [source.id])
    update(switcher, sessions: sessions, selectedID: target.id, focusRequestID: focusRequestID)
    try await waitForPuckState { visibleSwitcherSessionIDs(switcher) == [target.id] }
    #expect(window.firstResponder === targetView && targetView.alphaValue == 1)
}

@MainActor
@Test(arguments: [false, true], [false, true])
func terminalSwitcherUnwindsDeferredProjectWhenTargetWaitsForAdmission(duringReady: Bool, cancelled: Bool) async throws {
    _ = NSApplication.shared
    let source = makeSwitcherSession(id: "source", projectGroupID: "project-a")
    let target = makeSwitcherSession(id: "target", projectGroupID: "project-b")
    let switcher = TerminalSwitcherContainer(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
    let window = NSWindow(contentRect: switcher.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = switcher
    defer { window.close() }
    let focusRequestID = UUID()
    let sessions = [source, target]
    update(switcher, sessions: sessions, selectedID: source.id, focusRequestID: focusRequestID)
    #expect(window.makeFirstResponder(source.terminalView))
    switcher.switchImmediately(to: target.id, selectionChangedAt: nil, clickAt: nil)
    update(switcher, sessions: sessions, selectedID: target.id, focusRequestID: focusRequestID, onTerminalReady: { session in
        if duringReady, session === target {
            session.agentQueuePosition = cancelled ? nil : 1
            session.agentLaunchQueue = .init(cancelled: cancelled)
        }
    })
    #expect(visibleSwitcherSessionIDs(switcher) == [duringReady ? target.id : source.id])
    #expect(target.terminalView.alphaValue == (duringReady ? 1 : 0))
    switcher.setFrameSize(NSSize(width: 820, height: 600))

    target.agentQueuePosition = cancelled ? nil : 1
    target.agentLaunchQueue = .init(cancelled: cancelled)
    update(switcher, sessions: sessions, selectedID: target.id, focusRequestID: focusRequestID)
    #expect(visibleSwitcherSessionIDs(switcher) == [target.id])
    #expect(target.terminalView.alphaValue == 1)
    #expect(window.firstResponder !== source.terminalView)
    let sourceContainer = try #require(switcher.subviews.compactMap { $0 as? TerminalContainerView }
        .first { $0.session === source })
    #expect(sourceContainer.frame == switcher.bounds)

    // A grant in the background must not steal a newer selection, and an old
    // redraw completion must not reveal the abandoned target again.
    switcher.switchImmediately(to: source.id, selectionChangedAt: nil, clickAt: nil)
    update(switcher, sessions: sessions, selectedID: source.id, focusRequestID: focusRequestID)
    target.agentQueuePosition = nil
    target.agentLaunchQueue = nil
    target.isProcessStarted = true
    update(switcher, sessions: sessions, selectedID: source.id, focusRequestID: focusRequestID)
    try await waitForPuckState { visibleSwitcherSessionIDs(switcher) == [source.id] }
    // Let the abandoned synchronization's original timeout pass too.
    try await Task.sleep(for: .milliseconds(1_300))
    #expect(visibleSwitcherSessionIDs(switcher) == [source.id])
    #expect(window.firstResponder === source.terminalView)
}

@MainActor
private func visibleSwitcherSessionIDs(_ switcher: TerminalSwitcherContainer) -> [String] {
    switcher.subviews.compactMap { $0 as? TerminalContainerView }.filter { !$0.isHidden }.map { $0.session.id }
}

@MainActor
private func switcherTerminalText(_ session: TerminalSession) -> String {
    guard let terminal = session.loadedTerminalView?.terminal else { return "" }
    return (0..<terminal.rows).map { terminal.buffer.lines[terminal.buffer.yDisp + $0]
        .translateToString(trimRight: true) }.joined(separator: "\n")
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
    sessions: [TerminalSession],
    selectedID: String,
    focusRequestID: UUID,
    onTerminalReady: @escaping (TerminalSession) -> Void = { _ in }
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
        onTerminalReady: onTerminalReady
    )
}

@MainActor
private func makeSwitcherSession(id: String, projectGroupID: String? = nil) -> TerminalSession {
    let session = TerminalSession(
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
