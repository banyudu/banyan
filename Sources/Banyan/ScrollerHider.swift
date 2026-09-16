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
        nsView.hideScrollers()
    }
}

private final class ScrollerHidingView: NSView {
    /// KVO observations keyed weakly: entries vanish with their scroll views,
    /// so replaced instances never pin detached views (or leak them).
    /// Each scroll view carries a composite observation so every watched
    /// key path stays alive exactly as long as its scroll view.
    private let observations = NSMapTable<NSScrollView, ScrollerConcealment>(
        keyOptions: .weakMemory, valueOptions: .strongMemory
    )
    private var windowObserver: NSObjectProtocol?
    private weak var subscribedWindow: NSWindow?
    private var lastFullScan = Date.distantPast
    private static let fullScanInterval: TimeInterval = 0.5

    deinit {
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resubscribeWindow()
        hideScrollers()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hideScrollers()
    }

    override func layout() {
        super.layout()
        hideScrollers()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        hideScrollers()
    }

    private func resubscribeWindow() {
        guard window !== subscribedWindow else { return }
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        subscribedWindow = window
        guard let window else { return }
        // SwiftUI can rebuild a List's NSScrollView without any callback
        // firing on this (zero-size background) view, so re-scan on every
        // window display pass (throttled) instead of trusting hooks alone.
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.hideScrollers()
        }
    }

    /// Hides vertical scrollers while keeping trackpad/mouse-wheel scrolling.
    ///
    /// Discovery deliberately does NOT walk up to an "enclosing" scroll view:
    /// live hierarchy inspection (lldb, Sep 2026) proved that `.background()`
    /// on a `List` is hosted *outside* the List's internal NSScrollView —
    /// `ScrollerHidingView → PlatformViewHost → NSHostingView → … →
    /// NSSplitView` with no scroll view in between — so ancestor search always
    /// finds nothing and any fix built on it is a no-op for Lists. Instead, a
    /// mounted hider acts as a beacon: every NSScrollView in the same window
    /// gets its vertical scroller concealed, enforced instantly via KVO plus
    /// re-assertion on each display pass (which also picks up scroll views
    /// SwiftUI creates or swaps in later).
    ///
    /// Concealment is applied *synchronously* inside the KVO callbacks, never
    /// deferred with `DispatchQueue.main.async`: SwiftUI re-asserts its
    /// default scroller config whenever a view re-evaluates (e.g. the
    /// `TimelineView(.everyMinute)` ticks in the sidebar), and any async gap
    /// lets one display pass draw the scroller first — the ~60s flicker.
    func hideScrollers() {
        reassertKnownScrollViews()
        guard let window, Date().timeIntervalSince(lastFullScan) >= Self.fullScanInterval else { return }
        lastFullScan = Date()
        for scrollView in scrollViews(in: window) {
            conceal(scrollView)
        }
    }

    private func reassertKnownScrollViews() {
        let enumerator = observations.keyEnumerator()
        while let scrollView = enumerator.nextObject() as? NSScrollView {
            Self.applyConcealment(to: scrollView)
        }
    }

    private func scrollViews(in window: NSWindow) -> [NSScrollView] {
        guard let contentView = window.contentView else { return [] }
        var found: [NSScrollView] = []
        var stack: [NSView] = [contentView]
        while let view = stack.popLast() {
            if let scrollView = view as? NSScrollView {
                found.append(scrollView)
            }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    private func conceal(_ scrollView: NSScrollView) {
        Self.applyConcealment(to: scrollView)
        // Weak capture is load-bearing: a strong capture would keep every
        // replaced scroll view (plus observation and closure) alive forever.
        if observations.object(forKey: scrollView) == nil {
            let concealment = ScrollerConcealment()
            concealment.tokens = [
                scrollView.observe(\.hasVerticalScroller, options: [.new]) { [weak scrollView] _, change in
                    guard change.newValue == true, let scrollView else { return }
                    Self.applyConcealment(to: scrollView)
                },
                scrollView.observe(\.scrollerStyle, options: [.new]) { [weak scrollView] _, change in
                    guard change.newValue != .overlay, let scrollView else { return }
                    Self.applyConcealment(to: scrollView)
                },
                scrollView.observe(\.verticalScroller, options: [.new]) { [weak scrollView] _, _ in
                    guard let scrollView else { return }
                    Self.applyConcealment(to: scrollView)
                },
            ]
            observations.setObject(concealment, forKey: scrollView)
        }
    }

    /// Idempotent, flicker-free concealment. Every step is guarded so the
    /// steady state is a no-op (a few property reads, no layout, no loop):
    /// safe to call from layout/viewWillDraw/didUpdate reasserts.
    ///
    /// Order matters. The scroller *view* is hidden first — pure visibility,
    /// no layout — so no frame can ever draw it. The style is switched to
    /// `.overlay` next so the scroller reserves no layout width; removing it
    /// via `hasVerticalScroller = false` afterwards therefore causes no
    /// content-width jump. Recursion terminates: each observer guards on the
    /// already-concealed value and returns without re-setting.
    private static func applyConcealment(to scrollView: NSScrollView) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak scrollView] in
                guard let scrollView else { return }
                applyConcealment(to: scrollView)
            }
            return
        }
        if let scroller = scrollView.verticalScroller, !scroller.isHidden {
            scroller.isHidden = true
        }
        if scrollView.scrollerStyle != .overlay {
            scrollView.scrollerStyle = .overlay
        }
        if !scrollView.autohidesScrollers {
            scrollView.autohidesScrollers = true
        }
        if scrollView.hasVerticalScroller {
            scrollView.hasVerticalScroller = false
        }
        // The style swap above can hand us a fresh scroller instance that
        // defaults to visible (and `verticalScroller` KVO may arrive after
        // the next display pass), so hide whatever is installed right now.
        if let scroller = scrollView.verticalScroller, !scroller.isHidden {
            scroller.isHidden = true
        }
    }
}

/// Retains a scroll view's KVO tokens for exactly as long as the scroll view
/// itself lives (see the weak-keyed map above).
private final class ScrollerConcealment {
    var tokens: [NSKeyValueObservation] = []
}
