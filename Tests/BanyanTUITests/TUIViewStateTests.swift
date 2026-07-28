import XCTest
@testable import BanyanTUI

final class TUIViewStateTests: XCTestCase {
    func testHistoryStartsPendingAndToggleResetsSelection() {
        var state = TUIViewState()
        state.moveNext(rowCount: 4)

        state.toggleHistory()

        XCTAssertTrue(state.showingHistory)
        XCTAssertTrue(state.historyNeedsReload)
        XCTAssertEqual(state.selectedIndex, 0)
    }

    func testHistoryRefreshOnlyMarksHistoryForReload() {
        var state = TUIViewState()
        state.toggleHistory()
        state.markHistoryLoaded()

        state.refresh()

        XCTAssertTrue(state.historyNeedsReload)
        XCTAssertTrue(state.showingHistory)
    }

    func testSelectionMovementAndClampingStayWithinRows() {
        var state = TUIViewState()

        state.moveNext(rowCount: 3)
        state.moveNext(rowCount: 3)
        state.moveNext(rowCount: 3)
        XCTAssertEqual(state.selectedIndex, 2)

        state.movePrevious()
        XCTAssertEqual(state.selectedIndex, 1)

        state.clampSelection(rowCount: 1)
        XCTAssertEqual(state.selectedIndex, 0)
    }

    func testNoticeIsReplacedByLatestMessage() {
        var state = TUIViewState()

        state.showNotice("created")
        state.showNotice("closed")

        XCTAssertEqual(state.notice, "closed")
    }
}
