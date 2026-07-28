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

    init(
        tmux: any TmuxAttachmentBackend,
        processRunner: any TUIProcessRunner = InteractiveProcessRunner()
    ) {
        self.tmux = tmux
        self.processRunner = processRunner
    }

    func attach(to sessionName: String) {
        print("\u{1b}[2J\u{1b}[H", terminator: "")
        fflush(stdout)

        do {
            try processRunner.run(
                executableURL: tmux.executableURL,
                arguments: tmux.attachArguments(for: sessionName)
            )
        } catch {
            print("Unable to attach to \(sessionName): \(error.localizedDescription)")
        }
    }
}
