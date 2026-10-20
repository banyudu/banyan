import Foundation

public struct EnergySessionRoot: Sendable {
    public let sessionID: String
    public let pid: Int

    public init(sessionID: String, pid: Int) {
        self.sessionID = sessionID
        self.pid = pid
    }
}

/// A point-in-time inventory. No argv, environment, pane text, or transcripts
/// are needed to attribute a process to a tmux pane.
struct EnergyProcessSnapshot: Sendable {
    let pid: Int
    let parentPID: Int
    let name: String
    let sessionID: String?
    let category: String
    let counters: ProcessResourceSample
}

public struct EnergyProcessUsage: Codable, Sendable {
    public let pid: Int
    public let parentPID: Int
    public let name: String
    public let sessionID: String?
    public let category: String
    public let ageSeconds: Double
    public let cpuPercent: Double
    public let interruptWakeupsPerSecond: Double
    public let footprintBytes: UInt64
    public let cpuEnergyJoules: Double?
}

public struct EnergyUsageGroup: Codable, Sendable {
    public let category: String
    public let sessionID: String?
    public let processCount: Int
    public let cpuPercent: Double
    public let interruptWakeupsPerSecond: Double
    public let footprintBytes: UInt64
    public let cpuEnergyJoules: Double?
}

public struct EnergyReport: Codable, Sendable {
    public let generatedAt: Date
    public let elapsedSeconds: Double
    public let unreadableProcessCount: Int
    public let excludedProcessCount: Int
    public let warnings: [String]
    public let groups: [EnergyUsageGroup]
    public let processes: [EnergyProcessUsage]

    static func comparing(
        before: [Int: EnergyProcessSnapshot], after: [Int: EnergyProcessSnapshot],
        elapsedSeconds: Double, unreadableProcessCount: Int = 0, warnings: [String] = []
    ) -> Self {
        let processes = after.values.compactMap { current -> EnergyProcessUsage? in
            guard let previous = before[current.pid],
                  let started = current.counters.processStartUptimeSeconds,
                  started == previous.counters.processStartUptimeSeconds,
                  current.sessionID == previous.sessionID,
                  current.category == previous.category,
                  let interval = current.counters.interval(since: previous.counters, context: .init())
            else { return nil }
            return EnergyProcessUsage(
                pid: current.pid, parentPID: current.parentPID, name: current.name,
                sessionID: current.sessionID, category: current.category,
                ageSeconds: max(0, current.counters.uptimeSeconds - started),
                cpuPercent: interval.cpuPercent,
                interruptWakeupsPerSecond: interval.interruptWakeupsPerSecond,
                footprintBytes: interval.footprintBytes, cpuEnergyJoules: interval.cpuEnergyJoules
            )
        }.sorted { $0.cpuPercent == $1.cpuPercent ? $0.pid < $1.pid : $0.cpuPercent > $1.cpuPercent }
        struct Key: Hashable { let category: String; let sessionID: String? }
        let groups = Dictionary(grouping: processes) { Key(category: $0.category, sessionID: $0.sessionID) }
            .map { key, rows in
                let energy = rows.compactMap(\.cpuEnergyJoules)
                return EnergyUsageGroup(
                    category: key.category, sessionID: key.sessionID, processCount: rows.count,
                    cpuPercent: rows.reduce(0) { $0 + $1.cpuPercent },
                    interruptWakeupsPerSecond: rows.reduce(0) { $0 + $1.interruptWakeupsPerSecond },
                    footprintBytes: rows.reduce(0) { $0 + $1.footprintBytes },
                    cpuEnergyJoules: energy.count == rows.count ? energy.reduce(0, +) : nil
                )
            }.sorted {
                if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
                return ($0.sessionID ?? $0.category) < ($1.sessionID ?? $1.category)
            }
        return Self(
            generatedAt: Date(), elapsedSeconds: elapsedSeconds,
            unreadableProcessCount: unreadableProcessCount,
            excludedProcessCount: Set(before.keys).union(after.keys).count - processes.count,
            warnings: warnings, groups: groups, processes: processes
        )
    }

    public func formatted() -> String {
        var lines = [
            String(format: "Process resources over %.1f seconds (100%% CPU = one core)", elapsedSeconds),
            "CPU energy is kernel accounting, not Activity Monitor Energy Impact or battery watts.",
            "Groups: CPU% | wakeups/s | processes | owner"
        ]
        for group in groups {
            lines.append(String(format: "%7.1f | %9.1f | %9d | %@", group.cpuPercent,
                group.interruptWakeupsPerSecond, group.processCount, group.sessionID ?? group.category))
        }
        lines.append("Top processes: PID | CPU% | wakeups/s | age (hours) | owner | executable")
        for process in processes.prefix(20) {
            lines.append(String(format: "%7d | %6.1f | %9.1f | %11.1f | %@ | %@", process.pid,
                process.cpuPercent, process.interruptWakeupsPerSecond, process.ageSeconds / 3600,
                process.sessionID ?? process.category, process.name))
        }
        lines.append("Coverage: \(unreadableProcessCount) unreadable at final snapshot; \(excludedProcessCount) new/exited/replaced/reassigned processes excluded.")
        lines.append("Short-lived work between snapshots is not measured. Reparented jobs without a pane ancestor appear as other. No processes were stopped.")
        lines.append(contentsOf: warnings.map { "Warning: \($0)" })
        return lines.joined(separator: "\n")
    }
}

public enum EnergyReportSampler {
    /// Explicit, bounded sampling only. This adds no background timer to Banyan.
    public static func sample(seconds: TimeInterval, sessionRoots: () throws -> [EnergySessionRoot]) throws -> EnergyReport {
        guard seconds.isFinite, (1...60).contains(seconds) else {
            throw EnergyReportError.invalidDuration
        }
        #if os(macOS)
        var warnings: [String] = []
        func takeSnapshot() throws -> (processes: [Int: EnergyProcessSnapshot], unreadable: Int) {
            let roots: [EnergySessionRoot]
            do { roots = try sessionRoots() }
            catch {
                roots = []
                warnings.append("Session attribution unavailable: \(error.localizedDescription)")
            }
            let rows = try ProcessTableSource.rowsForResourceSampling()
            let owners = owners(rows: rows, roots: roots)
            let serverPIDs = Set(roots.compactMap { root in rows.first { $0.pid == root.pid }?.parentPID })
            var processes: [Int: EnergyProcessSnapshot] = [:]
            for row in rows {
                guard let pid = Int32(exactly: row.pid),
                      let counters = ResourceSpikeMonitor.readCounters(pid: pid) else { continue }
                let category: String
                if owners[row.pid] != nil { category = "session" }
                else if row.accountingName == "Banyan" { category = "app" }
                else if row.accountingName == "tmux", serverPIDs.contains(row.pid) { category = "tmux-server" }
                else { category = "other" }
                processes[row.pid] = EnergyProcessSnapshot(pid: row.pid, parentPID: row.parentPID,
                    name: row.accountingName, sessionID: owners[row.pid], category: category, counters: counters)
            }
            return (processes, rows.count - processes.count)
        }
        let before = try takeSnapshot()
        let start = ProcessInfo.processInfo.systemUptime
        Thread.sleep(forTimeInterval: seconds)
        let after = try takeSnapshot()
        return EnergyReport.comparing(before: before.processes, after: after.processes,
            elapsedSeconds: ProcessInfo.processInfo.systemUptime - start,
            unreadableProcessCount: after.unreadable, warnings: Array(Set(warnings)).sorted())
        #else
        throw EnergyReportError.unsupportedPlatform
        #endif
    }

    /// Follow ancestry from one kernel inventory, not argv markers. Nearest
    /// pane wins, cycles terminate, and sibling panes cannot share descendants.
    static func owners(rows: [ProcessTableRow], roots: [EnergySessionRoot]) -> [Int: String] {
        let parents = Dictionary(rows.map { ($0.pid, $0.parentPID) }, uniquingKeysWith: { first, _ in first })
        let rootsByPID = Dictionary(grouping: roots, by: \.pid).compactMapValues { values -> String? in
            let ids = Set(values.map(\.sessionID))
            return ids.count == 1 ? ids.first : nil
        }
        var owners: [Int: String] = [:]
        for row in rows {
            var pid = row.pid
            var visited: Set<Int> = []
            while visited.insert(pid).inserted {
                if let owner = rootsByPID[pid] { owners[row.pid] = owner; break }
                guard let parent = parents[pid], parent > 0 else { break }
                pid = parent
            }
        }
        return owners
    }
}

public enum EnergyReportError: Error, LocalizedError {
    case invalidDuration
    case unsupportedPlatform
    case processInventoryUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidDuration: "--seconds must be a finite number from 1 to 60"
        case .unsupportedPlatform: "Process energy sampling currently requires macOS"
        case .processInventoryUnavailable: "Kernel process inventory unavailable; no resource report can be measured"
        }
    }
}
