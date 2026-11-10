@testable import Banyan
import BanyanCore
import Foundation
import Testing

@MainActor
@Suite(.serialized) struct CommandPaletteLinearSessionTests {
    @Test func existingSessionRowsPromiseTheActionTheirStateAllows() {
        let matches = [
            LinearIssueSessionMatch(id: "live", title: "Live work", state: .live, updatedAt: Date()),
            LinearIssueSessionMatch(id: "closed", title: "Closed work", state: .closed, updatedAt: Date()),
            LinearIssueSessionMatch(
                id: "imported",
                title: "Imported work",
                state: .importedHistory,
                updatedAt: Date()
            )
        ]
        var opened: [String] = []
        let items = LinearIssueSessionPaletteItems.items(
            issueID: "ENG-123",
            matches: matches,
            onOpen: { opened.append($0.id) }
        )

        #expect(items.map(\.id) == [
            "linear.existing-session.live",
            "linear.existing-session.closed",
            "linear.existing-session.imported"
        ])
        #expect(items.map(\.title) == [
            "Switch to Session for ENG-123",
            "Reopen Session for ENG-123",
            "Resume Session for ENG-123"
        ])
        #expect(items.map(\.detail) == ["Live work", "Closed work", "Imported work"])
        #expect(items.allSatisfy { $0.category == "Linear · Existing Session" })
        #expect(items.allSatisfy { $0.priority == 1 })

        items[1].action()
        #expect(opened == ["closed"])
    }

    @Test func existingSessionRowsRankAboveQuickActionsForAnIssueID() {
        let items = [
            CommandPaletteItem(
                id: "open",
                category: "Linear · Quick Open",
                title: "Open Linear Issue ENG-123",
                detail: "Open in Linear",
                shortcut: "↩",
                action: {}
            ),
            CommandPaletteItem(
                id: "start",
                category: "Linear · Quick Open",
                title: "Start Session for ENG-123",
                detail: "Create the issue worktree",
                shortcut: nil,
                action: {}
            ),
            CommandPaletteItem(
                id: "discuss",
                category: "Linear · Discuss",
                title: "Discuss ENG-123",
                detail: "Chat about issue clarity, scope, and feasibility",
                shortcut: "↩",
                action: {}
            ),
            CommandPaletteItem(
                id: "resume.live",
                category: "Linear · Existing Session",
                title: "Switch to Session for ENG-123",
                detail: "Live work",
                shortcut: "↩",
                priority: 1,
                action: {}
            ),
            CommandPaletteItem(
                id: "resume.closed",
                category: "Linear · Existing Session",
                title: "Reopen Session for ENG-123",
                detail: "Closed work",
                shortcut: "↩",
                priority: 1,
                action: {}
            )
        ]

        let ordered = CommandPaletteView.orderedItems(query: "ENG-123", items: items)
        // Promoted rows keep the order their provider ranked them in, even
        // though the quick actions score higher on title position.
        #expect(ordered.prefix(2).map(\.id) == ["resume.live", "resume.closed"])
        #expect(ordered.dropFirst(2).first?.id == "discuss")

        let narrowed = CommandPaletteView.orderedItems(query: "reopen ENG-123", items: items)
        #expect(narrowed.map(\.id) == ["resume.closed"])
    }

    @Test func matchesRankLiveThenClosedThenImportedAndSkipTheSelectedSession() throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
        defer { store.flushPendingSessionSaves() }

        let live = store.spawn(
            id: "live", title: "ENG-123 live", cwd: fixture.project.path, command: "", select: false
        )
        let closed = store.spawn(
            id: "closed", title: "ENG-123 closed", cwd: fixture.home.path, command: "", select: false
        )
        closed.status = .closed
        let imported = TerminalSession(
            id: "imported",
            title: "ENG-123 imported",
            cwd: fixture.root.path,
            command: "",
            historyTranscriptURL: fixture.root.appendingPathComponent("history.jsonl"),
            theme: store.terminalTheme,
            tmuxBackend: AdmissionTerminalBackend(),
            telemetry: banyanTestTelemetry,
            host: store.host
        )
        store.sessions.append(imported)
        _ = store.spawn(
            id: "other", title: "ENG-456 unrelated", cwd: fixture.project.path, command: "", select: false
        )

        let matches = store.paletteLinearIssueSessions(tracking: "ENG-123")
        #expect(matches.map(\.id) == ["live", "closed", "imported"])
        #expect(matches.map(\.state) == [.live, .closed, .importedHistory])
        #expect(matches.map(\.title) == ["ENG-123 live", "ENG-123 closed", "ENG-123 imported"])

        store.selectedSessionID = live.id
        #expect(store.paletteLinearIssueSessions(tracking: "ENG-123").map(\.id) == ["closed", "imported"])
        #expect(store.paletteLinearIssueSessions(tracking: "ENG-999").isEmpty)
    }
}
