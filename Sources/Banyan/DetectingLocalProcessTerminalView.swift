import AppKit
import BanyanCore
import Foundation
import QuartzCore
import SwiftTerm
final class DetectingLocalProcessTerminalView: LocalProcessTerminalView {
    var onOutput: ((String) -> Void)?
    /// The tmux pane backing this view, so the scroll handler can hand scrollback
    /// off to tmux's copy-mode instead of keeping a duplicate local history.
    var tmuxSessionName: String?
    var telemetry: PerformanceTelemetry?
    private var preservedScrollbackTopRow: Int?
    private let displayInvalidationLock = NSLock()
    private var displayInvalidationPending = false
    private var accumulatedDirtyRect: NSRect = .zero
    private var lastFlushTime: CFTimeInterval = 0
    private var throttleTimer: Timer?

    private static let throttleInterval: CFTimeInterval = 1.0 / 30.0

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
            self?.scheduleThrottledFlush()
        }
    }

    private func scheduleThrottledFlush() {
        throttleTimer?.invalidate()
        throttleTimer = nil

        let now = CACurrentMediaTime()
        let elapsed = now - lastFlushTime

        if elapsed >= Self.throttleInterval {
            flushCoalescedDisplayInvalidation()
        } else {
            let delay = Self.throttleInterval - elapsed
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                self?.flushCoalescedDisplayInvalidation()
            }
            RunLoop.main.add(timer, forMode: .common)
            throttleTimer = timer
        }
    }

    private func flushCoalescedDisplayInvalidation() {
        throttleTimer?.invalidate()
        throttleTimer = nil

        displayInvalidationLock.lock()
        displayInvalidationPending = false
        let dirtyRect = accumulatedDirtyRect
        accumulatedDirtyRect = .zero
        displayInvalidationLock.unlock()

        guard !isHiddenOrHasHiddenAncestor,
              window?.occlusionState.contains(.visible) == true else {
            return
        }

        lastFlushTime = CACurrentMediaTime()
        let rect = dirtyRect.isEmpty ? bounds : dirtyRect
        super.setNeedsDisplay(rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        let start = CACurrentMediaTime()
        super.draw(dirtyRect)
        let elapsed = (CACurrentMediaTime() - start) * 1000.0
        telemetry?.recordDuration("terminal.draw", durationMS: elapsed)
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

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let preservedTopRow = preservedScrollbackTopRow ?? (canScroll && scrollPosition < 1 ? terminal.buffer.yDisp : nil)
        if let text = String(bytes: slice, encoding: .utf8) {
            onOutput?(text)
        }
        super.dataReceived(slice: TerminalFooterLinkifier.annotate(slice))
        if let preservedTopRow {
            restoreScrollbackPosition(preservedTopRow)
        }
    }

    func noteUserScrollbackPosition() {
        guard canScroll, scrollPosition < 1 else {
            preservedScrollbackTopRow = nil
            return
        }
        preservedScrollbackTopRow = terminal.buffer.yDisp
    }

    func preserveScrollPosition() {
        guard canScroll, scrollPosition < 1 else { return }
        preservedScrollbackTopRow = terminal.buffer.yDisp
    }

    func resetForNewProcess(preserveScrollPosition: Bool = false) {
        let preservedTopRow = preserveScrollPosition ? preservedScrollbackTopRow : nil
        preservedScrollbackTopRow = preservedTopRow
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
        DispatchQueue.main.async { [weak self] in
            guard let self, self.canScroll else { return }
            self.scrollTo(row: row, notifyAccessibility: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.canScroll else { return }
            self.scrollTo(row: row, notifyAccessibility: false)
        }
    }

    private func configureInteraction() {
        changeScrollback(1_000)
        allowMouseReporting = false
    }
}
