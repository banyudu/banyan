@testable import Banyan
import Testing

@Test func configuredLaunchProfilesRemainDistinctForSidebarPresentation() throws {
    let profiles = try SessionLaunchProfileLoader.parse("""
    session_launches:
      - id: codex
        label: Codex
        provider: codex
        command: codex
      - id: luna
        label: Luna
        provider: codex
        icon: ~/.banyan/icons/luna.svg
        command: codex -p luna-fast
    """)

    let luna = profiles.first { $0.command == "codex -p luna-fast" }

    #expect(luna?.id == "luna")
    #expect(luna?.iconName == "~/.banyan/icons/luna.svg")
    #expect(luna?.provider == .codex)
}
