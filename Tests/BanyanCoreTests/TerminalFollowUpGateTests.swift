import Testing
@testable import BanyanCore

@Test func remoteFollowupRequiresAnEmptyRecognizableComposer() {
    let ready = "Finished.\n› Ask Codex to do anything\nGPT-6.1-Sol xhigh · Context 40%\n? for shortcuts"
    func permits(_ text: String, status: SessionStatus = .needInput, mode: Bool = false) -> Bool {
        TerminalFollowUpGate.permits(provider: .codex, status: status, paneInMode: mode,
            isSuspended: false, isFrozen: false, isDeepSuspended: false, visibleText: text)
    }
    #expect(permits(ready))
    #expect(!permits(ready, status: .executing))
    #expect(!permits(ready, mode: true))
    #expect(!permits(ready.replacingOccurrences(of: "Ask Codex to do anything", with: "unfinished local draft")))
    #expect(!permits("Working • esc to interrupt\n" + ready))
    #expect(!permits("Select model\n› 1. Model A\n  2. Model B\n" + ready))
    #expect(!permits("Do you want to proceed?\n› 1. Yes\n  2. No\n" + ready))
    #expect(!permits("› Ask Codex to do anything\nmodel picker is open"))
    #expect(!permits("› Ask Codex to do anything\nunsent context for the next turn"))
    #expect(!permits("› Ask Codex to do anything\nmalformed footer for shortcuts and a draft"))
    #expect(!permits("›\nGPT-6 xhigh · ~/dev/my-project · Context 48% used · weekly 99% left\n? for shortcuts"))
    #expect(permits("› Ask Codex to do anything\nGPT-6 xhigh · ~/dev/my-project · Context 48% used · weekly 99% left\n? for shortcuts"))
    #expect(!TerminalFollowUpGate.permits(provider: .claude, status: .idle, paneInMode: false,
        isSuspended: false, isFrozen: false, isDeepSuspended: false, visibleText: ready))
}

@Test func remoteFollowupRejectsControlCharactersAndMultilineInput() {
    #expect(TerminalFollowUpGate.acceptsText("Please continue"))
    #expect(!TerminalFollowUpGate.acceptsText(" "))
    #expect(!TerminalFollowUpGate.acceptsText("one\ntwo"))
    #expect(!TerminalFollowUpGate.acceptsText("escape\u{001b}[A"))
    #expect(!TerminalFollowUpGate.acceptsText(String(repeating: "x", count: 16_385)))
}
