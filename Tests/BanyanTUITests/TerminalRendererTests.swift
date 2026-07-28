import BanyanCore
import Foundation
import Testing
@testable import BanyanTUI

@Test func rendererShowsEmptyStateAndHistoryInstructions() {
    let output = TerminalRenderer.render(
        sessions: [],
        history: [],
        showingHistory: true,
        selectedIndex: 0,
        notice: "ready",
        tmux: RendererTestBackend()
    )

    #expect(output.contains("ready"))
    #expect(output.contains("History"))
    #expect(output.contains("(no history)"))
    #expect(output.contains("enter resume/T trim"))
}

@Test func rendererUsesSelectedPaneTextForActiveSession() {
    let now = Date(timeIntervalSince1970: 100)
    let session = SessionSnapshot(
        id: "one",
        tmuxSessionName: "banyan-one",
        title: "Shell",
        reportedTitle: nil,
        cwd: "/tmp",
        command: "",
        status: .running,
        tone: .blue,
        createdAt: now,
        updatedAt: now
    )
    let output = TerminalRenderer.render(
        sessions: [session],
        history: [],
        showingHistory: false,
        selectedIndex: 0,
        notice: nil,
        tmux: RendererTestBackend(visibleText: "prompt> ")
    )

    #expect(output.contains("Shell"))
    #expect(output.contains("prompt> "))
}

private struct RendererTestBackend: TmuxDisplayBackend {
    let visibleText: String

    init(visibleText: String = "") {
        self.visibleText = visibleText
    }

    func hasSession(named name: String) -> Bool { true }
    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? {
        TmuxPaneSnapshot(
            paneID: "%0",
            rootPID: 1,
            currentCommand: "bash",
            currentPath: "/tmp",
            isDead: false,
            isInMode: false
        )
    }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String { visibleText }
    func captureCurrentVisibleText(paneID: String) -> String { visibleText }
}
