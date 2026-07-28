import Foundation

/// Session rows, history rows, and selection behavior shared by list frontends.
public struct SessionListModel: Sendable {
    private let dataSource: SessionDataSource
    private var viewState = SessionListViewState()

    public private(set) var sessions: [SessionSnapshot] = []
    public private(set) var history: [ImportedAgentSession] = []

    public init(dataSource: SessionDataSource) {
        self.dataSource = dataSource
    }

    public var showingHistory: Bool { viewState.showingHistory }
    public var historyNeedsReload: Bool { viewState.historyNeedsReload }
    public var selectedIndex: Int { viewState.selectedIndex }
    public var notice: String? { viewState.notice }
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
                history = dataSource.loadHistory()
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

    public mutating func refresh() {
        viewState.refresh()
    }

    public mutating func moveNext() {
        viewState.moveNext(rowCount: visibleRowCount)
    }

    public mutating func movePrevious() {
        viewState.movePrevious()
    }

    public mutating func showNotice(_ notice: String) {
        viewState.showNotice(notice)
    }
}
