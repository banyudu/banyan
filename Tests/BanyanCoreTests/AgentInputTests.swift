import Foundation
import Testing
@testable import BanyanCore

// MARK: - tmux argument vectors

@Test func literalTextIsNeverInterpretedAsAKeyName() {
    // Verified against tmux 3.6a: `send-keys -l -- Enter` types the five characters,
    // while `send-keys Enter` submits the prompt. A caller asking to type the word
    // must not press the key.
    #expect(AgentInputCommand.sendLiteralArguments(paneID: "%3", text: "Enter") == [
        "send-keys", "-t", "%3", "-l", "--", "Enter"
    ])
    #expect(AgentInputCommand.sendKeysArguments(paneID: "%3", keys: [.enter]) == [
        "send-keys", "-t", "%3", "Enter"
    ])
}

@Test func literalTextStartingWithADashIsNotReadAsAFlag() {
    // Without `--`, tmux 3.6a rejects this outright: "unknown flag -n".
    let arguments = AgentInputCommand.sendLiteralArguments(paneID: "%3", text: "-n --weird; text")

    #expect(arguments == ["send-keys", "-t", "%3", "-l", "--", "-n --weird; text"])
    #expect(arguments.last == "-n --weird; text")
}

@Test func keysAreSentToThePaneRatherThanTheSession() {
    // A session can hold more than one pane and only one of them is the agent's.
    let arguments = AgentInputCommand.sendKeysArguments(paneID: "%7", keys: [.down, .down, .enter])

    #expect(arguments == ["send-keys", "-t", "%7", "Down", "Down", "Enter"])
    #expect(!arguments.contains("banyan-agent"))
}

// MARK: - Key allowlist

@Test func keyNamesResolveOnlyFromTheAllowlist() {
    #expect(TmuxKey(name: "Enter") == .enter)
    #expect(TmuxKey(name: "esc") == .escape)
    #expect(TmuxKey(name: "ctrl-c") == .interrupt)
    #expect(TmuxKey(name: "DOWN") == .down)

    // Anything tmux would happily parse but nobody needs is refused, so an
    // injected "key" can never be a wider instruction than the API documents.
    #expect(TmuxKey(name: "C-u") == nil)
    #expect(TmuxKey(name: "F5") == nil)
    #expect(TmuxKey(name: "") == nil)
    #expect(TmuxKey(name: "-X copy-selection") == nil)
}

// MARK: - Option translation

@Test func answeringNavigatesWithArrowsFromTheHighlightedRow() {
    let prompt = prompt(labels: ["Yes", "Yes, and don't ask again", "No"], selected: 1)

    #expect(AgentPromptAnswer.keystrokes(selecting: 1, in: prompt) == [.enter])
    #expect(AgentPromptAnswer.keystrokes(selecting: 3, in: prompt) == [.down, .down, .enter])
}

@Test func answeringWalksBackwardsWhenTheCursorIsPastTheTarget() {
    // Claude's trust dialog opens with the *last* row highlighted, so assuming the
    // cursor starts at row one would select the wrong answer.
    let prompt = prompt(labels: ["Yes", "Maybe", "No"], selected: 3)

    #expect(AgentPromptAnswer.keystrokes(selecting: 1, in: prompt) == [.up, .up, .enter])
}

@Test func answeringRefusesAnOptionOutsideTheList() {
    let prompt = prompt(labels: ["Yes", "No"], selected: 1)

    #expect(AgentPromptAnswer.keystrokes(selecting: 0, in: prompt) == nil)
    #expect(AgentPromptAnswer.keystrokes(selecting: 3, in: prompt) == nil)
}

@Test func choiceMatchesOnTheLabelRatherThanThePosition() {
    let permission = prompt(labels: ["Yes", "Yes, and don’t ask again for: rm *", "No"], selected: 1)
    let trust = prompt(labels: ["No, exit", "Yes, I trust this folder"], selected: 1)

    #expect(AgentPromptAnswer.option(for: .yes, in: permission)?.index == 1)
    #expect(AgentPromptAnswer.option(for: .always, in: permission)?.index == 2)
    #expect(AgentPromptAnswer.option(for: .no, in: permission)?.index == 3)
    // Same intent, opposite row order — position would have approved the trust
    // dialog when the human said no.
    #expect(AgentPromptAnswer.option(for: .yes, in: trust)?.index == 2)
    #expect(AgentPromptAnswer.option(for: .no, in: trust)?.index == 1)
}

@Test func choiceRefusesWhenNothingOrMoreThanOneRowMatches() {
    let noYes = prompt(labels: ["Continue", "Abort"], selected: 1)
    let twoYeses = prompt(labels: ["Yes, run it", "Yes, run and watch", "No"], selected: 1)

    #expect(AgentPromptAnswer.option(for: .yes, in: noYes) == nil)
    #expect(AgentPromptAnswer.option(for: .always, in: noYes) == nil)
    // Guessing between two plausible rows in a permission dialog is the failure
    // this feature must never have; refusing sends the human back to the options.
    #expect(AgentPromptAnswer.option(for: .yes, in: twoYeses) == nil)
}

@Test func choiceDoesNotMatchAWordThatMerelyStartsTheSameWay() {
    let prompt = prompt(labels: ["Nothing else, continue", "Yes"], selected: 1)

    #expect(AgentPromptAnswer.option(for: .no, in: prompt) == nil)
    #expect(AgentPromptAnswer.option(for: .yes, in: prompt)?.index == 2)
}

private func prompt(labels: [String], selected: Int) -> AgentPrompt {
    AgentPrompt(
        question: "Do you want to proceed?",
        context: [],
        options: labels.enumerated().map { offset, label in
            AgentPromptOption(index: offset + 1, label: label, acceptsNumberKey: true)
        },
        selectedIndex: selected,
        footprint: "test-footprint"
    )
}
