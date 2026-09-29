import BanyanCore
import Foundation

/// Text mode for the same puckd sessions shown in the app and banyanctl.
/// Leaving this view closes only its socket; the daemon turn continues.
struct PuckTUI {
    let input: any TUIInput
    let output: any TUIOutput
    let currentDirectory: String

    func run() {
        let client = PuckDaemonClient()
        do {
            let sessions = try client.list()
            output.write("\u{1b}[2J\u{1b}[H", terminator: "")
            output.write("Puck sessions (one daemon):", terminator: "\n")
            for session in sessions {
                output.write("  \(session.id)  \(session.position)  \(session.provider)/\(session.model)", terminator: "\n")
            }
            let choice = input.readLine(prompt: "Session ID (or 'new', blank returns): ")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !choice.isEmpty else { return }
            let id: String
            if choice == "new" {
                let provider = input.readLine(prompt: "Provider [codex/opencode-go] (default codex): ") ?? ""
                let selectedProvider = provider.isEmpty ? "codex" : provider
                guard ["codex", "opencode-go"].contains(selectedProvider) else {
                    output.write("Unsupported puck provider", terminator: "\n")
                    return
                }
                let account = input.readLine(prompt: "Account label (blank for pool): ") ?? ""
                let model = input.readLine(prompt: "Model (blank for default): ") ?? ""
                let cwd = input.readLine(prompt: "Workspace (blank for current): ") ?? ""
                let summary = try client.create(
                    id: UUID().uuidString.lowercased(), provider: selectedProvider,
                    account: account.isEmpty ? nil : account,
                    model: model.isEmpty ? nil : model,
                    workspace: NSString(string: cwd.isEmpty ? currentDirectory : cwd).expandingTildeInPath
                )
                id = summary.id
            } else {
                id = choice
            }
            try attach(id, client: client)
        } catch {
            output.write("Puck: \(error.localizedDescription)", terminator: "\n")
            _ = input.readLine(prompt: "Press Return to continue: ")
        }
    }

    private func attach(_ id: String, client: PuckDaemonClient) throws {
        let (connection, attached) = try client.attach(id)
        output.write("\u{1b}[2J\u{1b}[H", terminator: "")
        output.write("\(id) · \(attached.summary.provider)/\(attached.summary.model) · \(attached.summary.position)", terminator: "\n")
        for event in try client.replay(id, initial: attached.batch) { show(event) }
        output.write("Type a prompt, /approve, /deny, /session, or /detach.", terminator: "\n")
        let reader = Thread {
            do {
                var cursor = attached.batch.cursor
                while let events = try client.receive(connection, session: id, after: cursor) {
                    for event in events {
                        cursor = event.cursor
                        show(event)
                    }
                }
            } catch {
                output.write("Puck stream: \(error.localizedDescription)", terminator: "\n")
            }
        }
        reader.start()
        defer { connection.disconnect() }
        while let line = input.readLine(prompt: "puck> ") {
            let command = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if command == "/detach" { break }
            do {
                if ["/approve", "/deny", "/session"].contains(command) {
                    guard let pending = try client.get(id).pendingApproval else {
                        output.write("No approval is pending", terminator: "\n")
                        continue
                    }
                    try client.decide(id, callID: pending.callID, decision: String(command.dropFirst()))
                } else if !command.isEmpty {
                    try client.turn(id, prompt: command)
                }
            } catch {
                output.write("Puck: \(error.localizedDescription)", terminator: "\n")
            }
        }
    }

    private func show(_ event: PuckSessionEvent) {
        guard let text = event.displayText else { return }
        output.write("[\(event.cursor)] \(text)", terminator: "\n")
    }
}
