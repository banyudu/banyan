import SwiftUI
import SwiftTerm

struct TerminalHostView: NSViewRepresentable {
    let session: BanyanSession
    let theme: TerminalTheme
    let fontFamily: String
    let fontSize: Double

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView(terminalView: session.terminalView)
        container.onLayout = {
            session.renderRestoredMessageIfNeeded(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
        }
        session.apply(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
        container.needsLayout = true
        return container
    }

    func updateNSView(_ nsView: TerminalContainerView, context: Context) {
        session.apply(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
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

    init(terminalView: LocalProcessTerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        install(terminalView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
}
