import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import BanyanCore

private let subprocessTestWorkQueue = DispatchQueue(label: "banyan.tests.subprocess-fixtures", qos: .utility)

/// Serialize blocking fixture work off Swift Testing's cooperative workers.
func runBlockingTestWork<Value: Sendable>(
    _ work: @escaping @Sendable () throws -> Value
) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        subprocessTestWorkQueue.async {
            do {
                continuation.resume(returning: try work())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Check only a fixture's own child. Other concurrent tests can have children
/// between exit and reap, so a process-wide zombie count cannot prove a leak.
func waitForTestChildExit(_ pid: Int32) async -> Bool {
    guard pid > 0 else { return false }
    let deadline = ContinuousClock.now + .seconds(SubprocessRunner.terminationBudget)
    repeat {
        if kill(pid, 0) == -1 && errno == ESRCH { return true }
        try? await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline
    return kill(pid, 0) == -1 && errno == ESRCH
}

func subprocessTestQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
