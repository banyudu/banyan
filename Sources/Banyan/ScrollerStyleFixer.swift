import SwiftUI
import AppKit

extension View {
    func overlayVerticalScroller() -> some View {
        background(ScrollerStyleFixer())
    }
}

private struct ScrollerStyleFixer: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerStyleFixingView {
        ScrollerStyleFixingView()
    }

    func updateNSView(_ nsView: ScrollerStyleFixingView, context: Context) {}
}

private final class ScrollerStyleFixingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var current: NSView? = self
            while let view = current {
                if let scrollView = view as? NSScrollView {
                    scrollView.scrollerStyle = .overlay
                    return
                }
                current = view.superview
            }
        }
    }
}
