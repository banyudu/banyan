import Testing
@testable import BanyanCore

@Test func branchRefreshSlowsWhenTheWindowIsNotFrontmost() {
    #expect(SessionBackgroundRefreshPolicy.branchRefreshInterval(activityLevel: .active) == 15)
    #expect(
        SessionBackgroundRefreshPolicy.branchRefreshInterval(activityLevel: .backgroundVisible) == 60
    )
}

/// The branch chip is chrome: it raises no notification and persists no decision,
/// so once no window is on screen the git sweep stops rather than slowing down.
@Test func branchRefreshStopsWhenNothingIsOnScreen() {
    #expect(SessionBackgroundRefreshPolicy.branchRefreshInterval(activityLevel: .hidden) == nil)
}

@Test func onScreenChromeRefreshesOnlyWhileSomethingIsVisible() {
    #expect(SessionBackgroundRefreshPolicy.refreshesOnScreenChrome(activityLevel: .active))
    #expect(SessionBackgroundRefreshPolicy.refreshesOnScreenChrome(activityLevel: .backgroundVisible))
    #expect(!SessionBackgroundRefreshPolicy.refreshesOnScreenChrome(activityLevel: .hidden))
}
