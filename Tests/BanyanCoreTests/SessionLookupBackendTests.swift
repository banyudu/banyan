import Testing
@testable import BanyanCore

@Test func sessionLookupBackendKeepsSessionActionsDependencyNarrow() {
    let backend: any TmuxSessionLookupBackend = LookupTestBackend()
    #expect(backend.hasSession(named: "banyan-test") == false)
}

private struct LookupTestBackend: TmuxSessionLookupBackend {
    func hasSession(named name: String) -> Bool { false }
}
