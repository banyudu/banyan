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
    private var alternateScrollRemainder: CGFloat = 0

    init(terminalView: LocalProcessTerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(AccessibilityID.terminal)
        wantsLayer = true
        install(terminalView)
        installScrollEventMonitor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let scrollEventMonitor {
            NSEvent.removeMonitor(scrollEventMonitor)
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

    private func shouldHandleScroll(_ event: NSEvent) -> Bool {
        guard event.window === window, terminalView.window === window else { return false }
        let point = terminalView.convert(event.locationInWindow, from: nil)
        guard terminalView.bounds.contains(point) else { return false }
        return !terminalView.canScroll || terminalView.terminal.mouseMode != .off
    }

    private func handleScroll(_ event: NSEvent) {
        if terminalView.allowMouseReporting, terminalView.terminal.mouseMode != .off {
            sendMouseWheel(event)
            return
        }
        sendPageScroll(event)
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

    private func sendPageScroll(_ event: NSEvent) {
        let delta = event.scrollingDeltaY == 0 ? event.deltaY : event.scrollingDeltaY
        alternateScrollRemainder += delta
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 24 : 1

        while abs(alternateScrollRemainder) >= threshold {
            if alternateScrollRemainder > 0 {
                terminalView.send(data: EscapeSequences.cmdPageUp[...])
                alternateScrollRemainder -= threshold
            } else {
                terminalView.send(data: EscapeSequences.cmdPageDown[...])
                alternateScrollRemainder += threshold
            }
        }
    }
}
