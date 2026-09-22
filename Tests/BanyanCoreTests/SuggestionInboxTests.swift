import Foundation
import Testing
@testable import BanyanCore

private func makeSuggestion(
    key: String? = nil,
    title: String = "Review TASK-123",
    detail: String? = nil,
    target: String? = nil,
    command: String = "workit TASK-123",
    cwd: String? = nil,
    run: CommandRunMode = .session,
    receivedAt: Date = Date(),
    ttl: TimeInterval? = nil
) -> InboundSuggestion {
    InboundSuggestion(
        key: key,
        title: title,
        detail: detail,
        target: target,
        command: command,
        cwd: cwd,
        run: run,
        receivedAt: receivedAt,
        ttl: ttl
    )
}

@Test func suggestionKeyFallsBackToTargetThenCommand() {
    #expect(makeSuggestion(key: "stale-review:TASK-123", target: "TASK-123").key == "stale-review:TASK-123")
    #expect(makeSuggestion(target: "TASK-123").key == "TASK-123")
    #expect(makeSuggestion(command: "workit TASK-9").key == "workit TASK-9")
    // Blank flags are the same as absent ones: `--key ""` must not become the key.
    #expect(makeSuggestion(key: "  ", target: " TASK-7 ").key == "TASK-7")
}

@Test func suggestionNormalizesOptionalTextAndClampsTTL() {
    let suggestion = makeSuggestion(
        detail: "   ",
        target: "  TASK-123  ",
        cwd: " ",
        receivedAt: Date(timeIntervalSince1970: 0),
        ttl: 5
    )
    #expect(suggestion.detail == nil)
    #expect(suggestion.target == "TASK-123")
    #expect(suggestion.cwd == nil)
    #expect(suggestion.expiresAt == Date(timeIntervalSince1970: InboundSuggestion.minimumTTL))

    let long = makeSuggestion(receivedAt: Date(timeIntervalSince1970: 0), ttl: 10 * 24 * 60 * 60)
    #expect(long.expiresAt == Date(timeIntervalSince1970: InboundSuggestion.maximumTTL))

    let defaulted = makeSuggestion(receivedAt: Date(timeIntervalSince1970: 0))
    #expect(defaulted.expiresAt == Date(timeIntervalSince1970: InboundSuggestion.defaultTTL))
}

@Test func inboxAcceptsTheFirstSuggestion() {
    var inbox = SuggestionInbox()
    let suggestion = makeSuggestion(key: "TASK-123")

    #expect(inbox.offer(suggestion) == .accepted(suggestion))
    #expect(inbox.pending == suggestion)
}

@Test func inboxRefusesASecondSuggestionWhileOneIsPending() {
    let now = Date()
    var inbox = SuggestionInbox()
    _ = inbox.offer(makeSuggestion(key: "TASK-123", receivedAt: now), now: now)

    let other = makeSuggestion(key: "TASK-456", receivedAt: now)
    #expect(inbox.offer(other, now: now) == .rejected(.slotBusy))
    #expect(inbox.pending?.key == "TASK-123")
}

@Test func inboxRefusesTheSameKeyTwiceWithinItsTTL() throws {
    let now = Date()
    var inbox = SuggestionInbox()
    _ = inbox.offer(makeSuggestion(key: "TASK-123", receivedAt: now, ttl: 600), now: now)
    inbox.resolve(id: try #require(inbox.pending).id)

    // The slot is free, but the nudge was already raised: a cron firing again a
    // minute later must not repeat it.
    let repeated = makeSuggestion(key: "TASK-123", receivedAt: now.addingTimeInterval(60))
    #expect(inbox.offer(repeated, now: now.addingTimeInterval(60)) == .rejected(.duplicate))
    #expect(inbox.pending == nil)
}

@Test func answeringFreesTheSlotForADifferentKey() throws {
    let now = Date()
    var inbox = SuggestionInbox()
    _ = inbox.offer(makeSuggestion(key: "TASK-123", receivedAt: now), now: now)
    let pendingID = try #require(inbox.pending).id
    let answered = inbox.resolve(id: pendingID)
    #expect(answered?.key == "TASK-123")
    #expect(inbox.pending == nil)

    let next = makeSuggestion(key: "TASK-456", receivedAt: now)
    #expect(inbox.offer(next, now: now) == .accepted(next))
}

@Test func resolveIgnoresAStaleIdentifier() {
    var inbox = SuggestionInbox()
    let suggestion = makeSuggestion(key: "TASK-123")
    _ = inbox.offer(suggestion)

    #expect(inbox.resolve(id: UUID()) == nil)
    #expect(inbox.pending == suggestion)
}

@Test func anExpiredSuggestionStopsHoldingTheSlotAndItsKey() {
    let now = Date()
    var inbox = SuggestionInbox()
    _ = inbox.offer(makeSuggestion(key: "TASK-123", receivedAt: now, ttl: 600), now: now)

    let later = now.addingTimeInterval(601)
    let repeated = makeSuggestion(key: "TASK-123", receivedAt: later)
    #expect(inbox.offer(repeated, now: later) == .accepted(repeated))
    #expect(inbox.pending == repeated)
}

@Test func anUnansweredSuggestionIsClearedEvenWhenTheNextOfferIsRefused() throws {
    let now = Date()
    var inbox = SuggestionInbox()
    // A long-lived key, answered, so it is suppressed but not holding the slot.
    let answered = makeSuggestion(key: "TASK-456", receivedAt: now, ttl: 86_400)
    _ = inbox.offer(answered, now: now)
    inbox.resolve(id: answered.id)
    // A short-lived one left unanswered on screen.
    _ = inbox.offer(makeSuggestion(key: "TASK-123", receivedAt: now, ttl: 60), now: now)

    let later = now.addingTimeInterval(61)
    let refused = makeSuggestion(key: "TASK-456", receivedAt: later)
    #expect(inbox.offer(refused, now: later) == .rejected(.duplicate))
    // The expired TASK-123 banner is gone even though nothing replaced it: a
    // reader of `pending` after a refusal still sees the truth.
    #expect(inbox.pending == nil)
}

@Test func suppressedKeysAreBounded() {
    let now = Date()
    var inbox = SuggestionInbox()
    for index in 0..<(SuggestionInbox.maximumSuppressedKeys + 20) {
        let suggestion = makeSuggestion(key: "TASK-\(index)", receivedAt: now, ttl: 600)
        _ = inbox.offer(suggestion, now: now)
        inbox.resolve(id: suggestion.id)
    }
    #expect(inbox.suppressedUntil.count <= SuggestionInbox.maximumSuppressedKeys)
}

@Test func theSuggestionOnScreenKeepsItsSuppressionWhenKeysAreEvicted() {
    let now = Date()
    var inbox = SuggestionInbox()
    // Fill the window with keys that outlive anything arriving later.
    for index in 0..<SuggestionInbox.maximumSuppressedKeys {
        let suggestion = makeSuggestion(key: "old-\(index)", receivedAt: now, ttl: 86_400)
        _ = inbox.offer(suggestion, now: now)
        inbox.resolve(id: suggestion.id)
    }
    // The shortest-lived key of all, so eviction would otherwise drop it first.
    let pending = makeSuggestion(key: "pending", receivedAt: now, ttl: 60)
    #expect(inbox.offer(pending, now: now) == .accepted(pending))

    #expect(inbox.suppressedUntil["pending"] == pending.expiresAt)
    #expect(inbox.suppressedUntil.count <= SuggestionInbox.maximumSuppressedKeys + 1)
}

@Test func rejectionCodesAreTheWireContract() {
    #expect(SuggestionInbox.Rejection.duplicate.rawValue == "duplicate_suggestion")
    #expect(SuggestionInbox.Rejection.slotBusy.rawValue == "suggestion_pending")
}
