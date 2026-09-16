import AppKit
import Foundation
import QuartzCore
import SwiftTerm

/// Replays a fixed stream of terminal output through one renderer and reports
/// what the frames cost. Run it once per renderer with the same seed and byte
/// budget to get an A/B; `scripts/terminal-render-bench.sh` drives that.
///
/// The window has to be on screen and unoccluded: a Metal drawable comes from
/// the window server, and macOS throttles updates for hidden windows.
final class BenchRunner: NSObject, NSApplicationDelegate {
    private enum Phase {
        case warmup
        case measured
        case drain
    }

    private let options: BenchOptions
    private var window: NSWindow?
    private var terminalView: BenchTerminalView?
    private var generator: WorkloadGenerator
    private var timer: Timer?
    private var phase: Phase = .warmup
    private var phaseStart: CFTimeInterval = 0
    private var measuredStart: CFTimeInterval = 0
    private var measuredEnd: CFTimeInterval = 0
    private var drainDeadline: CFTimeInterval = 0
    private var bytesFed = 0
    private var feedTicks = 0
    private var costAtStart: ProcessCostSample?

    private static let tickInterval = 0.008

    init(options: BenchOptions) {
        self.options = options
        self.generator = WorkloadGenerator(seed: options.seed, kind: options.workload)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 80, y: 80, width: options.width, height: options.height)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "TerminalRenderBench (\(options.renderer.rawValue))"
        let view = BenchTerminalView(
            frame: NSRect(origin: .zero, size: frame.size),
            font: NSFont(name: "Menlo", size: options.fontSize)
        )
        view.coalesceInvalidations = options.coalesce
        view.configureNativeColors()
        // Banyan runs with implicit link detection and highlighting on, which is
        // a large part of what a line costs to build. Match it.
        view.linkHighlightMode = .hoverWithModifier
        view.highlightDetectedLinks = true
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        self.terminalView = view

        DispatchQueue.main.async { [weak self] in
            self?.start()
        }
    }

    private func start() {
        guard let view = terminalView else { exit(1) }
        if options.renderer == .metal {
            do {
                try view.setUseMetal(true)
            } catch {
                fail("could not enable the Metal renderer: \(error)")
            }
            guard view.isUsingMetalRenderer else {
                fail("the Metal renderer did not start")
            }
            view.startMetalTiming()
        }
        if options.metalBuffering == "perFrame" {
            view.metalBufferingMode = .perFrameAggregated
        }
        generator = makeGenerator()
        phase = .warmup
        phaseStart = CACurrentMediaTime()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common so the feed keeps its cadence while AppKit is tracking or
        // resizing; an event-mode stall would show up as renderer cost.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let view = terminalView else { return }
        let now = CACurrentMediaTime()
        switch phase {
        case .warmup:
            feed(into: view)
            if now - phaseStart >= options.warmupSeconds {
                beginMeasuredPhase(at: now)
            }
        case .measured:
            feed(into: view)
            if bytesFed >= options.bytes {
                measuredEnd = CACurrentMediaTime()
                phase = .drain
                // Frames already queued still belong to this workload.
                drainDeadline = measuredEnd + 0.5
            }
        case .drain:
            if now >= drainDeadline {
                finish()
            }
        }
    }

    private func beginMeasuredPhase(at now: CFTimeInterval) {
        guard let view = terminalView else { return }
        // Replaying from the same seed makes the measured stream byte-identical
        // across arms, whatever jitter the warmup saw.
        generator = makeGenerator()
        view.resetSamples()
        bytesFed = 0
        feedTicks = 0
        costAtStart = ProcessCostSample.current()
        measuredStart = now
        phase = .measured
    }

    /// The static workload addresses rows explicitly, so it has to know how
    /// tall the terminal came out.
    private func makeGenerator() -> WorkloadGenerator {
        WorkloadGenerator(
            seed: options.seed,
            kind: options.workload,
            rows: terminalView?.getTerminal().rows ?? 24
        )
    }

    private func feed(into view: BenchTerminalView) {
        let chunkSize = max(1, Int(Double(options.bytesPerSecond) * Self.tickInterval))
        let chunk = generator.chunk(minimumBytes: chunkSize)
        view.feed(byteArray: chunk[...])
        if phase == .measured {
            bytesFed += chunk.count
            feedTicks += 1
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        guard let view = terminalView, let costAtStart, let costNow = ProcessCostSample.current() else {
            fail("could not read process cost counters")
        }
        let cost = costNow.delta(since: costAtStart)
        let summary = DurationSummary(samples: view.drawSamples)
        let wallSeconds = max(measuredEnd - measuredStart, 0.000_001)
        let terminal = view.getTerminal()
        let report: [String: Any] = [
            "renderer": options.renderer.rawValue,
            "label": options.label ?? "",
            "workload": options.workload.rawValue,
            "metalBuffering": options.renderer == .metal ? options.metalBuffering : "",
            "coalesced": options.coalesce,
            "cols": terminal.cols,
            "rows": terminal.rows,
            "seed": options.seed,
            "bytes": bytesFed,
            "bytesPerSecond": options.bytesPerSecond,
            "feedTicks": feedTicks,
            "wallSeconds": wallSeconds,
            "frames": summary.count,
            "framesPerSecond": Double(summary.count) / wallSeconds,
            "drawMS": [
                "avg": summary.averageMS,
                "p50": summary.p50MS,
                "p95": summary.p95MS,
                "p99": summary.p99MS,
                "max": summary.maxMS,
                "total": summary.totalMS
            ],
            "cpu": [
                "userMS": cost.userMS,
                "systemMS": cost.systemMS,
                "totalMS": cost.totalMS,
                "cycles": cost.cycles,
                "instructions": cost.instructions,
                "idleWakeups": cost.idleWakeups,
                "interruptWakeups": cost.interruptWakeups
            ]
        ]

        if options.json {
            let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print(String(data: data ?? Data(), encoding: .utf8) ?? "{}")
        } else {
            printSummary(report, summary: summary, cost: cost, wallSeconds: wallSeconds)
        }
        exit(0)
    }

    private func printSummary(
        _ report: [String: Any],
        summary: DurationSummary,
        cost: ProcessCostSample,
        wallSeconds: Double
    ) {
        let cols = report["cols"] as? Int ?? 0
        let rows = report["rows"] as? Int ?? 0
        let buffering = options.renderer == .metal ? " (\(options.metalBuffering))" : ""
        print("renderer            \(options.renderer.rawValue)\(buffering)\(options.coalesce ? "" : " (uncoalesced)")")
        print("workload            \(options.workload.rawValue)")
        print("surface             \(cols)x\(rows) cells, \(Int(options.width))x\(Int(options.height)) pt")
        print(String(format: "workload            %.1f MB at %.0f KB/s, seed %llu",
                     Double(bytesFed) / 1_048_576, Double(options.bytesPerSecond) / 1024, options.seed))
        print(String(format: "wall                %.2f s", wallSeconds))
        print(String(format: "frames              %d (%.1f/s)", summary.count, Double(summary.count) / wallSeconds))
        print(String(format: "draw avg/p50/p95    %.2f / %.2f / %.2f ms", summary.averageMS, summary.p50MS, summary.p95MS))
        print(String(format: "draw p99/max        %.2f / %.2f ms", summary.p99MS, summary.maxMS))
        print(String(format: "draw total          %.0f ms (%.1f%% of wall)",
                     summary.totalMS, 100 * summary.totalMS / (wallSeconds * 1000)))
        print(String(format: "cpu user/system     %.0f / %.0f ms", cost.userMS, cost.systemMS))
        print(String(format: "cpu total           %.0f ms (%.0f%% of one core)",
                     cost.totalMS, 100 * cost.totalMS / (wallSeconds * 1000)))
        print("cycles/instructions \(cost.cycles) / \(cost.instructions)")
        print("wakeups idle/intr   \(cost.idleWakeups) / \(cost.interruptWakeups)")
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("TerminalRenderBench: \(message)\n".utf8))
        exit(1)
    }
}

let options = BenchOptions.parse(CommandLine.arguments)
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let runner = BenchRunner(options: options)
application.delegate = runner
application.run()
