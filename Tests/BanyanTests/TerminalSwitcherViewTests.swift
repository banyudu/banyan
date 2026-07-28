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

@Test func terminalEditingShortcutsDoNotCaptureShiftedJumpChords() {
    #expect(TerminalContainerView.isPlainCommandTerminalShortcut(.command))
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
private func makeSwitcherSession(id: String) -> BanyanSession {
    BanyanSession(
        id: id,
        title: id,
        cwd: NSTemporaryDirectory(),
        command: "",
        isRestored: true,
        theme: .system,
        tmuxBackend: TmuxBackend.shared
    )
}
