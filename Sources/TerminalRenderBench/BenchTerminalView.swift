import AppKit
import QuartzCore
import SwiftTerm

/// A terminal view that times its own frames.
///
/// The CoreGraphics path is timed in `draw(_:)`; the Metal path never enters it
/// and reports through `onMetalFrameRendered` instead. The invalidation
/// coalescing mirrors `DetectingLocalProcessTerminalView` so the CoreGraphics
/// arm measures the cadence Banyan actually ships, not SwiftTerm's default.
final class BenchTerminalView: TerminalView {
    private(set) var drawSamples: [Double] = []
    var coalesceInvalidations = true
    private var isMetal = false

    private let displayInvalidationLock = NSLock()
    private var displayInvalidationPending = false
    private var accumulatedDirtyRect: NSRect = .zero
    private var lastDrawMS: Double = 0
    private var lastFlushUptime: TimeInterval = 0

    func startMetalTiming() {
        isMetal = true
        onMetalFrameRendered = { [weak self] durationMS in
            self?.record(durationMS)
        }
    }

    func resetSamples() {
        drawSamples.removeAll(keepingCapacity: true)
        drawSamples.reserveCapacity(4096)
    }

    private func record(_ durationMS: Double) {
        displayInvalidationLock.lock()
        lastDrawMS = durationMS
        displayInvalidationLock.unlock()
        drawSamples.append(durationMS)
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        guard coalesceInvalidations else {
            super.setNeedsDisplay(invalidRect)
            return
        }
        displayInvalidationLock.lock()
        if displayInvalidationPending {
            accumulatedDirtyRect = accumulatedDirtyRect.union(invalidRect)
            displayInvalidationLock.unlock()
            return
        }
        displayInvalidationPending = true
        accumulatedDirtyRect = invalidRect
        let now = ProcessInfo.processInfo.systemUptime
        let delay: TimeInterval = lastDrawMS > 12 ? max(0, (1.0 / 30.0) - (now - lastFlushUptime)) : 0
        displayInvalidationLock.unlock()

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.flushCoalescedDisplayInvalidation()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.flushCoalescedDisplayInvalidation()
            }
        }
    }

    private func flushCoalescedDisplayInvalidation() {
        displayInvalidationLock.lock()
        displayInvalidationPending = false
        let dirtyRect = accumulatedDirtyRect
        accumulatedDirtyRect = .zero
        lastFlushUptime = ProcessInfo.processInfo.systemUptime
        displayInvalidationLock.unlock()

        super.setNeedsDisplay(dirtyRect.isEmpty ? bounds : dirtyRect)
    }

    override func draw(_ dirtyRect: NSRect) {
        let start = CACurrentMediaTime()
        super.draw(dirtyRect)
        guard !isMetal else { return }
        record((CACurrentMediaTime() - start) * 1000.0)
    }
}
