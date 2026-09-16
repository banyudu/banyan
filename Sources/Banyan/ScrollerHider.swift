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
    private weak var observedScrollView: NSScrollView?
    private var scrollerObservation: NSKeyValueObservation?
    private var discoveryAttempts = 0
    private static let maxDiscoveryAttempts = 20

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideEnclosingScroller()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hideEnclosingScroller()
    }

    override func layout() {
        super.layout()
        hideEnclosingScroller()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        hideEnclosingScroller()
    }

    /// SwiftUI reconfigures the enclosing NSScrollView on state updates, which
    /// restores `hasVerticalScroller` and brings the scrollbar back. A one-shot
    /// hide is not enough — and layout/draw hooks rarely fire on a zero-size
    /// background view — so enforcement is event-driven: KVO catches the exact
    /// mutation that re-enables the scroller. Trackpad/mouse-wheel scrolling
    /// keeps working; only the visible bar stays gone.
    func hideEnclosingScroller() {
        if let scrollView = observedScrollView {
            if scrollView.hasVerticalScroller {
                scrollView.hasVerticalScroller = false
            }
            return
        }
        guard let scrollView = findEnclosingScrollView() else {
            scheduleDiscoveryRetry()
            return
        }
        discoveryAttempts = 0
        observedScrollView = scrollView
        if scrollView.hasVerticalScroller {
            scrollView.hasVerticalScroller = false
        }
        scrollerObservation = scrollView.observe(\.hasVerticalScroller, options: [.new]) { scrollView, change in
            guard change.newValue == true else { return }
            DispatchQueue.main.async { [weak scrollView] in
                if scrollView?.hasVerticalScroller == true {
                    scrollView?.hasVerticalScroller = false
                }
            }
        }
    }

    private func findEnclosingScrollView() -> NSScrollView? {
        var current: NSView? = self
        while let view = current {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            current = view.superview
        }
        return nil
    }

    /// The enclosing scroll view may not exist yet while SwiftUI is still
    /// assembling the hierarchy; retry with bounded backoff until found.
    /// (If SwiftUI later replaces the scroll view instance, the move/layout
    /// hooks above re-run discovery; the weak ref going nil is the signal.)
    private func scheduleDiscoveryRetry() {
        guard window != nil, observedScrollView == nil else { return }
        guard discoveryAttempts < Self.maxDiscoveryAttempts else { return }
        discoveryAttempts += 1
        let delay = min(0.1 * Double(discoveryAttempts), 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.observedScrollView == nil, self.window != nil else { return }
            self.hideEnclosingScroller()
        }
    }
}
