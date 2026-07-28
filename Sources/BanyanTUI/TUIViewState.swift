struct TUIViewState {
    private(set) var showingHistory = false
    private(set) var historyNeedsReload = true
    private(set) var selectedIndex = 0
    private(set) var notice: String?

    mutating func toggleHistory() {
        showingHistory.toggle()
        if showingHistory { historyNeedsReload = true }
        selectedIndex = 0
    }

    mutating func refresh() {
        if showingHistory { historyNeedsReload = true }
    }

    mutating func markHistoryLoaded() {
        historyNeedsReload = false
    }

    mutating func moveNext(rowCount: Int) {
        selectedIndex = min(selectedIndex + 1, max(0, rowCount - 1))
    }

    mutating func movePrevious() {
        selectedIndex = max(0, selectedIndex - 1)
    }

    mutating func clampSelection(rowCount: Int) {
        selectedIndex = min(selectedIndex, max(0, rowCount - 1))
    }

    mutating func showNotice(_ notice: String) {
        self.notice = notice
    }
}
