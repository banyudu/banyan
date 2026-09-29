@testable import Banyan
import BanyanCore
import Foundation
import Testing

/// Invoked by scripts/verify-puck-integration.py against a real local puckd.
/// Ordinary test runs skip this because no fixture session is configured.
@Test @MainActor func appPuckBrowserSeesSharedDaemonSessionAndItsEvents() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let id = environment["BANYAN_PUCK_E2E_SESSION"],
          let cursorText = environment["BANYAN_PUCK_E2E_AFTER_CURSOR"],
          let priorCursor = UInt64(cursorText) else { return }
    let browser = PuckSessionBrowser()
    browser.refresh()
    try await waitForPuckFixture {
        browser.sessions.contains(where: { $0.id == id })
    }
    browser.select(id)
    try await waitForPuckFixture {
        browser.selectedSummary?.id == id && !browser.isConnecting
    }
    if let readyFile = environment["BANYAN_PUCK_E2E_READY_FILE"] {
        try "ready".write(toFile: readyFile, atomically: true, encoding: .utf8)
    }
    try await waitForPuckFixture(timeout: .seconds(30)) {
        browser.events.contains(where: { $0.cursor > priorCursor && $0.kind == "turn_done" })
    }
    #expect(browser.selectedSummary?.id == id)
    #expect(browser.events.contains(where: {
        $0.cursor > priorCursor && $0.displayText?.contains("fixture done") == true
    }))
    browser.detach()
}

@Test @MainActor func appPuckBrowserAnswersParkedQuestion() async throws {
    guard let id = ProcessInfo.processInfo.environment["BANYAN_PUCK_E2E_QUESTION_SESSION"] else { return }
    let direct = try PuckDaemonClient().get(id)
    #expect(direct.pendingQuestion?.callID == "question-1")
    let browser = PuckSessionBrowser()
    browser.select(id)
    try await waitForPuckFixture {
        browser.selectedSummary?.pendingQuestion?.callID == "question-1"
    }
    let pending = try #require(browser.selectedSummary?.pendingQuestion)
    #expect(pending.questions.first?.options.map(\.label) == ["Approve", "Deny"])
    browser.answer([PuckQuestionSelection(labels: ["Approve"])])
    try await waitForPuckFixture {
        browser.events.contains(where: { $0.kind == "turn_done" })
            && browser.selectedSummary?.pendingQuestion == nil
    }
    browser.detach()
}

@MainActor
private func waitForPuckFixture(
    timeout: Duration = .seconds(10),
    until condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline {
            throw PuckFixtureError.timedOut
        }
        try await Task.sleep(for: .milliseconds(50))
    }
}

private enum PuckFixtureError: Error {
    case timedOut
}
