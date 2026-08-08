import Foundation

/// Runs short-lived CLI subprocesses (`linear`, `gh`, `git`, …) without leaking
/// threads.
///
/// Output is captured through in-memory pipes drained by `DispatchIO` (dispatch
/// sources — no thread is parked). The previous implementation wrote two temp
/// files per call, adding a mkdir + 2 creat + 2 open + read + 2 unlink + rmdir
/// per invocation — eliminated here.
///
/// The process-exit wait uses the **full timeout** in a single semaphore call.
/// Cancellation from `runAsync` is delivered immediately via
/// `withTaskCancellationHandler` signalling the same semaphore, avoiding the
/// 100 ms polling loop that used to wake a blocked worker 10×/sec per child.
public enum SubprocessRunner {
    public struct Output {
        public let terminationStatus: Int32
        public let standardOutput: Data
        public let standardError: Data
    }

    public enum RunError: LocalizedError {
        case launchFailed(underlying: Error)
        case timedOut
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .launchFailed(let underlying):
                return "Launch failed: \(underlying.localizedDescription)"
            case .timedOut:
                return "Subprocess timed out"
            case .cancelled:
                return "Subprocess cancelled"
            }
        }
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
    ///
    /// Task cancellation signals the wait semaphore directly via
    /// `withTaskCancellationHandler`, so the blocked `run()` wakes immediately
    /// without any polling.
    public static func runAsync(
        arguments: [String],
        cwd: String,
        environment: [String: String],
        timeout: TimeInterval,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> Output {
        let wakeSignal = DispatchSemaphore(value: 0)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ioQueue.addOperation {
                    do {
                        let output = try run(
                            arguments: arguments,
                            cwd: cwd,
                            environment: environment,
                            timeout: timeout,
                            isCancelled: isCancelled,
                            wakeSignal: wakeSignal
                        )
                        continuation.resume(returning: output)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            wakeSignal.signal()
        }
    }

    /// Synchronous, leak-free runner. Blocks the calling thread only for bounded
    /// waits. Prefer `runAsync` from async contexts.
    ///
    /// - Parameter wakeSignal: When non-nil the semaphore is shared with
    ///   `runAsync`'s cancellation handler so that Task cancellation wakes the
    ///   wait immediately. Callers of the synchronous API leave this `nil`.
    public static func run(
        arguments: [String],
        cwd: String,
        environment: [String: String],
        timeout: TimeInterval,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        wakeSignal: DispatchSemaphore? = nil
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

        // Share the semaphore with the async cancel path when available,
        // otherwise create a private one.
        let exited: DispatchSemaphore
        if let wakeSignal {
            exited = wakeSignal
        } else {
            exited = DispatchSemaphore(value: 0)
        }
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(underlying: error)
        }

        // Close the write ends in the parent so reads EOF once the child
        // (and any grandchildren) close their copies.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        // Drain both pipes concurrently with DispatchIO so the pipe buffer
        // cannot fill and deadlock the child. DispatchIO uses dispatch
        // sources internally — no thread is parked.
        let drainDone = DispatchGroup()
        let stdoutAccum = _PipeAccumulator()
        let stderrAccum = _PipeAccumulator()
        let drainQueue = DispatchQueue.global(qos: .utility)

        let stdoutChannel = DispatchIO(
            type: .stream,
            fileDescriptor: stdoutPipe.fileHandleForReading.fileDescriptor,
            queue: drainQueue,
            cleanupHandler: { _ in }
        )
        drainDone.enter()
        stdoutChannel.read(offset: 0, length: .max, queue: drainQueue) { done, data, _ in
            if let data, !data.isEmpty { stdoutAccum.append(data) }
            if done { drainDone.leave() }
        }

        let stderrChannel = DispatchIO(
            type: .stream,
            fileDescriptor: stderrPipe.fileHandleForReading.fileDescriptor,
            queue: drainQueue,
            cleanupHandler: { _ in }
        )
        drainDone.enter()
        stderrChannel.read(offset: 0, length: .max, queue: drainQueue) { done, data, _ in
            if let data, !data.isEmpty { stderrAccum.append(data) }
            if done { drainDone.leave() }
        }

        // ── Wait for the process to exit with the full timeout ──────────
        // One semaphore call replaces the old 100 ms polling loop.
        // If `runAsync` was cancelled the same semaphore is signalled by the
        // `onCancel` handler, waking us immediately.
        let waitResult = exited.wait(timeout: .now() + timeout)

        if waitResult == .timedOut {
            terminate(process, exited: exited)
            stdoutChannel.close(flags: .stop)
            stderrChannel.close(flags: .stop)
            _ = drainDone.wait(timeout: .now() + 0.1)
            throw RunError.timedOut
        }

        // The semaphore was signalled. If the process is still running the
        // signal came from the async cancel path, not the termination
        // handler.
        if process.isRunning || isCancelled() {
            terminate(process, exited: exited)
            stdoutChannel.close(flags: .stop)
            stderrChannel.close(flags: .stop)
            _ = drainDone.wait(timeout: .now() + 0.1)
            throw RunError.cancelled
        }

        // ── Normal exit ─────────────────────────────────────────────────
        // Close channels cleanly so any remaining buffered data is
        // delivered, then collect output. The 1 s cap guards against a
        // detached grandchild that inherited the pipe FDs.
        stdoutChannel.close()
        stderrChannel.close()
        _ = drainDone.wait(timeout: .now() + 1.0)

        return Output(
            terminationStatus: process.terminationStatus,
            standardOutput: stdoutAccum.data,
            standardError: stderrAccum.data
        )
    }

    private static func terminate(
        _ process: Process,
        exited: DispatchSemaphore
    ) {
        if process.isRunning {
            process.terminate()
        }
        _ = exited.wait(timeout: .now() + 0.5)
    }
}

// MARK: - Pipe accumulator

/// Thread-safe buffer that collects `DispatchData` chunks from `DispatchIO`
/// read callbacks and materialises them as a single `Data`.
private final class _PipeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [DispatchData] = []

    func append(_ chunk: DispatchData) {
        lock.lock()
        chunks.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        var result = Data()
        for chunk in chunks {
            result.append(contentsOf: chunk)
        }
        return result
    }
}
