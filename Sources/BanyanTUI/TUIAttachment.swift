import BanyanCore
import Foundation

protocol TUIProcessRunner {
    func run(executableURL: URL, arguments: [String]) throws
}

struct InteractiveProcessRunner: TUIProcessRunner {
    func run(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
    }
}

struct TUIAttachment {
    let tmux: any TmuxAttachmentBackend
    let processRunner: any TUIProcessRunner
    let output: any TUIOutput

    init(
        tmux: any TmuxAttachmentBackend,
        processRunner: any TUIProcessRunner = InteractiveProcessRunner(),
        output: any TUIOutput = StandardTUIOutput()
    ) {
        self.tmux = tmux
        self.processRunner = processRunner
        self.output = output
    }

    func attach(to sessionName: String) {
        output.write("\u{1b}[2J\u{1b}[H", terminator: "")

        do {
            try processRunner.run(
                executableURL: tmux.executableURL,
                arguments: tmux.attachArguments(for: sessionName)
            )
        } catch {
            output.write("Unable to attach to \(sessionName): \(error.localizedDescription)", terminator: "\n")
        }
    }
}
