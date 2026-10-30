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
        let history: [PuckHistoryItem]
        if attached.hasPagedHistory {
            let page = try client.history(id)
            history = page.order == "desc" ? Array(page.items.reversed()) : page.items
        } else {
            history = []
        }
        let replayed = try client.replay(id, initial: attached.batch)
        let timeline = PuckTimelineProjection.project(history: history, events: replayed)
        for item in timeline.items { show(item) }
        for notice in timeline.notices { show(notice) }
        if let pending = attached.summary.pendingQuestion { show(pending) }
        output.write("Type a prompt, /approve, /deny, /session, /answer, or /detach.", terminator: "\n")
        let reader = Thread {
            var rawEvents = replayed
            var liveTimeline = timeline
            var streamedThisTurn = false
            do {
                var cursor = replayed.last?.cursor ?? attached.batch.cursor
                while let batch = try client.receive(connection, session: id, after: cursor) {
                    for event in batch {
                        cursor = event.cursor
                        if event.kind == "turn_started" { streamedThisTurn = false }
                        if event.kind == "text_delta" {
                            streamedThisTurn = true
                            if let text = event.text { output.write(text, terminator: "") }
                        }
                        let previous = liveTimeline
                        append(event, to: &rawEvents, maximum: 200)
                        liveTimeline = PuckTimelineProjection.project(history: history, events: rawEvents)
                        if event.kind == "assistant_message", streamedThisTurn {
                            output.write("", terminator: "\n")
                            streamedThisTurn = false
                        } else if event.kind != "text_delta" {
                            showChanges(from: previous, to: liveTimeline)
                        }
                        if event.kind == "turn_done" { streamedThisTurn = false }
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

    private func showChanges(from previous: PuckTimeline, to current: PuckTimeline) {
        let prior = Dictionary(uniqueKeysWithValues: previous.items.map { ($0.id, $0) })
        for item in current.items where prior[item.id] != item { show(item) }
        let priorNotices = Dictionary(uniqueKeysWithValues: previous.notices.map { ($0.id, $0) })
        for notice in current.notices where priorNotices[notice.id] != notice { show(notice) }
    }

    private func show(_ item: PuckTimelineItem) {
        let suffix = item.truncated ? "\n[Preview truncated]" : ""
        output.write("[\(item.title)] \(item.text)\(suffix)", terminator: "\n")
    }

    private func show(_ notice: PuckTimelineNotice) {
        let suffix = notice.truncated ? "\n[Preview truncated]" : ""
        output.write("[\(notice.title)] \(notice.text)\(suffix)", terminator: "\n")
    }

    private func append(_ event: PuckSessionEvent, to events: inout [PuckSessionEvent], maximum: Int) {
        events.append(event)
        while events.count > maximum || events.reduce(0, { $0 + $1.retainedByteCount }) > 2 * 1_048_576 {
            guard !events.isEmpty else { break }
            events.removeFirst()
        }
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
