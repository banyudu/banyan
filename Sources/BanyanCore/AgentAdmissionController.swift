import Foundation

public struct AgentLaunchQueueState: Codable, Equatable, Sendable {
    public enum Purpose: String, Codable, Sendable { case launch, restart, deepResume }
    public var requestedAt: Date
    public var cancelled: Bool
    public var purpose: Purpose?
    public init(requestedAt: Date = Date(), cancelled: Bool = false, purpose: Purpose? = nil) {
        self.requestedAt = requestedAt
        self.cancelled = cancelled
        self.purpose = purpose
    }
}

/// One slot is a managed terminal command's lifetime, or an active daemon turn.
/// Reservations include launches/RPCs in flight. Everything runs on the main
/// actor so capacity cannot be read and claimed concurrently across frontends.
@MainActor
public final class AgentAdmissionController {
    nonisolated public static let defaultLimit = 100
    nonisolated public static let maximumLimit = 100
    nonisolated public static let defaultsKey = "maximumConcurrentAgents"
    /// A queued launch or turn may take a reservation away from a verified-idle
    /// terminal command once its pane has been silent this long. Idle commands
    /// otherwise hold their reservation until their process exits, so without a
    /// quiet window a fleet of idle commands above the cap would block the queue
    /// forever and the status of a just-started turn could free capacity early.
    nonisolated public static let idleYieldQuiescenceSeconds: TimeInterval = 45
    public private(set) var limit: Int
    public private(set) var running: Set<String> = []
    public var queuedIDs: [String] { queue.map(\.id) }
    public var onChange: (() -> Void)?

    private struct Entry {
        let id: String
        var start: (() -> Void)?
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    }
    private var queue: [Entry] = []
    private var draining = false

    public init(limit: Int = defaultLimit) { self.limit = max(1, limit) }

    public func setLimit(_ value: Int) {
        limit = max(1, value)
        // Lowering the cap never terminates or preempts existing work.
        drain()
    }

    public func position(of id: String) -> Int? { queue.firstIndex { $0.id == id }.map { $0 + 1 } }

    /// Synchronous transports must refuse before queuing work they cannot
    /// acknowledge. Existing owners may continue; FIFO waiters keep priority.
    public func acquireImmediately(_ id: String) -> Bool {
        if running.contains(id) { return true }
        guard queue.isEmpty, running.count < limit else { return false }
        running.insert(id)
        onChange?()
        return true
    }

    /// Synchronous launch paths retry only after this callback owns a slot.
    /// Duplicate foreground/background attempts share the same queue entry.
    public func request(_ id: String, start: @escaping () -> Void) -> Bool {
        if running.contains(id) { return true }
        if queue.contains(where: { $0.id == id }) { return false }
        if queue.isEmpty && running.count < limit {
            running.insert(id)
            onChange?()
            return true
        }
        queue.append(Entry(id: id, start: start))
        onChange?()
        return false
    }

    /// Never hold a runtime's lifecycle mutex while waiting for admission.
    public func acquire(_ id: String) async throws {
        try Task.checkCancellation()
        if running.contains(id) { return }
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if running.contains(id) { continuation.resume(); return }
                if queue.isEmpty && running.count < limit {
                    running.insert(id)
                    onChange?()
                    continuation.resume()
                } else if let index = queue.firstIndex(where: { $0.id == id }) {
                    queue[index].waiters[token] = continuation
                } else {
                    queue.append(Entry(id: id, waiters: [token: continuation]))
                    onChange?()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(id: id, token: token) }
        }
        try Task.checkCancellation()
    }

    /// Account for already-running/restored/external work even above the cap.
    /// This does not stop it or admit any *additional* work while over budget.
    public func adopt(_ id: String) {
        running.insert(id)
        if let index = queue.firstIndex(where: { $0.id == id }) {
            let entry = queue.remove(at: index)
            for waiter in entry.waiters.values { waiter.resume() }
        }
        onChange?()
    }

    /// Only call after confirmed exit/turn completion, never on UI parking,
    /// SIGSTOP, an optimistic status change, or an unacknowledged interrupt.
    public func release(_ id: String) {
        running.remove(id)
        drain()
    }

    public func cancel(_ id: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let entry = queue.remove(at: index)
        for waiter in entry.waiters.values { waiter.resume(throwing: CancellationError()) }
        drain()
    }

    /// Explicit user intent can change FIFO order; selection alone cannot.
    public func prioritize(_ id: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.insert(queue.remove(at: index), at: 0)
        drain()
    }

    private func cancelWaiter(id: String, token: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }),
              let waiter = queue[index].waiters.removeValue(forKey: token) else { return }
        waiter.resume(throwing: CancellationError())
        if queue[index].waiters.isEmpty && queue[index].start == nil { queue.remove(at: index) }
        drain()
    }

    private func drain() {
        guard !draining else { return }
        draining = true
        defer { draining = false; onChange?() }
        while running.count < limit, !queue.isEmpty {
            let entry = queue.removeFirst()
            running.insert(entry.id)
            onChange?()
            for waiter in entry.waiters.values { waiter.resume() }
            entry.start?()
        }
    }
}
