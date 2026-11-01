struct PuckPromptHistory {
    private var prompts: [String] = []
    private var selectedIndex: Int?
    private var savedDraft = ""

    var isBrowsing: Bool {
        selectedIndex != nil
    }

    mutating func previous(currentDraft: String, prompts availablePrompts: [String]) -> String? {
        if let selectedIndex {
            let next = min(selectedIndex + 1, prompts.count - 1)
            self.selectedIndex = next
            return prompts[next]
        }
        guard let newest = availablePrompts.first else { return nil }
        prompts = availablePrompts
        savedDraft = currentDraft
        selectedIndex = 0
        return newest
    }

    mutating func next() -> String? {
        guard let selectedIndex else { return nil }
        guard selectedIndex > 0 else {
            let draft = savedDraft
            reset()
            return draft
        }
        let next = selectedIndex - 1
        self.selectedIndex = next
        return prompts[next]
    }

    mutating func reset() {
        prompts = []
        selectedIndex = nil
        savedDraft = ""
    }
}
