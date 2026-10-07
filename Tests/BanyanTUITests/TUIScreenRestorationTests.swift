import BanyanCore
import Foundation
import Testing
@testable import BanyanTUI

@Test func fallbackThenEmbeddedThenQuitPreservesHostScreenAndScrollback() throws {
    let output = EmulatedHostOutput()
    output.write("older shell output\r\nHOST_SCREEN_SENTINEL", terminator: "")
    let before = output.host.terminal.getBufferAsData()
    let cursorBefore = output.host.terminal.getCursorLocation()
    let input = RestorationInput(output: output)
    let backend = TmuxBackend(executableURL: URL(fileURLWithPath: "/missing-tmux-fixture"),
                              workingDirectory: "/tmp", environment: [:], socketName: "unused-fixture")
    var app = BanyanTUI(backend: backend, dataSource: RestorationDataSource(),
                       actions: RestorationActions(), input: input, output: output,
                       processRunner: SimulatedFullscreenTmux(output: output),
                       currentDirectory: "/tmp", events: try TUIEvents(), environment: [:])
    app.run()
    #expect(input.checkedFallbackReturn)
    #expect(input.checkedEmbeddedReturn)
    #expect(!output.host.terminal.isCurrentBufferAlternate)
    #expect(output.host.terminal.getBufferAsData() == before)
    let cursorAfter = output.host.terminal.getCursorLocation()
    #expect(cursorAfter.x == cursorBefore.x)
    #expect(cursorAfter.y == cursorBefore.y)
}

@Test func sidebarEscapeDeadlineLeavesFollowingNavigationAvailable() {
    var router = SidebarInputRouter()
    #expect(router.consume(27) == nil)
    #expect(router.hasPendingEscape)
    router.flushEscape()
    #expect(router.consume(106) == .action(.next))
    #expect(router.consume(27) == nil)
    router.flushEscape()
    #expect(router.consume(107) == .action(.previous))
    #expect(router.consume(27) == nil)
    router.flushEscape()
    #expect(router.consume(113) == .action(.quit))
    #expect(router.consume(27) == nil)
    #expect(router.consume(91) == nil)
    #expect(router.consume(66) == .action(.next))
}

@Test func sidebarPasteCannotCloseOrRemoveSessions() {
    var router = SidebarInputRouter()
    let events = Array("\u{1b}[200~cxqf\u{1b}[201~j".utf8).compactMap { router.consume($0) }
    #expect(events == [.action(.next)])
}

private final class EmulatedHostOutput: TUIOutput {
    let host = TerminalGridModel(columns: 80, rows: 24)
    func write(_ text: String, terminator: String) { host.feed(Array((text + terminator).utf8)) }
}

private struct SimulatedFullscreenTmux: TUIProcessRunner {
    let output: EmulatedHostOutput
    func run(executableURL: URL, arguments: [String]) throws {
        // Like a real tmux client, this leaves the outer alternate-screen mode.
        output.write("\u{1b}[?1049h\u{1b}[2J\u{1b}[HFULLSCREEN\u{1b}[?1049l", terminator: "")
    }
}

private final class RestorationInput: TUIInput {
    let output: EmulatedHostOutput
    private var step = 0
    var checkedFallbackReturn = false, checkedEmbeddedReturn = false
    init(output: EmulatedHostOutput) { self.output = output }
    func readEvent(events: TUIEvents) -> TUIEvent? {
        defer { step += 1 }
        switch step {
        case 0: return .input([102]) // full-screen fallback
        case 1:
            #expect(output.host.terminal.isCurrentBufferAlternate)
            #expect(output.host.snapshot().lines[0].contains("Banyan TUI"))
            checkedFallbackReturn = true
            return .input([13]) // embedded focus
        case 2:
            #expect(output.host.terminal.isCurrentBufferAlternate)
            #expect(output.host.snapshot().lines[0].contains("terminal"))
            checkedEmbeddedReturn = true
            return .input([29, 93, 113]) // sidebar, quit in same read
        default: return nil
        }
    }
    func readByte() -> UInt8? { nil }
    func readAction() -> SessionListAction? { nil }
    func readLine(prompt: String) -> String? { nil }
    func enterRaw() {}
    func restore() {}
}

private struct RestorationDataSource: SessionListDataSource {
    func loadActiveSessions() -> [SessionSnapshot] {
        [SessionSnapshot(id: "fixture", tmuxSessionName: "fixture", title: "Shell", reportedTitle: nil,
                         cwd: "/tmp", command: "", status: .running, tone: .blue,
                         createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))]
    }
    func loadHistory(limit: Int) -> [ImportedAgentSession] { [] }
}

private struct RestorationActions: SessionListActions {
    func createShellSession(cwd: String) throws -> String { "fixture" }
    func createSession(title: String?, cwd: String, command: String) throws -> String { "fixture" }
    func resumeHistory(_ item: ImportedAgentSession, trimmed: Bool) throws -> Bool { false }
    func recover(_ session: SessionSnapshot) throws {}
    func rename(_ session: SessionSnapshot, title: String) {}
    func close(_ session: SessionSnapshot) {}
    func remove(_ session: SessionSnapshot) {}
}
