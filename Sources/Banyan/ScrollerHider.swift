import SwiftUI
import AppKit

extension View {
    func hidesVerticalScroller() -> some View {
        background(ScrollerHider())
    }
}

private struct ScrollerHider: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerHidingView {
        ScrollerHidingView()
    }

    func updateNSView(_ nsView: ScrollerHidingView, context: Context) {
        nsView.hideEnclosingScroller()
    }
}

private final class ScrollerHidingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideEnclosingScroller(retryIfMissing: true)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hideEnclosingScroller(retryIfMissing: true)
    }

    override func layout() {
        super.layout()
        hideEnclosingScroller()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        hideEnclosingScroller()
    }

    /// SwiftUI recreates or reconfigures the enclosing NSScrollView on state
    /// updates, which restores `hasVerticalScroller` and brings the scrollbar
    /// back. Re-applying on every layout/draw pass keeps it hidden while
    /// trackpad/mouse-wheel scrolling keeps working.
    func hideEnclosingScroller(retryIfMissing: Bool = false) {
        var current: NSView? = self
        while let view = current {
            if let scrollView = view as? NSScrollView {
                if scrollView.hasVerticalScroller {
                    scrollView.hasVerticalScroller = false
                }
                return
            }
            current = view.superview
        }
        // The enclosing scroll view may not exist yet when SwiftUI is still
        // assembling the hierarchy; retry once on the next runloop turn.
        if retryIfMissing, window != nil {
            DispatchQueue.main.async { [weak self] in
                self?.hideEnclosingScroller()
            }
        }
    }
}
