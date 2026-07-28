import BanyanCore
import Foundation

struct TUIAttachment {
    let tmux: TmuxBackend

    func attach(to sessionName: String) {
        print("\u{1b}[2J\u{1b}[H", terminator: "")
        fflush(stdout)

        let process = Process()
        process.executableURL = tmux.executableURL
        process.arguments = tmux.attachArguments(for: sessionName)
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("Unable to attach to \(sessionName): \(error.localizedDescription)")
        }
    }
}
