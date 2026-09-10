import Foundation
import Testing
@testable import BanyanCore

@Test func subprocessRunnerDoesNotWaitForDrainTimeoutAfterExit() throws {
    let startedAt = ContinuousClock.now
    let output = try SubprocessRunner.run(
        arguments: ["printf", "ready"],
        cwd: FileManager.default.currentDirectoryPath,
        environment: ProcessInfo.processInfo.environment,
        timeout: 2
    )
    let elapsed = ContinuousClock.now - startedAt

    #expect(output.terminationStatus == 0)
    #expect(String(decoding: output.standardOutput, as: UTF8.self) == "ready")
    #expect(elapsed < .milliseconds(900))
}

@Test func subprocessRunnerReturnsGitOutputWithoutWaitingForDescendantEOF() throws {
    let cwd = FileManager.default.currentDirectoryPath
    let startedAt = ContinuousClock.now
    let output = try SubprocessRunner.run(
        arguments: ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
        cwd: cwd,
        environment: ProcessInfo.processInfo.environment,
        timeout: 2
    )
    let elapsed = ContinuousClock.now - startedAt

    #expect(output.terminationStatus == 0)
    #expect(String(decoding: output.standardOutput, as: UTF8.self).contains("banyan"))
    #expect(elapsed < .milliseconds(900))
}

@Test func subprocessRunnerNeverDropsOutputUnderConcurrentLoad() async throws {
    // Regression guard for the drain race that broke worktree grouping: under
    // load, the post-exit pipe drain used to give up after its grace period and
    // return exit 0 with a truncated (often empty) stdout, which callers took
    // as a real answer. Saturate the runner and require every byte back.
    let cwd = FileManager.default.currentDirectoryPath
    let environment = ProcessInfo.processInfo.environment
    try await withThrowingTaskGroup(of: String.self) { group in
        for index in 0..<32 {
            group.addTask {
                let output = try await SubprocessRunner.runAsync(
                    arguments: ["printf", "payload-\(index)"],
                    cwd: cwd,
                    environment: environment,
                    timeout: 10
                )
                #expect(output.terminationStatus == 0)
                return String(decoding: output.standardOutput, as: UTF8.self)
            }
        }
        var results: [String] = []
        for try await result in group {
            results.append(result)
        }
        #expect(results.count == 32)
        #expect(results.allSatisfy { $0.hasPrefix("payload-") })
    }
}

@Test func subprocessRunnerHandlesLargeOutput() throws {
    let byteCount = 256 * 1024
    let output = try SubprocessRunner.run(
        arguments: ["head", "-c", "\(byteCount)", "/dev/zero"],
        cwd: FileManager.default.currentDirectoryPath,
        environment: ProcessInfo.processInfo.environment,
        timeout: 10
    )
    #expect(output.terminationStatus == 0)
    #expect(output.standardOutput.count == byteCount)
}

@Test func subprocessRunnerTimesOut() throws {
    let startedAt = ContinuousClock.now
    #expect(throws: SubprocessRunner.RunError.self) {
        try SubprocessRunner.run(
            arguments: ["sleep", "30"],
            cwd: FileManager.default.currentDirectoryPath,
            environment: ProcessInfo.processInfo.environment,
            timeout: 0.3
        )
    }
    let elapsed = ContinuousClock.now - startedAt
    #expect(elapsed < .seconds(2))
}

@Test func subprocessRunnerCancelledBeforeLaunch() throws {
    #expect {
        try SubprocessRunner.run(
            arguments: ["echo", "should not run"],
            cwd: FileManager.default.currentDirectoryPath,
            environment: ProcessInfo.processInfo.environment,
            timeout: 5,
            isCancelled: { true }
        )
    } throws: { error in
        guard let runError = error as? SubprocessRunner.RunError,
              case .cancelled = runError else { return false }
        return true
    }
}

@Test func subprocessRunnerAsyncCancellation() async throws {
    let task = Task {
        try await SubprocessRunner.runAsync(
            arguments: ["sleep", "30"],
            cwd: FileManager.default.currentDirectoryPath,
            environment: ProcessInfo.processInfo.environment,
            timeout: 60
        )
    }

    try await Task.sleep(for: .milliseconds(300))
    task.cancel()

    let startedAt = ContinuousClock.now
    do {
        _ = try await task.value
        Issue.record("Expected cancellation error")
    } catch {
        let elapsed = ContinuousClock.now - startedAt
        #expect(elapsed < .seconds(3))
        guard let runError = error as? SubprocessRunner.RunError,
              case .cancelled = runError else {
            Issue.record("Expected RunError.cancelled, got \(error)")
            return
        }
    }
}

/// Runs per descriptor-leak check, and the budget those runs may grow the table by.
///
/// The count these guard is process-wide, so tests running in parallel add noise to it —
/// tens of descriptors, opened and closed on their own schedule, which no amount of
/// settling makes deterministic. The separation comes from the run count instead: the
/// regression stranded two descriptors per run and four on the launch-failure path, so at
/// this many runs a live leak lands in the hundreds while the parallel-test noise floor
/// stays where it was. The budget sits between the two, far from each.
private let runsPerLeakCheck = 150
private let leakBudget = 120

/// Counts the descriptors this process currently holds open.
///
/// `fcntl(F_GETFD)` succeeds only for a live descriptor, so probing the low range is
/// enough: the leak this guards against grows monotonically from the first run.
private func openDescriptorCount(limit: Int32 = 4096) -> Int {
    var count = 0
    for descriptor in Int32(0)..<limit where fcntl(descriptor, F_GETFD) != -1 {
        count += 1
    }
    return count
}

@Test func subprocessRunnerReturnsItsDescriptors() throws {
    // Warm up first: the initial run pulls in lazily-opened resources (dyld images,
    // the operation queue's own machinery) whose descriptors are kept on purpose.
    for _ in 0..<3 {
        _ = try SubprocessRunner.run(
            arguments: ["printf", "warmup"],
            cwd: FileManager.default.currentDirectoryPath,
            environment: ProcessInfo.processInfo.environment,
            timeout: 5
        )
    }

    let before = openDescriptorCount()
    for _ in 0..<runsPerLeakCheck {
        _ = try SubprocessRunner.run(
            arguments: ["printf", "x"],
            cwd: FileManager.default.currentDirectoryPath,
            environment: ProcessInfo.processInfo.environment,
            timeout: 5
        )
    }
    let leaked = openDescriptorCount() - before

    #expect(leaked < leakBudget, "leaked \(leaked) descriptors across \(runsPerLeakCheck) runs")
}

@Test func subprocessRunnerReturnsItsDescriptorsWhenLaunchFails() throws {
    let before = openDescriptorCount()
    for _ in 0..<runsPerLeakCheck {
        #expect(throws: SubprocessRunner.RunError.self) {
            _ = try SubprocessRunner.run(
                arguments: ["printf", "x"],
                cwd: "/nonexistent-directory-for-launch-failure",
                environment: ProcessInfo.processInfo.environment,
                timeout: 5
            )
        }
    }
    let leaked = openDescriptorCount() - before

    // A failed launch never reaches the explicit write-end closes, so the `defer` is the
    // only thing returning these descriptors — this path leaked the hardest of all.
    #expect(leaked < leakBudget, "leaked \(leaked) descriptors across \(runsPerLeakCheck) failed launches")
}
