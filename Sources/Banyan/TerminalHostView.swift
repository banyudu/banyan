import BanyanCore
import SwiftUI
import SwiftTerm

struct TerminalHostView: NSViewRepresentable {
    let session: BanyanSession
    let theme: TerminalTheme
    let fontFamily: String
    let fontSize: Double

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView(terminalView: session.terminalView)
        container.apply(theme: theme)
        container.onLayout = {
            session.renderRestoredMessageIfNeeded(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
        }
        session.apply(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
        container.needsLayout = true
        return container
    }

    func updateNSView(_ nsView: TerminalContainerView, context: Context) {
        session.apply(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
        nsView.apply(theme: theme)
        nsView.install(session.terminalView)
        nsView.onLayout = {
            session.renderRestoredMessageIfNeeded(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
        }
        nsView.needsLayout = true
        DispatchQueue.main.async {
            nsView.layoutSubtreeIfNeeded()
            nsView.forceTerminalResize()
        }
    }
}

final class TerminalContainerView: NSView {
    private(set) var terminalView: LocalProcessTerminalView
    var onLayout: (() -> Void)?
    private let contentInset: CGFloat = 14
    private var leadingConstraint: NSLayoutConstraint?
    private var trailingConstraint: NSLayoutConstraint?
    private var topConstraint: NSLayoutConstraint?
    private var bottomConstraint: NSLayoutConstraint?
    private var scrollEventMonitor: Any?
    private var inputEventMonitor: Any?
    private var scrollInterpreter = TerminalScrollInterpreter()

    init(terminalView: LocalProcessTerminalView) {
        self.terminalView = terminalView
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

    func install(_ terminalView: LocalProcessTerminalView) {
        guard terminalView !== self.terminalView || terminalView.superview !== self else {
            return
        }
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
    }

    func apply(theme: TerminalTheme) {
        layer?.backgroundColor = theme.backgroundColor.cgColor
    }

    override func layout() {
        super.layout()
        forceTerminalResize()
        onLayout?()
    }

    func forceTerminalResize() {
        guard bounds.width > 40, bounds.height > 40 else { return }
        let terminalFrame = bounds.insetBy(dx: contentInset, dy: contentInset)
        guard terminalFrame.width > 40, terminalFrame.height > 40 else { return }
        terminalView.frame = terminalFrame
        terminalView.setFrameSize(terminalFrame.size)
        terminalView.resizeSubviews(withOldSize: .zero)
        terminalView.needsDisplay = true
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
            allowMouseReporting: terminalView.allowMouseReporting,
            mouseModeActive: terminalView.terminal.mouseMode != .off
        )

        switch action {
        case .mouseReport:
            sendMouseWheel(event)
        case .scrollbackUp(let lines):
            terminalView.scrollUp(lines: lines)
        case .scrollbackDown(let lines):
            terminalView.scrollDown(lines: lines)
        case .pageUp(let count):
            sendPageScroll(up: true, count: count)
        case .pageDown(let count):
            sendPageScroll(up: false, count: count)
        case nil:
            break
        }
    }

    private func sendMouseWheel(_ event: NSEvent) {
        let point = terminalView.convert(event.locationInWindow, from: nil)
        let terminal = terminalView.terminal!
        let colWidth = max(terminalView.bounds.width / CGFloat(max(terminal.cols, 1)), 1)
        let rowHeight = max(terminalView.bounds.height / CGFloat(max(terminal.rows, 1)), 1)
        let col = max(0, min(terminal.cols - 1, Int(point.x / colWidth)))
        let row = max(0, min(terminal.rows - 1, Int((terminalView.bounds.height - point.y) / rowHeight)))
        let button = event.deltaY > 0 ? 4 : 5
        let flags = event.modifierFlags
        let buttonFlags = terminal.encodeButton(
            button: button,
            release: false,
            shift: flags.contains(.shift),
            meta: flags.contains(.option),
            control: flags.contains(.control)
        )
        terminal.sendEvent(
            buttonFlags: buttonFlags,
            x: col,
            y: row,
            pixelX: Int(point.x),
            pixelY: Int(terminalView.bounds.height - point.y)
        )
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
