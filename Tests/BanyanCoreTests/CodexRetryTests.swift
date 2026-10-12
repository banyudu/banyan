import Foundation
import Testing
@testable import BanyanCore

actor CodexRetryTestClock {
    private var waits: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private(set) var delays: [TimeInterval] = []
    var count: Int { waits.count }
    func sleep(_ delay: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                delays.append(delay)
                waits.append((id, continuation))
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waits.firstIndex(where: { $0.0 == id }) else { return }
        waits.remove(at: index).1.resume(throwing: CancellationError())
    }
    func advance() { if !waits.isEmpty { waits.removeFirst().1.resume() } }
}

@Suite @MainActor
struct CodexRetryTests {
    @Test func transientClassificationExcludesPermanentAndUnknownFailures() {
        for code in ["serverOverloaded", "rateLimitExceeded", "internalServerError"] {
            #expect(CodexRetryPolicy.reason(error: error(code, "Temporary failure")) != nil)
        }
        for code in ["usageLimitExceeded", "unauthorized", "contextWindowExceeded", "sessionBudgetExceeded", "sandboxError", "badRequest", "cyberPolicy", "misalignmentPolicyViolation", "newUnknownCode"] {
            #expect(CodexRetryPolicy.reason(error: error(code, "Selected model is at capacity")) == nil)
        }
        for message in ["Selected model is at capacity. Please try a different model.", "stream disconnected before completion", "Rate limit exceeded", "Connection reset by peer"] {
            #expect(CodexRetryPolicy.reason(message: message) != nil)
        }
        for message in ["Weekly usage limit reached", "Insufficient quota: service unavailable", "Authentication failed: error sending request", "Approval required", "Context window exceeded"] {
            #expect(CodexRetryPolicy.reason(message: message) == nil)
            #expect(CodexRetryPolicy.reason(error: error("serverOverloaded", message)) == nil)
        }
        #expect(CodexRetryPolicy.reason(message: "The task failed") == nil)
        #expect(CodexRetryPolicy.reason(error: error("other", "Selected model is at capacity")) != nil)
    }

    @Test func httpFailuresRespectNonRetryableStatusCodes() {
        for status in [408, 429, 500, 502, 503, 504] {
            #expect(CodexRetryPolicy.reason(error: connectionError(status)) != nil)
        }
        for status in [400, 401, 403, 404] {
            #expect(CodexRetryPolicy.reason(error: connectionError(status)) == nil)
        }
    }

    @Test func terminalParserRequiresCurrentErrorAndEmptyComposer() {
        let screen = terminalScreen()
        #expect(CodexTerminalRetryPrompt.parse(screen)?.reason.contains("at capacity") == true)
        #expect(CodexTerminalRetryPrompt.parse(terminalScreen(draft: "")) != nil)
        #expect(CodexTerminalRetryPrompt.parse(terminalScreen(draft: "My unfinished prompt")) == nil)
        #expect(CodexTerminalRetryPrompt.parse(screen.replacingOccurrences(of: "? for shortcuts", with: "Esc to interrupt")) == nil)
        #expect(CodexTerminalRetryPrompt.parse(screen.replacingOccurrences(of: "\n\n›", with: "\nCompleted successfully\n\n›")) == nil)
        #expect(CodexTerminalRetryPrompt.parse(screen.replacingOccurrences(of: "■ ", with: "")) == nil)
        #expect(CodexTerminalRetryPrompt.parse(terminalScreen(message: "Weekly usage limit reached")) == nil)
        #expect(CodexTerminalRetryPrompt.parse("■ Selected model is at capacity\n$ ") == nil)
        #expect(CodexTerminalRetryPrompt.parse(screen + "\nnew output") == nil)
        let wrapped = screen.replacingOccurrences(of: "Please try a different model.", with: "Please try a\ndifferent model.")
        #expect(CodexTerminalRetryPrompt.parse(wrapped) != nil)
    }

    @Test func jitterIsBoundedAndBudgetStopsAfterFourRetries() async throws {
        let clock = CodexRetryTestClock()
        let controller = CodexAutoRetryController()
        controller.sleep = { try await clock.sleep($0) }
        controller.jitter = { 0.5 }
        var sent = 0
        for attempt in 1...4 {
            controller.schedule(failureID: "turn-\(attempt)", reason: "Capacity") { sent += 1 }
            #expect(controller.status?.attempt == attempt)
            try await wait { await clock.count == 1 }
            await clock.advance()
            try await wait { controller.status == nil }
        }
        controller.schedule(failureID: "turn-5", reason: "Capacity") { sent += 1 }
        #expect(controller.status?.isExhausted == true)
        #expect(sent == 4)
        #expect(await clock.delays == [15, 30, 60, 120])
        #expect(CodexRetryPolicy.delay(attempt: 1, jitter: -1) == 13.5)
        #expect(CodexRetryPolicy.delay(attempt: 1, jitter: 2) == 16.5)
        #expect(CodexRetryPolicy.delay(attempt: 5, jitter: 0.5) == nil)
        controller.reset()
        #expect(controller.attempts == 0)
    }

    @Test func duplicateFailuresAndCancellationCannotInjectAgain() async throws {
        let clock = CodexRetryTestClock()
        let controller = CodexAutoRetryController()
        controller.sleep = { try await clock.sleep($0) }
        var sent = 0
        let cancellation = controller.cancellation
        controller.schedule(failureID: "failed-turn", reason: "Capacity") { sent += 1 }
        controller.schedule(failureID: "failed-turn", reason: "Capacity") { sent += 1 }
        try await wait { await clock.count == 1 }
        controller.cancel()
        #expect(cancellation.isCancelled)
        controller.schedule(failureID: "redrawn-error", reason: "Capacity") { sent += 1 }
        try await wait { await clock.count == 0 }
        #expect(sent == 0)
        #expect(controller.status == nil)
        controller.beganTurn(automatic: false)
        controller.schedule(failureID: "new-turn", reason: "Capacity") { sent += 1 }
        try await wait { await clock.count == 1 }
        await clock.advance()
        try await wait { sent == 1 }
        controller.schedule(failureID: "new-turn", reason: "Capacity") { sent += 1 }
        #expect(controller.attempts == 1)
        #expect(controller.status == nil)
    }

    @Test func fastFailuresDuringSubmissionKeepTheBudgetAndScheduleNextWait() async throws {
        let clock = CodexRetryTestClock()
        let controller = CodexAutoRetryController()
        controller.sleep = { try await clock.sleep($0) }
        var sent = 0
        controller.schedule(failureID: "first", reason: "Capacity") {
            sent += 1
            controller.beganTurn(automatic: true)
            controller.schedule(failureID: "fast-second", reason: "Capacity") { sent += 1 }
        }
        try await wait { await clock.count == 1 }
        await clock.advance()
        try await wait { await clock.count == 1 && controller.status?.attempt == 2 }
        await clock.advance()
        try await wait { sent == 2 && controller.status == nil }
        #expect(controller.attempts == 2)
    }

    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await predicate() { return }
            await Task.yield()
        }
        throw RetryTestFailure.timeout
    }
    private enum RetryTestFailure: Error { case timeout }
    private func error(_ code: String, _ message: String) -> CodexJSONValue {
        .object(["codexErrorInfo": .string(code), "message": .string(message)])
    }
    private func connectionError(_ status: Int) -> CodexJSONValue {
        .object(["message": .string("Connection failed"), "codexErrorInfo": .object([
            "httpConnectionFailed": .object(["httpStatusCode": .integer(Int64(status))])])])
    }
    private func terminalScreen(draft: String = "Ask Codex to do anything", message: String = "Selected model is at capacity. Please try a different model.") -> String {
        "Read files\n■ \(message)\n\n› \(draft)\nGPT · Context 15% used · weekly 93% left\n? for shortcuts"
    }
}
