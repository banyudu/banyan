import Foundation

/// Recovery is deliberately narrower than "retry every failed turn".
public enum CodexRetryPolicy {
    public static let delays: [TimeInterval] = [15, 30, 60, 120]
    public static let continuation = "Continue the interrupted task from where you left off. Check the current state and completed tool results before repeating any action."

    public static func reason(error: CodexJSONValue) -> String? {
        let fields = error.objectValue ?? [:]
        let message = fields["message"]?.stringValue ?? ""
        guard !isPermanent(message.lowercased()) else { return nil }
        if let info = fields["codexErrorInfo"], info != .null {
            if let code = info.stringValue {
                switch code {
                case "serverOverloaded", "rateLimitExceeded", "internalServerError": return message.isEmpty ? code : message
                case "other": break // Some CLI versions report capacity as Other.
                default: return nil
                }
            } else if let object = info.objectValue, object.count == 1,
                      let entry = object.first,
                      ["httpConnectionFailed", "responseStreamConnectionFailed", "responseStreamDisconnected", "responseTooManyFailedAttempts"].contains(entry.key) {
                let status = entry.value.objectValue?["httpStatusCode"]
                if case .integer(let number) = status, number != 408 && number != 429 && !(500...599).contains(number) { return nil }
                return message.isEmpty ? "Connection interrupted" : message
            } else { return nil }
        }
        return reason(message: message)
    }

    public static func reason(message: String) -> String? {
        let text = message.lowercased()
        guard !isPermanent(text) else { return nil }
        let transient = ["selected model is at capacity", "server is overloaded", "server overloaded",
            "model is overloaded", "temporarily overloaded", "too many requests", "rate limit exceeded", "rate limit reached",
            "stream disconnected before completion", "connection reset by peer", "connection timed out",
            "error sending request", "failed to connect", "service unavailable"]
        return transient.contains(where: text.contains) ? message : nil
    }

    private static func isPermanent(_ text: String) -> Bool {
        ["quota", "usage limit", "usage_limit", "spend limit", "budget", "insufficient credit", "out of credit", "unauthorized", "authentication",
         "sign in", "log in", "api key", "context window", "context length", "policy", "permission", "approval"]
            .contains(where: text.contains)
    }

    public static func delay(attempt: Int, jitter: Double) -> TimeInterval? {
        guard delays.indices.contains(attempt - 1) else { return nil }
        return delays[attempt - 1] * (0.9 + min(1, max(0, jitter)) * 0.2)
    }
}

/// Parses only the current Codex error block immediately above an empty composer.
/// Callers must independently verify the live process, pane, and idle state.
public struct CodexTerminalRetryPrompt: Sendable, Equatable {
    public let reason: String
    public let footprint: String

    public static func parse(_ text: String) -> Self? {
        let lines = text.suffix(24_000).components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let composer = lines.lastIndex(where: { $0.hasPrefix("›") || $0.hasPrefix("❯") || $0.hasPrefix(">") }) else { return nil }
        let draft = String(lines[composer].dropFirst()).trimmingCharacters(in: .whitespaces)
        guard draft.isEmpty || draft == "Ask Codex to do anything" else { return nil }
        let footer = lines.suffix(from: composer + 1).filter { !$0.isEmpty }
        guard footer.contains(where: { $0.contains("? for shortcuts") }),
              footer.allSatisfy({ $0.contains("? for shortcuts") || $0.contains("Context") || $0.contains("context") || $0.contains("·") }),
              !footer.contains(where: { $0.lowercased().contains("interrupt") }) else { return nil }
        var end = composer
        while end > 0, lines[end - 1].isEmpty { end -= 1 }
        guard let start = lines[..<end].lastIndex(where: { $0.hasPrefix("■ ") }), end - start <= 4 else { return nil }
        let message = ([String(lines[start].dropFirst()).trimmingCharacters(in: .whitespaces)] + Array(lines[(start + 1)..<end])).joined(separator: " ")
        if message.lowercased().hasPrefix("selected model is at capacity") {
            guard ["Selected model is at capacity.", "Selected model is at capacity. Please try a different model."].contains(message) else { return nil }
        } else if end - start != 1 { return nil }
        guard let reason = CodexRetryPolicy.reason(message: message) else { return nil }
        return Self(reason: reason, footprint: lines[..<end].joined(separator: "\n"))
    }
}

public struct CodexRetryStatus: Sendable, Equatable {
    public let attempt: Int
    public let retryAt: Date?
    public let reason: String
    public var isExhausted: Bool { attempt > CodexRetryPolicy.delays.count }
}

/// Shared with subprocess submission so input can revoke queued background work.
public final class CodexRetryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public var isCancelled: Bool { lock.withLock { cancelled } }
    fileprivate func cancel() { lock.withLock { cancelled = true } }
}

/// Owns one cancellable wait per session. No timer, polling, or process restart.
@MainActor
public final class CodexAutoRetryController {
    public private(set) var status: CodexRetryStatus? { didSet { onChange?(status) } }
    public var onChange: ((CodexRetryStatus?) -> Void)?
    public var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    public var jitter: () -> Double = { Double.random(in: 0...1) }
    public private(set) var attempts = 0
    public private(set) var generation = UUID()
    public private(set) var isSubmitting = false
    public private(set) var cancellation = CodexRetryCancellation()
    private var suppressed = false
    private var failures: Set<String> = []
    private var task: Task<Void, Never>?
    private var pending: (String, String, @MainActor () async throws -> Void)?

    public init() {}
    deinit { task?.cancel() }

    public func schedule(failureID: String, reason: String, operation: @escaping @MainActor () async throws -> Void) {
        if isSubmitting, !suppressed, !failures.contains(failureID) {
            pending = (failureID, reason, operation)
            return
        }
        guard !suppressed, !failures.contains(failureID), task == nil else { return }
        failures.insert(failureID)
        guard let delay = CodexRetryPolicy.delay(attempt: attempts + 1, jitter: jitter()) else {
            suppressed = true
            status = .init(attempt: attempts + 1, retryAt: nil, reason: reason)
            return
        }
        attempts += 1
        let token = generation
        status = .init(attempt: attempts, retryAt: Date().addingTimeInterval(delay), reason: reason)
        let sleep = sleep
        task = Task { [weak self] in
            do { try await sleep(delay); try Task.checkCancellation() }
            catch { return }
            guard let self, self.generation == token else { return }
            self.isSubmitting = true
            self.status = .init(attempt: self.attempts, retryAt: nil, reason: reason)
            do { try await operation() }
            catch {
                if self.generation == token { self.cancel() }
            }
            guard self.generation == token else { return }
            self.isSubmitting = false
            self.task = nil
            self.status = nil
            if let pending = self.pending {
                self.pending = nil
                self.schedule(failureID: pending.0, reason: pending.1, operation: pending.2)
            }
        }
    }

    /// User interaction suppresses the same failed task, including repeated redraws.
    public func cancel() {
        cancellation.cancel()
        cancellation = CodexRetryCancellation()
        generation = UUID()
        task?.cancel(); task = nil
        pending = nil
        isSubmitting = false
        suppressed = true
        status = nil
    }

    public func beganTurn(automatic: Bool) {
        guard !automatic else { return }
        reset()
    }

    public func reset() {
        cancel()
        suppressed = false
        failures.removeAll(keepingCapacity: true)
        attempts = 0
    }
}
