import Foundation
import Testing
@testable import BanyanCore

@Suite struct EnergyReportTests {
    @Test func descendantsAreAttributedWithoutReadingCommandLines() {
        let rows = [row(1, 0), row(10, 1), row(20, 10), row(21, 20), row(22, 21),
                    row(30, 10), row(31, 30), row(40, 1), row(50, 51), row(51, 50)]
        let owners = EnergyReportSampler.owners(rows: rows, roots: [
            .init(sessionID: "TASK-123", pid: 20), .init(sessionID: "session-2", pid: 30)
        ])
        #expect(owners == [20: "TASK-123", 21: "TASK-123", 22: "TASK-123", 30: "session-2", 31: "session-2"])
    }

    @Test func nestedAndAmbiguousPaneRootsDoNotDoubleCount() {
        let rows = [row(10, 1), row(20, 10), row(21, 20), row(30, 1)]
        let owners = EnergyReportSampler.owners(rows: rows, roots: [
            .init(sessionID: "outer", pid: 10), .init(sessionID: "inner", pid: 20),
            .init(sessionID: "one", pid: 30), .init(sessionID: "two", pid: 30)
        ])
        #expect(owners == [10: "outer", 20: "inner", 21: "inner"])
    }

    @Test func resourceDeltasSeparateAppAndChildCosts() throws {
        let before = [10: process(10, category: "app", at: 100, cpu: 3, wakeups: 10, energy: 1_000_000_000),
                      20: process(20, at: 100, cpu: 50, wakeups: 500, energy: 2_000_000_000)]
        let after = [10: process(10, category: "app", at: 110, cpu: 4, wakeups: 30, energy: 2_000_000_000),
                     20: process(20, at: 110, cpu: 58, wakeups: 10_500, energy: 22_000_000_000)]
        let report = EnergyReport.comparing(before: before, after: after, elapsedSeconds: 10)
        let child = try #require(report.processes.first)
        #expect(child.pid == 20)
        #expect(child.cpuPercent == 80)
        #expect(child.interruptWakeupsPerSecond == 1000)
        #expect(child.cpuEnergyJoules == 20)
        #expect(child.ageSeconds == 109)
        #expect(report.groups.first?.sessionID == "TASK-123")
        #expect(report.groups.first { $0.category == "app" }?.cpuPercent == 10)
        #expect(report.groups.reduce(0) { $0 + $1.processCount } == 2)
        #expect(report.excludedProcessCount == 0)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!json.contains("arguments"))
        #expect(!json.contains("environment"))
        #expect(report.formatted().contains("No processes were stopped."))
    }

    @Test func replacedReassignedMissingAndDiscontinuousProcessesAreExcluded() {
        let before = Dictionary(uniqueKeysWithValues: (10...16).map { ($0, process($0, at: 100, cpu: 50)) })
        let after = [
            10: process(10, at: 110, cpu: 60, start: 105), // Reused PID with a higher CPU counter.
            11: process(11, category: "other", at: 110, cpu: 60), // Reparented outside the pane.
            12: process(12, at: 110, cpu: 40), // Counter reset.
            13: process(13, at: 250, cpu: 60), // Suspend/discontinuity, not a live interval.
            14: process(14, at: 110, cpu: 60, start: nil), // Cannot establish identity.
            15: process(15, at: 100, cpu: 60), // No elapsed time.
            17: process(17, at: 110, cpu: 60) // New process; 16 exited.
        ]
        let report = EnergyReport.comparing(before: before, after: after, elapsedSeconds: 10,
            unreadableProcessCount: 2, warnings: ["Fixture attribution unavailable"])
        #expect(report.processes.isEmpty)
        #expect(report.excludedProcessCount == 8)
        #expect(report.unreadableProcessCount == 2)
        #expect(report.formatted().contains("Fixture attribution unavailable"))
    }

    @Test func unknownEnergyIsNotPresentedAsZero() {
        let report = EnergyReport.comparing(
            before: [10: process(10, at: 100, cpu: 50, energy: 1), 11: process(11, at: 100, cpu: 50)],
            after: [10: process(10, at: 110, cpu: 60, energy: 2), 11: process(11, at: 110, cpu: 60)],
            elapsedSeconds: 10)
        #expect(report.groups.count == 1)
        #expect(report.groups.first?.cpuPercent == 200)
        #expect(report.groups.first?.cpuEnergyJoules == nil)
    }

    @Test func paneInventoryRejectsUnrelatedAndMalformedRoots() {
        let roots = TmuxBackend.parseEnergySessionRoots("""
        banyan-TASK-123\t10
        banyan-TASK-123\t11
        unrelated\t12
        banyan-\t13
        banyan-invalid\t0
        banyan-invalid\t-1
        banyan-invalid\tnan
        banyan-invalid\t20\textra
        """)
        #expect(roots.map(\.pid) == [10, 11])
        #expect(roots.map(\.sessionID) == ["TASK-123", "TASK-123"])
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, 0, -1, 61])
    func invalidSampleDurationDoesNotInspectProcesses(seconds: Double) {
        #expect(throws: EnergyReportError.self) {
            try EnergyReportSampler.sample(seconds: seconds) {
                Issue.record("Invalid sampling duration must fail before discovery")
                return []
            }
        }
    }

    private func row(_ pid: Int, _ parent: Int) -> ProcessTableRow {
        .init(pid: pid, parentPID: parent, state: "S", elapsed: 100,
              accountingName: "fixture", resolvedCommand: nil)
    }

    private func process(_ pid: Int, category: String = "session", at time: Double, cpu: Double,
                         wakeups: UInt64 = 0, energy: UInt64? = nil, start: Double? = 1) -> EnergyProcessSnapshot {
        .init(pid: pid, parentPID: 1, name: "fixture", sessionID: category == "session" ? "TASK-123" : nil,
              category: category, counters: .init(uptimeSeconds: time, cpuSeconds: cpu,
                interruptWakeups: wakeups, cpuEnergyNanojoules: energy, processStartUptimeSeconds: start))
    }
}
