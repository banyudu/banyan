#if os(macOS)
import Foundation
import Testing
@testable import BanyanCore

@MainActor
@Test func supervisorExitMonitorWakesDeferredSessionsWithoutPTYOrTimer() async throws {
    // A disposable child exits by EOF; no user/worker process is signalled.
    let child = Process()
    let input = Pipe()
    child.executableURL = URL(fileURLWithPath: "/bin/cat")
    child.standardInput = input
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try child.run()
    var notified: Set<String> = []
    let monitor = SupervisorProcessExitMonitor { notified.insert($0) }
    monitor.update(sessionID: "evicted", processIDs: [child.processIdentifier])
    monitor.update(sessionID: "shared", processIDs: [child.processIdentifier])
    monitor.update(sessionID: "parked", processIDs: [child.processIdentifier])
    monitor.retainSessions(["evicted", "shared"])
    let started = ContinuousClock.now
    try input.fileHandleForWriting.close()
    for _ in 0..<200 where notified.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(notified == ["evicted", "shared"])
    #expect(started.duration(to: .now) < .seconds(2))
    child.waitUntilExit()
    monitor.retainSessions([])
}
#endif
