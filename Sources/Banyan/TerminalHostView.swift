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
            onUserSubmittedInput: { session.noteUserSubmittedInput($0) }
        )
        container.apply(theme: theme)
        container.onLayout = {
            handleTerminalReady()
        }
        session.apply(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
        container.needsLayout = true
        context.coordinator.lastFocusRequestID = focusRequestID
        let readyStartedAt = DispatchTime.now()
        container.performWhenTerminalReady(for: session.terminalView) {
            PerformanceTelemetry.shared.recordDuration(
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
            PerformanceTelemetry.shared.recordDuration(
                "terminal.install_view",
                durationMS: PerformanceTelemetry.elapsedMS(since: installStartedAt),
                sessionID: session.id
            )
        }
        nsView.onUserSubmittedInput = { session.noteUserSubmittedInput($0) }
        nsView.apply(theme: theme)
        nsView.onLayout = {
            handleTerminalReady()
        }
        session.apply(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
        if didInstall {
            nsView.needsLayout = true
            nsView.syncTerminalFrameIfNeeded(markNeedsDisplay: true)
        }
        let readyStartedAt = DispatchTime.now()
        nsView.performWhenTerminalReady(for: session.terminalView) {
            PerformanceTelemetry.shared.recordDuration(
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
        PerformanceTelemetry.shared.noteSessionTerminalReady(sessionID: session.id)
        session.renderRestoredMessageIfNeeded(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
        guard session.status != .closed,
              !session.isImportedHistory,
              !session.needsManualAttach else {
            return
        }
        session.start()
        session.refreshTerminalClient()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            session.refreshTerminalClient()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            session.recoverBlankTerminalClientIfNeeded()
        }
    }
}

final class TerminalContainerView: NSView {
    private(set) var terminalView: LocalProcessTerminalView
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

    init(terminalView: LocalProcessTerminalView, onUserSubmittedInput: ((String?) -> Void)? = nil) {
        self.terminalView = terminalView
        self.onUserSubmittedInput = onUserSubmittedInput
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(AccessibilityID.terminal)
        wantsLayer = true
        install(terminalView)
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

    override func layout() {
        super.layout()
        syncTerminalFrameIfNeeded(markNeedsDisplay: false)
        onLayout?()
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
        if markNeedsDisplay {
            terminalView.needsDisplay = true
        }
    }

    func focusTerminalWhenReady() {
        focusTerminalWhenReady(attempt: 0)
    }

    func performWhenTerminalReady(for expectedTerminalView: LocalProcessTerminalView, action: @escaping () -> Void) {
        performWhenTerminalReady(for: expectedTerminalView, attempt: 0, action: action)
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

    private func performWhenTerminalReady(
        for expectedTerminalView: LocalProcessTerminalView,
        attempt: Int,
        action: @escaping () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.05)) { [weak self] in
            guard let self, self.terminalView === expectedTerminalView else { return }
            guard self.window != nil, self.bounds.width > 40, self.bounds.height > 40 else {
                if attempt < 20 {
                    self.performWhenTerminalReady(for: expectedTerminalView, attempt: attempt + 1, action: action)
                }
                return
            }
            self.syncTerminalFrameIfNeeded(markNeedsDisplay: true)
            action()
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
        inputEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }

            switch event.type {
            case .leftMouseDown:
                if self.isEventInTerminal(event) {
                    self.window?.makeFirstResponder(self.terminalView)
                }
                return event
            case .keyDown:
                guard self.isTerminalFirstResponder else { return event }
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
        guard event.window === window, terminalView.window === window else { return false }
        guard isEventInTerminal(event) else { return false }
        return true
    }

    private func isEventInTerminal(_ event: NSEvent) -> Bool {
        let point = terminalView.convert(event.locationInWindow, from: nil)
        return terminalView.bounds.contains(point)
    }

    private var isTerminalFirstResponder: Bool {
        guard let firstResponder = window?.firstResponder else { return false }
        if firstResponder === terminalView {
            return true
        }
        if let view = firstResponder as? NSView {
            return view === terminalView || view.isDescendant(of: terminalView)
        }
        return false
    }

    private func isSubmitKey(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
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
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
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
        default:
            return false
        }
    }

    private func handleScroll(_ event: NSEvent) {
        let action = scrollInterpreter.interpret(
            deltaY: Double(event.deltaY),
            scrollingDeltaY: Double(event.scrollingDeltaY),
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            canScroll: terminalView.canScroll,
            mouseModeActive: terminalView.terminal.mouseMode != .off
        )

        switch action {
        case .mouseWheelUp(let count):
            sendMouseWheel(event, up: true, count: count)
        case .mouseWheelDown(let count):
            sendMouseWheel(event, up: false, count: count)
        case .scrollbackUp(let lines):
            terminalView.scrollUp(lines: lines)
            (terminalView as? DetectingLocalProcessTerminalView)?.noteUserScrollbackPosition()
        case .scrollbackDown(let lines):
            terminalView.scrollDown(lines: lines)
            (terminalView as? DetectingLocalProcessTerminalView)?.noteUserScrollbackPosition()
        case .pageUp(let count):
            sendPageScroll(up: true, count: count)
        case .pageDown(let count):
            sendPageScroll(up: false, count: count)
        case nil:
            break
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
