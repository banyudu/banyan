import Foundation

/// Session rows, history rows, and selection behavior shared by list frontends.
public struct SessionListModel: Sendable {
    private let dataSource: any SessionListDataSource
    private let puckClient: PuckDaemonClient?
    private var viewState = SessionListViewState()
    private var historyFilter = ""
    private var puckNeedsReload = true

    public private(set) var sessions: [SessionSnapshot] = []
    public private(set) var puckSessions: [PuckSessionSummary] = []
    public private(set) var history: [ImportedAgentSession] = []

    public init(dataSource: any SessionListDataSource, puckClient: PuckDaemonClient? = nil) {
        self.dataSource = dataSource
        self.puckClient = puckClient
    }

    public var showingHistory: Bool { viewState.showingHistory }
    public var historyNeedsReload: Bool { viewState.historyNeedsReload }
    public var selectedIndex: Int { viewState.selectedIndex }
    public var notice: String? { viewState.notice }
    public var currentHistoryFilter: String { historyFilter }
    public var visibleRowCount: Int { showingHistory ? history.count : sessions.count + puckSessions.count }

    public var selectedSession: SessionSnapshot? {
        sessions.indices.contains(selectedIndex) ? sessions[selectedIndex] : nil
    }

    public var selectedPuckSession: PuckSessionSummary? {
        let index = selectedIndex - sessions.count
        return puckSessions.indices.contains(index) ? puckSessions[index] : nil
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
        if puckNeedsReload {
            puckSessions = (try? puckClient?.list()) ?? []
            puckNeedsReload = false
        }
        viewState.clampSelection(rowCount: visibleRowCount)
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
        puckNeedsReload = true
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
