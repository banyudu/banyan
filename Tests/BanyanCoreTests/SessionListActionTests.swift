import Testing
@testable import BanyanCore

@Test func sessionListActionExposesFrontendIndependentCommands() {
    let actions: [SessionListAction] = [.toggleHistory, .next, .activate, .trimResume]
    #expect(actions.count == 4)
}
