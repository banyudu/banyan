import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Runs short-lived CLI subprocesses (`linear`, `gh`, `git`, …) without leaking
/// threads.
///
/// Output is captured by reading the child's pipes directly from the calling
/// thread with `poll(2)`: the same wait observes stdout, stderr, child exit and
/// task cancellation, so a run needs no worker thread of its own beyond the one
/// already blocked in `run()`.
///
/// That single `poll` is what makes the drain exhaustive. The previous
/// implementation handed the pipes to `DispatchIO` and, after the child exited,
/// waited a fixed grace for the read callbacks to arrive. On a CPU-bound Linux
/// runner those callbacks share a thread pool with the callers blocked waiting
/// for them, so under concurrent load they landed after the grace expired and
/// `run()` returned exit 0 with truncated (usually empty) stdout — which callers
/// such as `SessionDisplayLabel.gitRemoteURL` took for a real answer. Reading the
/// descriptors inline removes the scheduling dependency entirely: once the child
/// has exited, every byte it wrote is already in the kernel pipe buffer, so
/// draining to `EAGAIN`/EOF right then is complete by construction rather than
/// after a timed guess.
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

    /// Grace given to a child to exit on `SIGTERM` before it is `SIGKILL`ed.
    private static let terminationGrace: TimeInterval = 0.5

    /// How long to wait for a `SIGKILL`ed child to be *reaped*. The kill itself is
    /// immediate; this covers Foundation's exit monitoring, which on Linux notices
    /// a dead child on a ~300 ms tick. Returning before the reap would leave a
    /// zombie behind for every timed-out run, so the bound is several ticks wide.
    private static let reapGrace: TimeInterval = 2

    /// Worst case a run may overrun its `timeout` by while tearing down a child
    /// that ignores `SIGTERM`. Callers sizing their own deadline around a run
    /// should add this rather than guessing at it.
    public static let terminationBudget: TimeInterval = terminationGrace + reapGrace

    /// Longest a single `poll` may block when the wake pipe is unavailable, so the
    /// loop still notices exit and cancellation. Unused on the normal path, where
    /// `poll` waits on the wake pipe itself and returns no later than the deadline.
    private static let fallbackPollSliceMilliseconds: Int32 = 20

    /// Async, non-blocking entry point. Preferred by all callers.
    ///
    /// Task cancellation writes to the run's wake pipe via
    /// `withTaskCancellationHandler`, so the blocked `poll` returns immediately
    /// without any polling.
    public static func runAsync(
        arguments: [String],
        cwd: String,
        environment: [String: String],
        timeout: TimeInterval,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        standardInput: FileHandle? = nil
    ) async throws -> Output {
        let signal = RunSignal()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ioQueue.addOperation {
                    // Cancelled while queued behind the concurrency cap: return
                    // without launching anything, so a backlog of cancelled work
                    // drains at once instead of each entry paying a full run.
                    if signal.isCancelled {
                        continuation.resume(throwing: RunError.cancelled)
                        return
                    }
                    do {
                        let output = try run(
                            arguments: arguments,
                            cwd: cwd,
                            environment: environment,
                            timeout: timeout,
                            isCancelled: isCancelled,
                            standardInput: standardInput,
                            signal: signal
                        )
                        continuation.resume(returning: output)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            signal.cancel()
        }
    }

    /// Synchronous, leak-free runner. Blocks the calling thread only for bounded
    /// waits, and uses no other thread. Prefer `runAsync` from async contexts.
    ///
    /// - Parameter standardInput: Passed through to the child. The default leaves
    ///   the parent's stdin inherited; pass `FileHandle.nullDevice` for children
    ///   that must never read from it.
    public static func run(
        arguments: [String],
        cwd: String,
        environment: [String: String],
        timeout: TimeInterval,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        standardInput: FileHandle? = nil
    ) throws -> Output {
        try run(
            arguments: arguments,
            cwd: cwd,
            environment: environment,
            timeout: timeout,
            isCancelled: isCancelled,
            standardInput: standardInput,
            signal: RunSignal()
        )
    }

    private static func run(
        arguments: [String],
        cwd: String,
        environment: [String: String],
        timeout: TimeInterval,
        isCancelled: @escaping @Sendable () -> Bool,
        standardInput: FileHandle?,
        signal: RunSignal
    ) throws -> Output {
        // Closing the wake pipe here also disarms the termination and cancellation
        // handlers, which may still fire after this call returns.
        defer { signal.invalidate() }

        if isCancelled() || signal.isCancelled { throw RunError.cancelled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment
        if let standardInput {
            process.standardInput = standardInput
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { _ in signal.markExited() }

        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(underlying: error)
        }

        // Close the write ends in the parent so reads EOF once the child
        // (and any grandchildren) close their copies.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        // Both pipes must be drained *while* the child runs: a child that fills the
        // ~64KB buffer blocks in `write` and never exits, which would defeat the
        // timeout below.
        var stdoutReader = PipeReader(fileHandle: stdoutPipe.fileHandleForReading)
        var stderrReader = PipeReader(fileHandle: stderrPipe.fileHandleForReading)
        let deadline = Deadline(after: timeout)

        while !signal.hasExited {
            if isCancelled() || signal.isCancelled {
                terminate(process, signal: signal)
                throw RunError.cancelled
            }
            let remaining = deadline.remainingMilliseconds()
            if remaining == 0 {
                terminate(process, signal: signal)
                throw RunError.timedOut
            }

            var descriptors: [pollfd] = []
            if let descriptor = stdoutReader.pollDescriptor { descriptors.append(descriptor) }
            if let descriptor = stderrReader.pollDescriptor { descriptors.append(descriptor) }
            descriptors.append(signal.pollDescriptor)

            let slice = signal.isPollable
                ? remaining
                : min(remaining, fallbackPollSliceMilliseconds)
            if poll(&descriptors, nfds_t(descriptors.count), slice) < 0 {
                if errno == EINTR { continue }
                // `poll` cannot make progress on these descriptors; back off so the
                // deadline above still bounds the run instead of spinning.
                usleep(useconds_t(fallbackPollSliceMilliseconds) * 1000)
            }

            stdoutReader.drainAvailable()
            stderrReader.drainAvailable()
            signal.consume()
        }

        // ── Normal exit ─────────────────────────────────────────────────
        // The child is gone, so everything it wrote is already buffered in the
        // kernel: this drain reads it all rather than waiting out a grace period.
        // Anything still holding the write end open is a detached grandchild whose
        // later output was never ours to wait for.
        stdoutReader.drainAvailable()
        stderrReader.drainAvailable()

        // Cancellation that lands in the same instant the child finishes still wins:
        // the caller asked to stop, so it must not be handed a result to act on.
        if isCancelled() || signal.isCancelled { throw RunError.cancelled }

        return Output(
            terminationStatus: process.terminationStatus,
            standardOutput: stdoutReader.data,
            standardError: stderrReader.data
        )
    }

    private static func terminate(_ process: Process, signal: RunSignal) {
        guard process.isRunning else { return }
        process.terminate()
        if waitForExit(signal, seconds: terminationGrace) { return }
        // A child that ignores SIGTERM would otherwise linger as a zombie holding
        // the pipe write ends open. Re-check `isRunning` first: once Foundation has
        // reaped the child its pid is free for the OS to hand to someone else, and
        // signalling that pid would hit an unrelated process.
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        waitForExit(signal, seconds: reapGrace)
    }

    @discardableResult
    private static func waitForExit(_ signal: RunSignal, seconds: TimeInterval) -> Bool {
        let deadline = Deadline(after: seconds)
        while !signal.hasExited {
            let remaining = deadline.remainingMilliseconds()
            if remaining == 0 { break }
            var descriptor = signal.pollDescriptor
            let slice = signal.isPollable
                ? remaining
                : min(remaining, fallbackPollSliceMilliseconds)
            if withUnsafeMutablePointer(to: &descriptor, { poll($0, 1, slice) }) < 0,
               errno != EINTR {
                usleep(useconds_t(fallbackPollSliceMilliseconds) * 1000)
            }
            signal.consume()
        }
        return signal.hasExited
    }
}

// MARK: - Deadline

/// Monotonic deadline, immune to wall-clock changes, expressed in the `poll`
/// timeout's own units.
private struct Deadline {
    private let expiresAt: UInt64

    init(after seconds: TimeInterval) {
        let bounded = min(max(seconds, 0), 60 * 60 * 24)
        expiresAt = DispatchTime.now().uptimeNanoseconds
            &+ UInt64((bounded * 1_000_000_000).rounded())
    }

    /// Milliseconds left, rounded up so a sub-millisecond remainder still gets one
    /// more `poll`; `0` once expired.
    func remainingMilliseconds() -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard expiresAt > now else { return 0 }
        let milliseconds = (expiresAt - now + 999_999) / 1_000_000
        return milliseconds > UInt64(Int32.max) ? Int32.max : Int32(milliseconds)
    }
}

// MARK: - Wake channel

/// Wake channel shared by the `poll` loop, `Process.terminationHandler` and
/// `runAsync`'s cancellation handler.
///
/// A pipe rather than a semaphore, so "the child exited" and "the task was
/// cancelled" can be awaited in the *same* `poll` as the child's output. Waiting
/// on a semaphore instead would mean a second wait that no longer drains the
/// pipes — the shape that used to lose output.
private final class RunSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var readFD: Int32 = -1
    private var writeFD: Int32 = -1
    private var exited = false
    private var cancelled = false

    init() {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return }
        readFD = ends[0]
        writeFD = ends[1]
        // Non-blocking on both ends: draining must never block the poll loop, and
        // signalling must never block a termination handler on a full pipe.
        for end in ends {
            let flags = fcntl(end, F_GETFL, 0)
            if flags >= 0 { _ = fcntl(end, F_SETFL, flags | O_NONBLOCK) }
        }
    }

    deinit { invalidate() }

    var hasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exited
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// `false` only if the pipe could not be created, in which case callers fall
    /// back to short `poll` slices.
    var isPollable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readFD >= 0
    }

    var pollDescriptor: pollfd {
        lock.lock()
        defer { lock.unlock() }
        // A negative fd is ignored by `poll`, which then simply waits out its
        // timeout — the fallback slice keeps that responsive.
        return pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
    }

    func markExited() {
        lock.lock()
        exited = true
        wakeLocked()
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        wakeLocked()
        lock.unlock()
    }

    /// Clears pending wake bytes so the next `poll` blocks again.
    func consume() {
        lock.lock()
        defer { lock.unlock() }
        guard readFD >= 0 else { return }
        var scratch = [UInt8](repeating: 0, count: 64)
        while read(readFD, &scratch, scratch.count) > 0 {}
    }

    /// Closes the pipe. Later signals become no-ops rather than writing into a
    /// descriptor number the process has since recycled.
    func invalidate() {
        lock.lock()
        let ends = (read: readFD, write: writeFD)
        readFD = -1
        writeFD = -1
        lock.unlock()

        if ends.read >= 0 { close(ends.read) }
        if ends.write >= 0 { close(ends.write) }
    }

    private func wakeLocked() {
        guard writeFD >= 0 else { return }
        var byte: UInt8 = 1
        _ = write(writeFD, &byte, 1)
    }
}

// MARK: - Pipe reader

/// Non-blocking reader over one end of a `Pipe`, accumulating everything the
/// child writes.
private struct PipeReader {
    /// Held so the pipe's descriptor stays open for the lifetime of the read.
    private let handle: FileHandle
    private let descriptor: Int32
    private(set) var data = Data()
    private var isAtEnd = false

    init(fileHandle: FileHandle) {
        handle = fileHandle
        descriptor = fileHandle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    }

    /// `nil` once the write end has closed, so a finished pipe stops waking `poll`.
    var pollDescriptor: pollfd? {
        isAtEnd ? nil : pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    }

    /// Reads everything the kernel currently holds, without blocking.
    ///
    /// Called after the child exits this is exhaustive, not best-effort: a
    /// completed `write` has already deposited its bytes in the pipe buffer, so
    /// reading to `EAGAIN`/EOF cannot truncate the child's output.
    mutating func drainAvailable() {
        guard !isAtEnd else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                chunk.withUnsafeBufferPointer { buffer in
                    if let base = buffer.baseAddress { data.append(base, count: count) }
                }
                continue
            }
            if count == 0 {
                isAtEnd = true
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            // Any other error is unrecoverable for this descriptor.
            isAtEnd = true
            return
        }
    }
}
