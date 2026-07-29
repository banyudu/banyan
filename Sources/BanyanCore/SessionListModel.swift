import Foundation

/// Session rows, history rows, and selection behavior shared by list frontends.
public struct SessionListModel: Sendable {
    private let dataSource: any SessionListDataSource
    private var viewState = SessionListViewState()
    private var historyFilter = ""

    public private(set) var sessions: [SessionSnapshot] = []
    public private(set) var history: [ImportedAgentSession] = []

    public init(dataSource: any SessionListDataSource) {
        self.dataSource = dataSource
    }

    public var showingHistory: Bool { viewState.showingHistory }
    public var historyNeedsReload: Bool { viewState.historyNeedsReload }
    public var selectedIndex: Int { viewState.selectedIndex }
    public var notice: String? { viewState.notice }
    public var currentHistoryFilter: String { historyFilter }
    public var visibleRowCount: Int { showingHistory ? history.count : sessions.count }

    public var selectedSession: SessionSnapshot? {
        sessions.indices.contains(selectedIndex) ? sessions[selectedIndex] : nil
    }

    public var selectedHistory: ImportedAgentSession? {
        history.indices.contains(selectedIndex) ? history[selectedIndex] : nil
    }

    public mutating func reload() {
        if showingHistory {
            if viewState.historyNeedsReload {
                let limit = historyFilter.isEmpty
                    ? SessionHistoryPresentation.sidebarBrowseLimit
                    : SessionHistoryPresentation.sidebarSearchLimit
                history = dataSource.loadHistory(limit: limit).filter { item in
                    let searchText = "\(item.provider.displayName) \(item.title) \(item.cwd)"
                    return SessionHistoryPresentation.matchesFilter(
                        title: searchText,
                        query: historyFilter
                    )
                }
                viewState.markHistoryLoaded()
            }
            viewState.clampSelection(rowCount: history.count)
            return
        }
        sessions = dataSource.loadActiveSessions()
        viewState.clampSelection(rowCount: sessions.count)
    }

    public mutating func toggleHistory() {
        viewState.toggleHistory()
    }

    public mutating func setHistoryFilter(_ query: String) {
        historyFilter = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if showingHistory { viewState.refresh() }
    }

    public mutating func refresh() {
        viewState.refresh()
    }

    public mutating func moveNext() {
        viewState.moveNext(rowCount: visibleRowCount)
    }

    public mutating func movePageNext() {
        viewState.moveNext(rowCount: visibleRowCount, by: 10)
    }

    public mutating func movePagePrevious() {
        for _ in 0..<10 { viewState.movePrevious() }
    }

    public mutating func movePrevious() {
        viewState.movePrevious()
    }

    public mutating func showNotice(_ notice: String) {
        viewState.showNotice(notice)
    }
}
