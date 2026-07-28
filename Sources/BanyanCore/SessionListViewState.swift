import Foundation

/// Selection and reload state shared by session-list frontends.
public struct SessionListViewState: Sendable {
    public private(set) var showingHistory = false
    public private(set) var historyNeedsReload = true
    public private(set) var selectedIndex = 0
    public private(set) var notice: String?

    public init() {}

    public mutating func toggleHistory() {
        showingHistory.toggle()
        if showingHistory { historyNeedsReload = true }
        selectedIndex = 0
    }

    public mutating func refresh() {
        if showingHistory { historyNeedsReload = true }
    }

    public mutating func markHistoryLoaded() {
        historyNeedsReload = false
    }

    public mutating func moveNext(rowCount: Int) {
        selectedIndex = min(selectedIndex + 1, max(0, rowCount - 1))
    }

    public mutating func movePrevious() {
        selectedIndex = max(0, selectedIndex - 1)
    }

    public mutating func clampSelection(rowCount: Int) {
        selectedIndex = min(selectedIndex, max(0, rowCount - 1))
    }

    public mutating func showNotice(_ notice: String) {
        self.notice = notice
    }
}
