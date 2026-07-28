import BanyanCore
import Foundation
import Testing
@testable import BanyanTUI

@Test func attachmentPassesTmuxInvocationToTheProcessRunner() {
    let runner = RecordingProcessRunner()
    let output = RecordingOutput()
    let attachment = TUIAttachment(
        tmux: AttachmentBackend(),
        processRunner: runner,
        output: output
    )

    attachment.attach(to: "banyan-session")

    #expect(runner.executableURL == URL(fileURLWithPath: "/usr/bin/tmux"))
    #expect(runner.arguments == ["attach-session", "-t", "banyan-session"])
    #expect(output.text == "\u{1b}[2J\u{1b}[H")
}

private final class RecordingOutput: TUIOutput, @unchecked Sendable {
    var text = ""

    func write(_ text: String, terminator: String) {
        self.text += text + terminator
    }
}

private struct AttachmentBackend: TmuxAttachmentBackend {
    var executableURL: URL { URL(fileURLWithPath: "/usr/bin/tmux") }

    func attachArguments(for sessionName: String) -> [String] {
        ["attach-session", "-t", sessionName]
    }
}

private final class RecordingProcessRunner: TUIProcessRunner, @unchecked Sendable {
    var executableURL: URL?
    var arguments: [String]?

    func run(executableURL: URL, arguments: [String]) throws {
        self.executableURL = executableURL
        self.arguments = arguments
    }
}
