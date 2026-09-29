import Foundation
import OSLog

/// Opt-in diagnostics for investigating Activity Monitor's long-window power
/// score. Counters are aggregated in memory and emitted at most once every few
/// seconds, so enabling this does not turn terminal output into a log storm.
enum TerminalEnergyDiagnostics {
    static let enabled = ProcessInfo.processInfo.environment["BANYAN_TERMINAL_DIAGNOSTICS"] == "1"
    static let logger = Logger(subsystem: "dev.banyudu.banyan", category: "terminal-energy")
    static let minimumLogInterval: TimeInterval = 5
}

struct TerminalSurfaceEnergySnapshot {
    let outputChunks: Int
    let outputBytes: Int
    let invalidationCalls: Int
    let flushes: Int
    let droppedFlushes: Int
    let draws: Int

    var hasActivity: Bool {
        outputChunks > 0 || invalidationCalls > 0 || flushes > 0 || draws > 0
    }
}

struct TerminalContainerEnergySnapshot {
    let sessionID: String
    let layoutPasses: Int
    let frameSyncCalls: Int
    let frameChanges: Int
    let clientRunning: Bool
    let surface: TerminalSurfaceEnergySnapshot
}
