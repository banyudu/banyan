import BanyanCore
import Foundation

/// Text mode for the same puckd sessions shown in the app and banyanctl.
/// Leaving this view closes only its socket; the daemon turn continues.
struct PuckTUI {
    let input: any TUIInput
    let output: any TUIOutput
    let currentDirectory: String

    func run(client: PuckDaemonClient = PuckDaemonClient()) {
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
                let provider = input.readLine(prompt: "Provider [codex/opencode-go/anthropic/gemini] (default codex): ") ?? ""
                let selectedProvider = provider.isEmpty ? "codex" : provider
                guard ["codex", "opencode-go", "anthropic", "gemini"].contains(selectedProvider) else {
                    output.write("Unsupported puck provider", terminator: "\n")
                    return
                }
                let billedAPI = ["anthropic", "gemini"].contains(selectedProvider)
                let account = input.readLine(prompt: billedAPI
                    ? "Separately billed API-key account label: "
                    : "Account label (blank for pool): ") ?? ""
                let model = input.readLine(prompt: billedAPI
                    ? "API model ID: "
                    : "Model (blank for default): ") ?? ""
                if billedAPI && (account.isEmpty || model.isEmpty) {
                    output.write("\(selectedProvider) requires an explicit model and separately billed API-key account", terminator: "\n")
                    return
                }
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

    func attach(_ id: String, client: PuckDaemonClient) throws {
        let (connection, attached) = try client.attach(id)
        output.write("\u{1b}[2J\u{1b}[H", terminator: "")
        output.write("\(id) · \(attached.summary.provider)/\(attached.summary.model) · \(attached.summary.position)", terminator: "\n")
        let replayed = try client.replay(id, initial: attached.batch)
        for event in replayed { show(event) }
        if let pending = attached.summary.pendingQuestion { show(pending) }
        output.write("Type a prompt, /approve, /deny, /session, /answer, or /detach.", terminator: "\n")
        let reader = Thread {
            do {
                var cursor = replayed.last?.cursor ?? attached.batch.cursor
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
                } else if command == "/answer" {
                    guard let pending = try client.get(id).pendingQuestion else {
                        output.write("No question is pending", terminator: "\n")
                        continue
                    }
                    show(pending)
                    guard let selections = collectAnswers(pending) else { continue }
                    try client.answer(id, callID: pending.callID, selections: selections)
                } else if !command.isEmpty {
                    if try !PuckAppAdmission.turn(id, prompt: command) {
                        try client.turn(id, prompt: command)
                    }
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

    private func show(_ pending: PuckPendingQuestion) {
        output.write("Question \(pending.callID) needs an answer:", terminator: "\n")
        for question in pending.questions {
            output.write("\(question.header): \(question.question)", terminator: "\n")
            for (index, option) in question.options.enumerated() {
                output.write("  \(index + 1). \(option.label) — \(option.description)", terminator: "\n")
            }
            if question.multiple { output.write("  Use comma-separated numbers for multiple choices.", terminator: "\n") }
            if question.custom { output.write("  Or enter text:your answer", terminator: "\n") }
        }
    }

    private func collectAnswers(_ pending: PuckPendingQuestion) -> [PuckQuestionSelection]? {
        var selections: [PuckQuestionSelection] = []
        for question in pending.questions {
            while true {
                guard let line = input.readLine(prompt: "\(question.header)> ") else { return nil }
                if let selection = PuckQuestionSelection.parse(line, for: question) {
                    selections.append(selection)
                    break
                }
                output.write("Enter an offered number, comma-separated numbers, or text:your answer.", terminator: "\n")
            }
        }
        return selections
    }
}
