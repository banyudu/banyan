import Foundation

/// Bounded blocking socket work, kept off Swift's cooperative executor.
/// Queued requests can be cancelled before execution. Cancellation cannot undo
/// a command already delivered; use explicit turn cancellation for that.
public enum PuckBackgroundIO {
    private static let work = WorkQueue()
    public static func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let job = Job<T>()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard job.install(continuation) else { return }
                guard work.reserve() else {
                    job.finish(.failure(PuckDaemonError.notSubmitted("SDK request queue is full; retry shortly")))
                    return
                }
                work.queue.addOperation {
                    defer { work.release() }
                    guard job.begin() else { return }
                    do { job.finish(.success(try operation())) }
                    catch { job.finish(.failure(error)) }
                }
            }
        }, onCancel: { job.cancel() })
    }
    private final class Job<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var cancelled = false
        private var running = false
        func install(_ value: CheckedContinuation<T, Error>) -> Bool {
            lock.lock()
            if cancelled {
                lock.unlock()
                value.resume(throwing: CancellationError())
                return false
            }
            continuation = value
            lock.unlock()
            return true
        }
        func begin() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            running = true
            return true
        }
        func cancel() {
            lock.lock()
            cancelled = true
            let pending = running ? nil : continuation
            if !running { continuation = nil }
            lock.unlock()
            pending?.resume(throwing: CancellationError())
        }
        func finish(_ result: Result<T, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }
    private final class WorkQueue: @unchecked Sendable {
        let queue: OperationQueue
        private let lock = NSLock()
        private var pending = 0
        init() {
            queue = OperationQueue()
            queue.name = "puck-sdk-rpc"
            queue.maxConcurrentOperationCount = 4
            queue.qualityOfService = .userInitiated
        }
        func reserve() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard pending < 64 else { return false }
            pending += 1; return true
        }
        func release() { lock.lock(); pending -= 1; lock.unlock() }
    }
}
