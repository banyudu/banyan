import SwiftUI
import SwiftTerm

struct TerminalHostView: NSViewRepresentable {
    let session: BanyanSession
    let theme: TerminalTheme
    let fontFamily: String
    let fontSize: Double

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView(terminalView: session.terminalView)
        session.apply(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
        container.needsLayout = true
        return container
    }

    func updateNSView(_ nsView: TerminalContainerView, context: Context) {
        session.apply(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
        nsView.install(session.terminalView)
        nsView.needsLayout = true
        DispatchQueue.main.async {
            nsView.layoutSubtreeIfNeeded()
            nsView.forceTerminalResize()
        }
    }
}

final class TerminalContainerView: NSView {
    private(set) var terminalView: LocalProcessTerminalView

    init(terminalView: LocalProcessTerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        wantsLayer = true
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
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    override func layout() {
        super.layout()
        forceTerminalResize()
    }

    func forceTerminalResize() {
        guard bounds.width > 40, bounds.height > 40 else { return }
        terminalView.frame = bounds
        terminalView.resizeSubviews(withOldSize: .zero)
        terminalView.needsDisplay = true
    }
}
