import Foundation

/// Runs short-lived CLI subprocesses (`linear`, `gh`, `git`, …) without leaking
/// threads.
///
/// The previous per-call pattern parked a GCD worker in
/// `Process.waitUntilExit()` and two more in `readDataToEndOfFile()`. Foundation's
/// `waitUntilExit()` spins an internal run loop that, under concurrency, can miss
/// the child's termination mach-notification and block *forever* — even after the
/// child has already exited. Those wedged workers accumulated to GCD's 80-thread
/// soft limit and froze the whole app (see the compound freeze diagnosed from a
/// `sample`: 80 dispatch threads stuck in `waitUntilExit`, cooperative pool stuck
/// in `DispatchGroup.wait`).
///
/// This runner completes via `terminationHandler` (no parked wait thread) and
/// drains pipes with `readabilityHandler` (event-driven dispatch source, no parked
/// reader threads). Every wait is timeout-bounded, and the async bridge caps total
/// concurrency so a burst of resolves can never approach the pool limits again.
enum SubprocessRunner {
    struct Output {
        let terminationStatus: Int32
        let standardOutput: Data
        let standardError: Data
    }

    enum RunError: Error {
        case launchFailed
        case timedOut
        case cancelled
    }

    /// Bridges the blocking runner onto a bounded background queue so awaiting
    /// callers (Swift-concurrency `Task`s) are *suspended*, never blocking a
    /// cooperative thread. `maxConcurrentOperationCount` also hard-caps the number
    /// of OS threads doing subprocess I/O — excess work queues as operations, not
    /// as parked threads — so this cannot exhaust the dispatch pool.
    private static let ioQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 8
        queue.qualityOfService = .utility
        queue.name = "banyan.subprocess.io"
        return queue
    }()

    /// Async, non-blocking entry point. Preferred by all callers.
    static func runAsync(
        arguments: [String],
        cwd: String,
        environment: [String: String],
        timeout: TimeInterval,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.addOperation {
                do {
                    let output = try run(
                        arguments: arguments,
                        cwd: cwd,
                        environment: environment,
                        timeout: timeout,
                        isCancelled: isCancelled
                    )
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous, leak-free runner. Blocks the calling thread only for bounded
    /// waits. Prefer `runAsync` from async contexts.
    static func run(
        arguments: [String],
        cwd: String,
        environment: [String: String],
        timeout: TimeInterval,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> Output {
        if isCancelled() { throw RunError.cancelled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutSink = DataSink()
        let stderrSink = DataSink()
        let drainGroup = DispatchGroup()
        installDrain(stdoutPipe, into: stdoutSink, group: drainGroup)
        installDrain(stderrPipe, into: stderrSink, group: drainGroup)

        // Completion is signaled by Foundation from its own queue — no thread of
        // ours is parked waiting for the child.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw RunError.launchFailed
        }

        let deadline = Date().addingTimeInterval(timeout)
        var didExit = false
        while Date() < deadline {
            if isCancelled() {
                terminate(process, exited: exited, drainGroup: drainGroup)
                throw RunError.cancelled
            }
            let slice = min(0.1, max(0, deadline.timeIntervalSinceNow))
            if exited.wait(timeout: .now() + slice) == .success {
                didExit = true
                break
            }
        }

        guard didExit else {
            terminate(process, exited: exited, drainGroup: drainGroup)
            throw RunError.timedOut
        }

        // Let the readability handlers flush the tail and report EOF. Bounded, so a
        // pipe inherited by a stray grandchild can't hang us.
        _ = drainGroup.wait(timeout: .now() + 1.0)

        return Output(
            terminationStatus: process.terminationStatus,
            standardOutput: stdoutSink.data,
            standardError: stderrSink.data
        )
    }

    private static func terminate(
        _ process: Process,
        exited: DispatchSemaphore,
        drainGroup: DispatchGroup
    ) {
        if process.isRunning {
            process.terminate()
        }
        _ = exited.wait(timeout: .now() + 0.5)
        _ = drainGroup.wait(timeout: .now() + 1.0)
    }

    /// Drains a pipe via its dispatch-source readability handler: no dedicated
    /// reader thread, and continuous draining means a child that outruns the 64 KB
    /// pipe buffer can never deadlock waiting for us to read.
    private static func installDrain(_ pipe: Pipe, into sink: DataSink, group: DispatchGroup) {
        group.enter()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                sink.append(chunk)
            }
        }
    }
}

/// Thread-safe byte accumulator: the readability handler fires on a background
/// queue while the caller reads `data` from another.
private final class DataSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
