import Testing
@testable import BanyanCore

@Test func uniqueSessionIDAllocatorSkipsPersistedAndLiveNames() {
    let allocator = UniqueSessionIDAllocator(
        persistence: AllocatorPersistence(ids: ["tui-shell", "tui-shell-2"]),
        tmux: AllocatorTmux(names: ["banyan-tui-shell-3"])
    )

    #expect(allocator.allocate(prefix: "tui-shell") == "tui-shell-4")
}

private struct AllocatorPersistence: SessionPersistenceBackend {
    let ids: [String]

    func load() -> [SessionSnapshot] {
        ids.map { id in
            SessionSnapshot(
                id: id,
                tmuxSessionName: nil,
                title: "Shell",
                reportedTitle: nil,
                cwd: "/tmp",
                command: "",
                status: .running,
                tone: .blue,
                createdAt: .now,
                updatedAt: .now
            )
        }
    }

    func save(_ snapshots: [SessionSnapshot]) {}
}

private struct AllocatorTmux: TmuxSessionLookupBackend {
    let names: Set<String>

    init(names: [String]) {
        self.names = Set(names)
    }

    func hasSession(named name: String) -> Bool {
        names.contains(name)
    }
}
