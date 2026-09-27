import BanyanCore
import Testing
@testable import Banyan

/// A store built on the shared test backend runs the app's launch reap. That
/// reap kills every session on its socket that the store's rows do not name, so
/// the two must never share a socket: on `banyan` it reached every live session
/// and killed them all.
@Test func testBackendNeverSharesTheAppsTmuxSocket() {
    #expect(banyanTestTmuxBackend.socketName != TmuxBackend.socketName)
    #expect(banyanTestTmuxBackend.socketName == "banyan-test")
}
