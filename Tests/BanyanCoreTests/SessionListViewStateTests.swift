import Testing
@testable import BanyanCore

@Test func sessionListViewStateKeepsHistoryReloadAndSelectionIndependent() {
    var state = SessionListViewState()
    state.moveNext(rowCount: 3)
    state.toggleHistory()

    #expect(state.showingHistory)
    #expect(state.historyNeedsReload)
    #expect(state.selectedIndex == 0)
}
