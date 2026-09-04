import AppKit
import BanyanCore
import Foundation
import QuartzCore
import SwiftTerm
final class DetectingLocalProcessTerminalView: LocalProcessTerminalView {
    var onOutput: ((String) -> Void)?
    /// Receives text after AppKit has committed it to the terminal input.
    /// This is intentionally sourced from NSTextInputClient rather than raw
    /// key events so paste and IME composition (for example, Chinese input)
    /// are recorded as the text the user actually submitted.
    var onCommittedInput: ((String) -> Void)?
    private(set) var isTextComposing = false
    /// The tmux pane backing this view, so the scroll handler can hand scrollback
    /// off to tmux's copy-mode instead of keeping a duplicate local history.
    var tmuxSessionName: String?
    var telemetry: PerformanceTelemetry?
    private var tmuxScrollPosition = 0
    private let displayInvalidationLock = NSLock()
    private var displayInvalidationPending = false
    private var accumulatedDirtyRect: NSRect = .zero
    /// A non-bottom SwiftTerm viewport is not, by itself, proof that the user
    /// is reading scrollback. tmux screen redraws can briefly leave a hidden
    /// terminal at an earlier local row. Only preserve a viewport after an
    /// explicit local scrolling gesture has established that intent.
    private var preservesUserScrollback = false
    private var isSynchronizingInitialScreen = false
    private var initialScreenSyncGeneration = 0
    private var initialScreenSyncReveal: DispatchWorkItem?
    private var initialScreenSyncTimeout: DispatchWorkItem?
    private var initialScreenSyncEarliestReveal = TimeInterval.zero
    private var initialScreenSyncDeadline = TimeInterval.zero
    private var initialScreenSyncCompletion: (() -> Void)?

    /// A tmux client attaches by redrawing its already-visible screen one line at
    /// a time. Make that first redraw transparent, then reveal one complete frame
    /// so switching to an uninitialized (or reattached) session does not visibly
    /// scroll from the top of its screen to the bottom. Keeping the AppKit view
    /// attached avoids recreating SwiftTerm's backing surface during a switch.
    func beginInitialScreenSynchronization(
        restarting: Bool = false,
        minimumDuration: TimeInterval = 0,
        timeout: TimeInterval = 0.75,
        onFinished: (() -> Void)? = nil
    ) {
        guard restarting || !isSynchronizingInitialScreen else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let minimumDeadline = now + max(0, minimumDuration)
        let timeoutDeadline = now + max(timeout, minimumDuration)
        let wasSynchronizing = isSynchronizingInitialScreen
        isSynchronizingInitialScreen = true
        preservesUserScrollback = false
        initialScreenSyncGeneration &+= 1
        initialScreenSyncReveal?.cancel()
        initialScreenSyncTimeout?.cancel()
        if wasSynchronizing {
            initialScreenSyncEarliestReveal = max(initialScreenSyncEarliestReveal, minimumDeadline)
            initialScreenSyncDeadline = max(initialScreenSyncDeadline, timeoutDeadline)
        } else {
            initialScreenSyncEarliestReveal = minimumDeadline
            initialScreenSyncDeadline = timeoutDeadline
            initialScreenSyncCompletion = nil
        }
        if let onFinished {
            initialScreenSyncCompletion = onFinished
        }
        alphaValue = 0
        let generation = initialScreenSyncGeneration
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishInitialScreenSynchronization(generation: generation)
        }
        initialScreenSyncTimeout = timeout
        // An empty shell has no output to settle. Do not leave it transparent forever,
        // but give a normal tmux screen replay ample time to arrive first.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, initialScreenSyncDeadline - now),
            execute: timeout
        )
    }

    /// A project change can alter the terminal's width when its issue panel appears
    /// or disappears. Reflow that tmux redraw while the target is still hidden, then
    /// notify the switcher once the terminal has been quiet long enough to reveal.
    func synchronizeForProjectSwitch(onFinished: @escaping () -> Void) {
        beginInitialScreenSynchronization(
            restarting: true,
            minimumDuration: 0.35,
            timeout: 1.2,
            onFinished: onFinished
        )
        noteInitialScreenGeometryChange()
    }

    func cancelInitialScreenSynchronization() {
        guard isSynchronizingInitialScreen else { return }
        isSynchronizingInitialScreen = false
        initialScreenSyncGeneration &+= 1
        initialScreenSyncReveal?.cancel()
        initialScreenSyncReveal = nil
        initialScreenSyncTimeout?.cancel()
        initialScreenSyncTimeout = nil
        initialScreenSyncCompletion = nil
        alphaValue = 1
    }

    /// SwiftTerm invalidates per row as output is parsed, and agent output arrives
    /// in many small PTY chunks. Coalesce those into one invalidation per main
    /// run-loop turn, accumulating the union of the dirty rects so SwiftTerm's
    /// per-row draw skip still only repaints rows that actually changed.
    ///
    /// Deliberately *not* rate-limited: a wall-clock throttle was measured to give
    /// no CPU benefit (the cost was per-repaint, not per-second — see #31) while
    /// adding up to a frame of latency to every paint, which reads as lag.
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        displayInvalidationLock.lock()
        if displayInvalidationPending {
            accumulatedDirtyRect = accumulatedDirtyRect.union(invalidRect)
            displayInvalidationLock.unlock()
            return
        }
        displayInvalidationPending = true
        accumulatedDirtyRect = invalidRect
        displayInvalidationLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.flushCoalescedDisplayInvalidation()
        }
    }

    /// tmux scrolls its history by repainting the visible rows in place, so the
    /// local buffer never moves under an active selection. Given the pane's
    /// resulting `#{scroll_position}`, shift the selection by the observed
    /// displacement so the highlight stays on the text it was covering.
    func noteTmuxScrollPosition(_ position: Int) {
        let delta = position - tmuxScrollPosition
        tmuxScrollPosition = position
        guard delta != 0 else { return }
        adjustSelection(byRows: delta)
    }

    /// Repaint everything, discarding any partial accumulated rect. Used when the
    /// view is revealed after invalidations were dropped while it was hidden.
    func invalidateEntireSurface() {
        displayInvalidationLock.lock()
        displayInvalidationPending = false
        accumulatedDirtyRect = .zero
        displayInvalidationLock.unlock()

        terminal.updateFullScreen()
        needsDisplay = true
        super.setNeedsDisplay(bounds)
    }

    private func flushCoalescedDisplayInvalidation() {
        displayInvalidationLock.lock()
        displayInvalidationPending = false
        let dirtyRect = accumulatedDirtyRect
        accumulatedDirtyRect = .zero
        displayInvalidationLock.unlock()

        guard !isHiddenOrHasHiddenAncestor,
              window?.occlusionState.contains(.visible) == true else {
            return
        }

        let rect = dirtyRect.isEmpty ? bounds : dirtyRect
        super.setNeedsDisplay(rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        let start = CACurrentMediaTime()
        super.draw(dirtyRect)
        let elapsed = (CACurrentMediaTime() - start) * 1000.0
        telemetry?.recordDurationIfSlow("terminal.draw", durationMS: elapsed)
    }

    var hasVisibleText: Bool {
        let dimensions = terminal.getDims()
        guard dimensions.cols > 0, dimensions.rows > 0 else { return false }
        for row in 0..<dimensions.rows {
            for col in 0..<dimensions.cols {
                guard let character = terminal.getCharacter(col: col, row: row) else { continue }
                if String(character).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    return true
                }
            }
        }
        return false
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureInteraction()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureInteraction()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if oldSize != newSize {
            noteInitialScreenGeometryChange()
        }
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        // Capture the current viewport for this output batch only when the user
        // explicitly scrolled it there. In particular, do not restore a stale
        // hidden (or transparent initial-sync) viewport: a cross-project return
        // can otherwise replay it at the top before tmux catches up at bottom.
        let isSurfaceVisible = !isHiddenOrHasHiddenAncestor && alphaValue > 0
        if !isSurfaceVisible {
            preservesUserScrollback = false
        }
        let preservedTopRow = preservesUserScrollback && isSurfaceVisible
            && canScroll && scrollPosition < 1 ? terminal.buffer.yDisp : nil
        if let text = String(bytes: slice, encoding: .utf8) {
            onOutput?(text)
        }
        super.dataReceived(slice: TerminalFooterLinkifier.annotate(slice))
        if let preservedTopRow {
            restoreScrollbackPosition(preservedTopRow)
        } else if !preservesUserScrollback {
            followLiveOutput()
        }
        noteInitialScreenOutput()
    }

    /// Called after a local scroll gesture (rather than a tmux copy-mode
    /// repaint) so streaming output can preserve the viewport the user chose.
    func noteUserScrollbackPosition() {
        guard !isHiddenOrHasHiddenAncestor,
              alphaValue > 0,
              canScroll else {
            preservesUserScrollback = false
            return
        }
        preservesUserScrollback = scrollPosition < 1
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let text = string as? NSString {
            let committedText = text as String
            if !committedText.isEmpty {
                onCommittedInput?(committedText)
            }
            isTextComposing = false
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        isTextComposing = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func unmarkText() {
        isTextComposing = false
        super.unmarkText()
    }

    func resetForNewProcess() {
        beginInitialScreenSynchronization(restarting: true)
        terminal.resetToInitialState()
        needsDisplay = true
        setNeedsDisplay(bounds)
    }

    func refreshLinkTracking() {
        // SwiftTerm creates its tracking area when linkHighlightMode changes.
        // At terminal construction time the view has a zero-sized frame; repeat
        // the assignment after layout so hover links track the real terminal.
        linkHighlightMode = .hoverWithModifier
    }

    private func restoreScrollbackPosition(_ row: Int) {
        guard canScroll else { return }
        scrollTo(row: row, notifyAccessibility: false)
    }

    private func followLiveOutput() {
        guard canScroll else { return }
        scroll(toPosition: 1)
    }

    private func noteInitialScreenOutput() {
        guard isSynchronizingInitialScreen else { return }
        scheduleInitialScreenRevealAfterQuietInterval()
    }

    private func noteInitialScreenGeometryChange() {
        guard isSynchronizingInitialScreen else { return }
        scheduleInitialScreenRevealAfterQuietInterval()
    }

    private func scheduleInitialScreenRevealAfterQuietInterval() {
        initialScreenSyncReveal?.cancel()
        let now = ProcessInfo.processInfo.systemUptime
        let revealAt = max(now + 0.08, initialScreenSyncEarliestReveal)
        let generation = initialScreenSyncGeneration
        let reveal = DispatchWorkItem { [weak self] in
            self?.finishInitialScreenSynchronization(generation: generation)
        }
        initialScreenSyncReveal = reveal
        // LocalProcess drains PTY chunks in short main-run-loop slices. Waiting
        // for a quiet interval collapses the multi-chunk tmux replay into one
        // final paint while keeping an interactive shell responsive.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, revealAt - now), execute: reveal)
    }

    private func finishInitialScreenSynchronization(generation: Int) {
        guard isSynchronizingInitialScreen, generation == initialScreenSyncGeneration else { return }
        guard ProcessInfo.processInfo.systemUptime >= initialScreenSyncEarliestReveal else {
            scheduleInitialScreenRevealAfterQuietInterval()
            return
        }
        isSynchronizingInitialScreen = false
        initialScreenSyncReveal?.cancel()
        initialScreenSyncReveal = nil
        initialScreenSyncTimeout?.cancel()
        initialScreenSyncTimeout = nil
        initialScreenSyncEarliestReveal = .zero
        initialScreenSyncDeadline = .zero
        let completion = initialScreenSyncCompletion
        initialScreenSyncCompletion = nil
        alphaValue = 1
        needsDisplay = true
        setNeedsDisplay(bounds)
        completion?()
    }

    private func configureInteraction() {
        changeScrollback(1_000)
        allowMouseReporting = false
    }
}
