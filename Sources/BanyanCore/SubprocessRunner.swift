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
/// captures output in temporary files. Regular files are intentional: a detached
/// grandchild can inherit stdout/stderr and keep a pipe open long after the command
/// itself exits, making an EOF-based drain add latency to every invocation. Every
/// wait is timeout-bounded, and the async bridge caps total concurrency so a burst
/// of resolves can never approach the pool limits again.
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
    public static func runAsync(
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
    public static func run(
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

        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("banyan-subprocess-\(UUID().uuidString)", isDirectory: true)
        let stdoutURL = captureDirectory.appendingPathComponent("stdout")
        let stderrURL = captureDirectory.appendingPathComponent("stderr")
        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle
        do {
            try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: false)
            guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
                  FileManager.default.createFile(atPath: stderrURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            stderrHandle = try FileHandle(forWritingTo: stderrURL)
        } catch {
            try? FileManager.default.removeItem(at: captureDirectory)
            throw RunError.launchFailed(underlying: error)
        }
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? FileManager.default.removeItem(at: captureDirectory)
        }
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        // Completion is signaled by Foundation from its own queue — no thread of
        // ours is parked waiting for the child.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(underlying: error)
        }

        let deadline = Date().addingTimeInterval(timeout)
        var didExit = false
        while Date() < deadline {
            if isCancelled() {
                terminate(process, exited: exited)
                throw RunError.cancelled
            }
            let slice = min(0.1, max(0, deadline.timeIntervalSinceNow))
            if exited.wait(timeout: .now() + slice) == .success {
                didExit = true
                break
            }
        }

        guard didExit else {
            terminate(process, exited: exited)
            throw RunError.timedOut
        }

        try? stdoutHandle.close()
        try? stderrHandle.close()

        return Output(
            terminationStatus: process.terminationStatus,
            standardOutput: (try? Data(contentsOf: stdoutURL)) ?? Data(),
            standardError: (try? Data(contentsOf: stderrURL)) ?? Data()
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
