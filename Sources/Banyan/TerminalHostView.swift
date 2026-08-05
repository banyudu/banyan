import BanyanCore
import SwiftUI
import SwiftTerm

struct TerminalHostView: NSViewRepresentable {
    let session: BanyanSession
    let theme: TerminalTheme
    let fontFamily: String
    let fontSize: Double
    let focusRequestID: UUID

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView(
            terminalView: session.terminalView,
            session: session,
            onUserSubmittedInput: { session.noteUserSubmittedInput($0) }
        )
        container.apply(theme: theme)
        session.apply(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
        container.needsLayout = true
        context.coordinator.lastFocusRequestID = focusRequestID
        let readyStartedAt = DispatchTime.now()
        container.performWhenTerminalReady(for: session.terminalView) {
            session.telemetry.recordDuration(
                "terminal.ready_wait",
                durationMS: PerformanceTelemetry.elapsedMS(since: readyStartedAt),
                sessionID: session.id
            )
            handleTerminalReady()
        }
        container.focusTerminalWhenReady()
        return container
    }

    func updateNSView(_ nsView: TerminalContainerView, context: Context) {
        let installStartedAt = DispatchTime.now()
        let didInstall = nsView.install(session.terminalView)
        if didInstall {
            session.telemetry.recordDuration(
                "terminal.install_view",
                durationMS: PerformanceTelemetry.elapsedMS(since: installStartedAt),
                sessionID: session.id
            )
        }
        nsView.onUserSubmittedInput = { session.noteUserSubmittedInput($0) }
        nsView.apply(theme: theme)
        nsView.onLayout = nil
        session.apply(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
        if didInstall {
            nsView.needsLayout = true
            nsView.syncTerminalFrameIfNeeded(markNeedsDisplay: true)
        }
        let readyStartedAt = DispatchTime.now()
        nsView.performWhenTerminalReady(for: session.terminalView) {
            session.telemetry.recordDuration(
                "terminal.ready_wait",
                durationMS: PerformanceTelemetry.elapsedMS(since: readyStartedAt),
                sessionID: session.id
            )
            handleTerminalReady()
        }
        if context.coordinator.lastFocusRequestID != focusRequestID {
            context.coordinator.lastFocusRequestID = focusRequestID
            nsView.focusTerminalWhenReady()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastFocusRequestID: UUID?
    }

    private func handleTerminalReady() {
        session.telemetry.noteSessionTerminalReady(sessionID: session.id)
        session.renderRestoredMessageIfNeeded(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
        guard session.status != .closed,
              !session.isImportedHistory,
              !session.needsManualAttach else {
            return
        }
        session.start()
        session.refreshTerminalClient(immediately: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            session.refreshTerminalClient()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) {
            session.recoverBlankTerminalClientIfNeeded()
        }
    }
}

final class TerminalContainerView: NSView {
    private(set) var terminalView: LocalProcessTerminalView
    private let session: BanyanSession
    private let paintProbe = TerminalPaintProbeView()
    var onLayout: (() -> Void)?
    var onUserSubmittedInput: ((String?) -> Void)?
    private let contentInset: CGFloat = 14
    private var leadingConstraint: NSLayoutConstraint?
    private var trailingConstraint: NSLayoutConstraint?
    private var topConstraint: NSLayoutConstraint?
    private var bottomConstraint: NSLayoutConstraint?
    private var scrollEventMonitor: Any?
    private var inputEventMonitor: Any?
    private var scrollInterpreter = TerminalScrollInterpreter()
    private var submittedInputBuffer = ""
    private var selectionAutoScrollTimer: Timer?
    private var lastSelectionDragEvent: NSEvent?
    private var pendingReadyCallback: (() -> Void)?
    private weak var pendingReadyTerminalView: LocalProcessTerminalView?

    init(terminalView: LocalProcessTerminalView, session: BanyanSession, onUserSubmittedInput: ((String?) -> Void)? = nil) {
        self.terminalView = terminalView
        self.session = session
        self.onUserSubmittedInput = onUserSubmittedInput
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(AccessibilityID.terminal)
        wantsLayer = true
        install(terminalView)
        paintProbe.frame = bounds
        paintProbe.autoresizingMask = [.width, .height]
        addSubview(paintProbe, positioned: .above, relativeTo: terminalView)
        installScrollEventMonitor()
        installInputEventMonitor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let scrollEventMonitor {
            NSEvent.removeMonitor(scrollEventMonitor)
        }
        if let inputEventMonitor {
            NSEvent.removeMonitor(inputEventMonitor)
        }
        selectionAutoScrollTimer?.invalidate()
    }

    @discardableResult
    func install(_ terminalView: LocalProcessTerminalView) -> Bool {
        guard terminalView !== self.terminalView || terminalView.superview !== self else {
            return false
        }
        NSLayoutConstraint.deactivate([
            leadingConstraint,
            trailingConstraint,
            topConstraint,
            bottomConstraint
        ].compactMap { $0 })
        self.terminalView.removeFromSuperview()
        self.terminalView = terminalView
        terminalView.wantsLayer = true
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        let leading = terminalView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentInset)
        let trailing = terminalView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInset)
        let top = terminalView.topAnchor.constraint(equalTo: topAnchor, constant: contentInset)
        let bottom = terminalView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -contentInset)
        leadingConstraint = leading
        trailingConstraint = trailing
        topConstraint = top
        bottomConstraint = bottom
        NSLayoutConstraint.activate([leading, trailing, top, bottom])
        return true
    }

    func apply(theme: TerminalTheme) {
        layer?.backgroundColor = theme.backgroundColor.cgColor
    }

    /// AppKit can retain a stale terminal backing layer while the window is
    /// occluded. Re-layout and invalidate SwiftTerm after the window becomes
    /// visible again so image placeholders and terminal geometry are repainted.
    func refreshAfterWindowLifecycle() {
        needsLayout = true
        layoutSubtreeIfNeeded()
        syncTerminalFrameIfNeeded(markNeedsDisplay: true)
        terminalView.terminal.updateFullScreen()
        terminalView.needsDisplay = true
        terminalView.setNeedsDisplay(terminalView.bounds)
        layer?.setNeedsDisplay()
    }

    func measureNextSwitchPaint(
        startedAt: DispatchTime,
        sessionID: String,
        telemetry: PerformanceTelemetry?,
        afterPaint: (() -> Void)? = nil
    ) {
        paintProbe.measureNextPaint(
            startedAt: startedAt,
            sessionID: sessionID,
            telemetry: telemetry,
            afterPaint: afterPaint
        )
    }

    override func layout() {
        super.layout()
        syncTerminalFrameIfNeeded(markNeedsDisplay: false)
        onLayout?()
        drainPendingReadyCallback()
    }

    func syncTerminalFrameIfNeeded(markNeedsDisplay: Bool) {
        guard bounds.width > 40, bounds.height > 40 else { return }
        let terminalFrame = bounds.insetBy(dx: contentInset, dy: contentInset)
        guard terminalFrame.width > 40, terminalFrame.height > 40 else { return }
        guard !terminalView.frame.equalTo(terminalFrame) else {
            if markNeedsDisplay {
                terminalView.needsDisplay = true
            }
            return
        }
        let oldSize = terminalView.bounds.size
        terminalView.frame = terminalFrame
        terminalView.setFrameSize(terminalFrame.size)
        if oldSize != terminalFrame.size {
            terminalView.resizeSubviews(withOldSize: oldSize)
        }
        (terminalView as? DetectingLocalProcessTerminalView)?.refreshLinkTracking()
        if markNeedsDisplay {
            terminalView.needsDisplay = true
        }
    }

    func focusTerminalWhenReady() {
        focusTerminalWhenReady(attempt: 0)
    }

    func performWhenTerminalReady(for expectedTerminalView: LocalProcessTerminalView, action: @escaping () -> Void) {
        pendingReadyTerminalView = expectedTerminalView
        if isTerminalReady(for: expectedTerminalView) {
            pendingReadyCallback = nil
            syncTerminalFrameIfNeeded(markNeedsDisplay: true)
            action()
        } else {
            pendingReadyCallback = action
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if pendingReadyCallback != nil && window != nil {
            needsLayout = true
        }
        drainPendingReadyCallback()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        drainPendingReadyCallback()
    }

    private func drainPendingReadyCallback() {
        guard let callback = pendingReadyCallback,
              let tv = pendingReadyTerminalView,
              isTerminalReady(for: tv) else {
            return
        }
        pendingReadyCallback = nil
        pendingReadyTerminalView = nil
        syncTerminalFrameIfNeeded(markNeedsDisplay: true)
        callback()
    }

    private func isTerminalReady(for expectedTerminalView: LocalProcessTerminalView) -> Bool {
        terminalView === expectedTerminalView
            && window != nil
            && bounds.width > 40
            && bounds.height > 40
    }

    private func focusTerminalWhenReady(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.03)) { [weak self] in
            guard let self else { return }
            guard let window = self.window else {
                if attempt < 5 {
                    self.focusTerminalWhenReady(attempt: attempt + 1)
                }
                return
            }
            window.makeFirstResponder(self.terminalView)
        }
    }

    private func installScrollEventMonitor() {
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.shouldHandleScroll(event) else { return event }
            self.handleScroll(event)
            return nil
        }
    }

    private func installInputEventMonitor() {
        inputEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }

            switch event.type {
            case .leftMouseUp:
                // A mouse-up can land outside our window (autoscrolled past the edge),
                // so stop the timer regardless of location.
                self.endSelectionAutoScroll()
                return event
            case .leftMouseDragged:
                guard event.window === self.window, self.isEventInTerminal(event) else { return event }
                self.noteSelectionDrag(event)
                return event
            default:
                break
            }

            guard event.window === self.window, !self.isHidden else { return event }

            switch event.type {
            case .leftMouseDown:
                if self.isEventInTerminal(event), self.shouldFocusTerminalOnClick(event) {
                    self.window?.makeFirstResponder(self.terminalView)
                }
                return event
            case .keyDown:
                // SwiftTerm's find bar is a child of the terminal view. It must
                // receive text editing and control-key events itself; treating
                // any descendant as the terminal would submit search text to
                // the shell when Return/Escape is pressed and could consume
                // Cmd+F while the search field is focused.
                guard self.isTerminalInputFirstResponder else { return event }
                if self.handlePageScrollShortcut(event) {
                    return nil
                }
                if self.isSubmitKey(event) {
                    self.onUserSubmittedInput?(self.submittedInputBuffer)
                    self.submittedInputBuffer = ""
                } else {
                    self.recordInput(event)
                }
                return self.handleTerminalShortcut(event) ? nil : event
            default:
                return event
            }
        }
    }

    private func shouldHandleScroll(_ event: NSEvent) -> Bool {
        guard !isHidden else { return false }
        guard event.window === window, terminalView.window === window else { return false }
        guard isEventInTerminal(event) else { return false }
        return true
    }

    private func isEventInTerminal(_ event: NSEvent) -> Bool {
        let point = terminalView.convert(event.locationInWindow, from: nil)
        return terminalView.bounds.contains(point)
    }

    /// The terminal surface should reclaim first responder on click, but the find
    /// bar (a control layered over the terminal by SwiftTerm) must not — otherwise
    /// clicking its search field immediately steals focus back to the terminal.
    private func shouldFocusTerminalOnClick(_ event: NSEvent) -> Bool {
        guard let hit = window?.contentView?.hitTest(event.locationInWindow) else { return true }
        return !(hit !== terminalView && hit.isDescendant(of: terminalView))
    }

    private var isTerminalInputFirstResponder: Bool {
        window?.firstResponder === terminalView
    }

    private func isSubmitKey(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
    }

    /// Page Up/Down are almost exclusively scrollback commands in an embedded
    /// agent terminal. Route them to the tmux-owned history before SwiftTerm can
    /// forward them to Claude, Codex, or the shell.
    private func handlePageScrollShortcut(_ event: NSEvent) -> Bool {
        let direction: Bool
        switch event.keyCode {
        case 116: // Page Up
            direction = true
        case 121: // Page Down
            direction = false
        default:
            return false
        }

        guard isTmuxBackedPane else { return false }
        let lines = max(1, (terminalView.terminal?.rows ?? 1) - 1)
        _ = scrollHistoryViaTmux(lines: lines, up: direction)
        return true
    }

    private func recordInput(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command), !flags.contains(.control) else { return }
        switch event.keyCode {
        case 51:
            if !submittedInputBuffer.isEmpty {
                submittedInputBuffer.removeLast()
            }
        case 53:
            submittedInputBuffer = ""
        default:
            guard let characters = event.characters, !characters.isEmpty else { return }
            guard !characters.contains(where: { character in
                character.isNewline || character.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            }) else { return }
            submittedInputBuffer.append(contentsOf: characters)
        }
    }

    private func handleTerminalShortcut(_ event: NSEvent) -> Bool {
        // These are plain-Command editing shortcuts. In particular, do not swallow
        // ⌘⇧A/C/F before the global session-jump monitor can handle those chords.
        guard Self.isPlainCommandTerminalShortcut(event.modifierFlags),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }

        switch key {
        case "c":
            guard terminalView.selectionActive else { return true }
            terminalView.copy(self)
            return true
        case "v":
            terminalView.paste(self)
            return true
        case "a":
            terminalView.selectAll(self)
            return true
        case "f":
            presentFindBar()
            return true
        default:
            return false
        }
    }

    static func isPlainCommandTerminalShortcut(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection([.command, .shift, .control, .option]) == .command
    }

    /// Open SwiftTerm's find bar. Driven from the input monitor because the SwiftUI
    /// menu's ⌘F shortcut does not reliably fire while the terminal view holds first
    /// responder — the same reason ⌘C/⌘V/⌘A are handled here rather than via the menu.
    private func presentFindBar() {
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        terminalView.performFindPanelAction(item)
    }

    private func handleScroll(_ event: NSEvent) {
        let action = scrollInterpreter.interpret(
            deltaY: Double(event.deltaY),
            scrollingDeltaY: Double(event.scrollingDeltaY),
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            // A tmux-backed pane can always scroll: its history lives in tmux, so the
            // near-empty local SwiftTerm buffer is no longer the thing to ask.
            // Without this, `canScroll` goes false once the local scrollback shrank
            // and the wheel would fall through to sending PageUp/PageDown to the
            // running program instead of scrolling history.
            canScroll: terminalView.canScroll || isTmuxBackedPane,
            mouseModeActive: terminalView.terminal.mouseMode != .off
        )

        switch action {
        case .mouseWheelUp(let count):
            sendMouseWheel(event, up: true, count: count)
        case .mouseWheelDown(let count):
            sendMouseWheel(event, up: false, count: count)
        case .scrollbackUp(let lines):
            if !scrollHistoryViaTmux(lines: lines, up: true) {
                terminalView.scrollUp(lines: lines)
                (terminalView as? DetectingLocalProcessTerminalView)?.noteUserScrollbackPosition()
            }
            extendSelectionDuringDrag(event)
        case .scrollbackDown(let lines):
            if !scrollHistoryViaTmux(lines: lines, up: false) {
                terminalView.scrollDown(lines: lines)
                (terminalView as? DetectingLocalProcessTerminalView)?.noteUserScrollbackPosition()
            }
            extendSelectionDuringDrag(event)
        case .pageUp(let count):
            sendPageScroll(up: true, count: count)
        case .pageDown(let count):
            sendPageScroll(up: false, count: count)
        case nil:
            break
        }
    }

    private var isTmuxBackedPane: Bool {
        (terminalView as? DetectingLocalProcessTerminalView)?.tmuxSessionName != nil
    }

    /// Hands wheel scrollback to tmux's copy-mode, which already holds this pane's
    /// history. Returns `false` for a pane we can't address (no tmux name), leaving
    /// the caller to fall back to SwiftTerm's local buffer.
    ///
    /// Mouse *reporting* stays disabled, so only the wheel is redirected — drag and
    /// click keep going to SwiftTerm, preserving the native text selection added in
    /// 7f20bcb, including while scrolled back through tmux history.
    private func scrollHistoryViaTmux(lines: Int, up: Bool) -> Bool {
        guard let paneID = (terminalView as? DetectingLocalProcessTerminalView)?.tmuxSessionName else {
            return false
        }
        session.scrollHistory(paneID: paneID, lines: lines, up: up)
        return true
    }

    /// Left button still held: re-extend the active selection to the pointer's
    /// current buffer row after the viewport scrolled underneath it. SwiftTerm's
    /// `mouseDragged` recomputes the hit against the new `yDisp`, so the selection
    /// grows instead of riding along with the scrolled content.
    private func extendSelectionDuringDrag(_ event: NSEvent) {
        guard NSEvent.pressedMouseButtons & 0x1 != 0, terminalView.selectionActive else { return }
        terminalView.mouseDragged(with: event)
    }

    /// Record an in-progress selection drag and start the edge auto-scroll timer,
    /// so holding the pointer past the top/bottom edge keeps growing the selection
    /// even while the pointer is stationary (no further drag events are delivered).
    private func noteSelectionDrag(_ event: NSEvent) {
        lastSelectionDragEvent = event
        guard selectionAutoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.selectionAutoScrollTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        selectionAutoScrollTimer = timer
    }

    private func endSelectionAutoScroll() {
        selectionAutoScrollTimer?.invalidate()
        selectionAutoScrollTimer = nil
        lastSelectionDragEvent = nil
    }

    private func selectionAutoScrollTick() {
        guard NSEvent.pressedMouseButtons & 0x1 != 0 else {
            endSelectionAutoScroll()
            return
        }
        guard let event = lastSelectionDragEvent,
              terminalView.selectionActive,
              terminalView.canScroll else { return }
        let rows = max(terminalView.terminal.rows, 1)
        let rowHeight = max(terminalView.bounds.height / CGFloat(rows), 1)
        let point = terminalView.convert(event.locationInWindow, from: nil)
        let screenRow = Int((terminalView.bounds.height - point.y) / rowHeight)
        if screenRow < 0 {
            terminalView.scrollUp(lines: selectionScrollVelocity(forOvershoot: -screenRow))
        } else if screenRow >= rows {
            terminalView.scrollDown(lines: selectionScrollVelocity(forOvershoot: screenRow - rows + 1))
        } else {
            return
        }
        (terminalView as? DetectingLocalProcessTerminalView)?.noteUserScrollbackPosition()
        terminalView.mouseDragged(with: event)
    }

    private func selectionScrollVelocity(forOvershoot rows: Int) -> Int {
        switch rows {
        case ..<3: return 1
        case 3..<6: return 3
        default: return 6
        }
    }

    private func sendMouseWheel(_ event: NSEvent, up: Bool, count: Int) {
        guard count > 0 else { return }
        let point = terminalView.convert(event.locationInWindow, from: nil)
        let terminal = terminalView.terminal!
        let colWidth = max(terminalView.bounds.width / CGFloat(max(terminal.cols, 1)), 1)
        let rowHeight = max(terminalView.bounds.height / CGFloat(max(terminal.rows, 1)), 1)
        let col = max(0, min(terminal.cols - 1, Int(point.x / colWidth)))
        let row = max(0, min(terminal.rows - 1, Int((terminalView.bounds.height - point.y) / rowHeight)))
        let flags = event.modifierFlags
        let buttonFlags = terminal.encodeButton(
            button: up ? 4 : 5,
            release: false,
            shift: flags.contains(.shift),
            meta: flags.contains(.option),
            control: flags.contains(.control)
        )
        for _ in 0..<count {
            terminal.sendEvent(
                buttonFlags: buttonFlags,
                x: col,
                y: row,
                pixelX: Int(point.x),
                pixelY: Int(terminalView.bounds.height - point.y)
            )
        }
    }

    private func sendPageScroll(up: Bool, count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            if up {
                terminalView.send(data: EscapeSequences.cmdPageUp[...])
            } else {
                terminalView.send(data: EscapeSequences.cmdPageDown[...])
            }
        }
    }
}

private final class TerminalPaintProbeView: NSView {
    private var pendingMeasurement: (
        startedAt: DispatchTime,
        sessionID: String,
        telemetry: PerformanceTelemetry?,
        afterPaint: (() -> Void)?
    )?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let pendingMeasurement else { return }
        self.pendingMeasurement = nil
        pendingMeasurement.telemetry?.recordDuration(
            "switcher.terminal_drawn",
            durationMS: PerformanceTelemetry.elapsedMS(since: pendingMeasurement.startedAt),
            sessionID: pendingMeasurement.sessionID
        )
        if let afterPaint = pendingMeasurement.afterPaint {
            DispatchQueue.main.async(execute: afterPaint)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func measureNextPaint(
        startedAt: DispatchTime,
        sessionID: String,
        telemetry: PerformanceTelemetry?,
        afterPaint: (() -> Void)?
    ) {
        pendingMeasurement = (startedAt, sessionID, telemetry, afterPaint)
        needsDisplay = true
    }
}
