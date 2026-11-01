import Testing
@testable import Banyan

@Test func puckPromptHistoryWalksNewestToOldestAndBack() {
    var history = PuckPromptHistory()

    #expect(history.previous(currentDraft: "unfinished", prompts: ["latest", "older"]) == "latest")
    #expect(history.previous(currentDraft: "ignored", prompts: []) == "older")
    #expect(history.previous(currentDraft: "ignored", prompts: []) == "older")
    #expect(history.next() == "latest")
    #expect(history.next() == "unfinished")
    #expect(history.next() == nil)
    #expect(!history.isBrowsing)
}

@Test func puckPromptHistoryIgnoresAnEmptyHistory() {
    var history = PuckPromptHistory()

    #expect(history.previous(currentDraft: "", prompts: []) == nil)
    #expect(history.next() == nil)
    #expect(!history.isBrowsing)
}

@Test func puckPromptHistoryResetStartsFromTheNewestPromptAgain() {
    var history = PuckPromptHistory()
    _ = history.previous(currentDraft: "", prompts: ["second", "first"])
    _ = history.previous(currentDraft: "", prompts: [])

    history.reset()

    #expect(!history.isBrowsing)
    #expect(history.previous(currentDraft: "", prompts: ["third", "second", "first"]) == "third")
}
