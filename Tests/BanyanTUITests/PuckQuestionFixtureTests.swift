import BanyanCore
import Foundation
import Testing
@testable import BanyanTUI

/// Invoked by the cross-process fixture against a real parked daemon turn.
@Test func tuiAnswersParkedPuckQuestion() throws {
    guard let id = ProcessInfo.processInfo.environment["BANYAN_PUCK_E2E_TUI_QUESTION_SESSION"] else { return }
    let input = QuestionInput(["/answer", "1", "/detach"])
    let output = QuestionOutput()
    let tui = PuckTUI(input: input, output: output, currentDirectory: "/tmp")
    try tui.attach(id, client: PuckDaemonClient())
    #expect(output.text.contains("Approve the plan?"))
    #expect(output.text.contains("Approve — Proceed."))
}

private final class QuestionInput: TUIInput {
    private var lines: [String]

    init(_ lines: [String]) { self.lines = lines }
    func readByte() -> UInt8? { nil }
    func readAction() -> SessionListAction? { nil }
    func readLine(prompt: String) -> String? { lines.isEmpty ? nil : lines.removeFirst() }
    func enterRaw() {}
    func restore() {}
}

private final class QuestionOutput: TUIOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func write(_ text: String, terminator: String) {
        lock.lock()
        value += text + terminator
        lock.unlock()
    }
}
