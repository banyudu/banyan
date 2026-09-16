import Foundation
import Testing
@testable import BanyanCore

@Test func ledgerSendsKeystrokesForAMatchingFootprint() {
    var ledger = AgentAnswerLedger()

    let decision = ledger.decide(
        sessionID: "agent",
        request: AgentAnswerRequest(option: 3, footprint: "abc"),
        observedStatus: .asking,
        observedPrompt: prompt(footprint: "abc")
    )

    #expect(decision == .send(
        keys: [.down, .down, .enter],
        option: AgentPromptOption(index: 3, label: "No", acceptsNumberKey: true)
    ))
}

@Test func ledgerRefusesAStaleFootprintAndSendsNothing() {
    // The single most dangerous failure: a slow tap in a chat client answering a
    // *newer* question than the human read.
    var ledger = AgentAnswerLedger()

    let decision = ledger.decide(
        sessionID: "agent",
        request: AgentAnswerRequest(option: 1, footprint: "the-question-they-saw"),
        observedStatus: .asking,
        observedPrompt: prompt(footprint: "the-question-on-screen-now")
    )

    #expect(decision == .reject(.stalePrompt))
    #expect(AgentAnswerRejection.stalePrompt.httpStatus == 409)
    // Nothing was consumed, so answering the prompt actually on screen still works.
    #expect(ledger.consumedFootprint(sessionID: "agent") == nil)
}

@Test func ledgerRefusesARedeliveredAnswerWithoutSendingTwice() {
    // Chat platforms redeliver actions; the second delivery must be a no-op.
    var ledger = AgentAnswerLedger()
    let request = AgentAnswerRequest(option: 1, footprint: "abc")

    let first = ledger.decide(
        sessionID: "agent",
        request: request,
        observedStatus: .asking,
        observedPrompt: prompt(footprint: "abc")
    )
    let second = ledger.decide(
        sessionID: "agent",
        request: request,
        observedStatus: .asking,
        observedPrompt: prompt(footprint: "abc")
    )

    #expect(first == .send(
        keys: [.enter],
        option: AgentPromptOption(index: 1, label: "Yes", acceptsNumberKey: true)
    ))
    #expect(second == .reject(.alreadyConsumed))
}

@Test func ledgerAnswersTheSameQuestionAgainOnceThePaneHasMovedOn() {
    // An agent may genuinely re-ask after a "no". Refusing forever would strand it,
    // so the consumed entry is retired as soon as any reading shows the pane
    // somewhere else.
    var ledger = AgentAnswerLedger()
    let request = AgentAnswerRequest(option: 1, footprint: "abc")
    _ = ledger.decide(
        sessionID: "agent",
        request: request,
        observedStatus: .asking,
        observedPrompt: prompt(footprint: "abc")
    )

    ledger.note(sessionID: "agent", observedFootprint: nil)
    let retry = ledger.decide(
        sessionID: "agent",
        request: request,
        observedStatus: .asking,
        observedPrompt: prompt(footprint: "abc")
    )

    #expect(retry == .send(
        keys: [.enter],
        option: AgentPromptOption(index: 1, label: "Yes", acceptsNumberKey: true)
    ))
}

@Test func ledgerKeepsSessionsIndependent() {
    var ledger = AgentAnswerLedger()
    let request = AgentAnswerRequest(option: 1, footprint: "abc")
    _ = ledger.decide(sessionID: "one", request: request, observedStatus: .asking, observedPrompt: prompt(footprint: "abc"))

    let other = ledger.decide(
        sessionID: "two",
        request: request,
        observedStatus: .asking,
        observedPrompt: prompt(footprint: "abc")
    )

    #expect(other != .reject(.alreadyConsumed))
}

@Test func ledgerRefusesASessionThatIsNotWaitingOnAHuman() {
    var ledger = AgentAnswerLedger()

    for status in [SessionStatus.executing, .idle, .review, .completed, .closed, .subagents] {
        let decision = ledger.decide(
            sessionID: "agent",
            request: AgentAnswerRequest(option: 1, footprint: "abc"),
            observedStatus: status,
            observedPrompt: prompt(footprint: "abc")
        )
        #expect(decision == .reject(.notBlocked), "status \(status.rawValue) must not accept an answer")
    }
}

@Test func ledgerRefusesWhenNoPromptCouldBeRead() {
    // The fail-safe path: unparseable dialogs get no options, and `/answer` is not
    // a way around that — `/input` is the explicit raw route.
    var ledger = AgentAnswerLedger()

    let decision = ledger.decide(
        sessionID: "agent",
        request: AgentAnswerRequest(confirm: true, footprint: "abc"),
        observedStatus: .needInput,
        observedPrompt: nil
    )

    #expect(decision == .reject(.noPrompt))
}

@Test func ledgerRequiresExactlyOneAnswerForm() {
    var ledger = AgentAnswerLedger()
    let live = prompt(footprint: "abc")

    #expect(ledger.decide(
        sessionID: "agent",
        request: AgentAnswerRequest(footprint: "abc"),
        observedStatus: .asking,
        observedPrompt: live
    ) == .reject(.ambiguousRequest))
    #expect(ledger.decide(
        sessionID: "agent",
        request: AgentAnswerRequest(option: 1, choice: .no, footprint: "abc"),
        observedStatus: .asking,
        observedPrompt: live
    ) == .reject(.ambiguousRequest))
}

@Test func ledgerConfirmTakesTheHighlightedRow() {
    var ledger = AgentAnswerLedger()

    let decision = ledger.decide(
        sessionID: "agent",
        request: AgentAnswerRequest(confirm: true, footprint: "abc"),
        observedStatus: .asking,
        observedPrompt: prompt(footprint: "abc", selected: 2)
    )

    #expect(decision == .send(
        keys: [.enter],
        option: AgentPromptOption(index: 2, label: "Yes, and don’t ask again", acceptsNumberKey: true)
    ))
}

@Test func ledgerRefusesAnOptionOutsideThePrompt() {
    var ledger = AgentAnswerLedger()

    let decision = ledger.decide(
        sessionID: "agent",
        request: AgentAnswerRequest(option: 9, footprint: "abc"),
        observedStatus: .asking,
        observedPrompt: prompt(footprint: "abc")
    )

    #expect(decision == .reject(.invalidOption))
    #expect(AgentAnswerRejection.invalidOption.httpStatus == 400)
}

private func prompt(footprint: String, selected: Int = 1) -> AgentPrompt {
    AgentPrompt(
        question: "Do you want to proceed?",
        context: ["rm -rf build"],
        options: [
            AgentPromptOption(index: 1, label: "Yes", acceptsNumberKey: true),
            AgentPromptOption(index: 2, label: "Yes, and don’t ask again", acceptsNumberKey: true),
            AgentPromptOption(index: 3, label: "No", acceptsNumberKey: true)
        ],
        selectedIndex: selected,
        footprint: footprint
    )
}

@Test func awaitingAnAnswerIsNarrowerThanNeedingAttention() {
    // Both predicates exist and neither is redundant. `needsAttention` asks whether
    // a session should compete for the user's eye — a failed one should. This asks
    // whether there is a prompt that will accept a keystroke — a failed one has
    // none, and typing into it would land in a pane that already gave up.
    #expect(SessionLifecyclePolicy.needsAttention(status: .failed, isImportedHistory: false, isSuspended: false))
    #expect(SessionStatus.failed.isAwaitingHumanAnswer == false)

    for status in [SessionStatus.asking, .needInput] {
        #expect(status.isAwaitingHumanAnswer)
        #expect(SessionLifecyclePolicy.needsAttention(status: status, isImportedHistory: false, isSuspended: false))
    }
}
