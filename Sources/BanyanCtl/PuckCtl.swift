import BanyanCore
import Foundation

/// Direct daemon control also works when the Banyan app is stopped. This is the
/// same session and event stream shown by the macOS app and the TUI.
func runPuckCtl(_ args: [String], host: HostRuntimeContext) throws {
    let client = PuckDaemonClient(environment: host.environment, homeDirectory: host.homeDirectory.path)
    let command = args.first ?? "list"
    let options = try PuckOptions(Array(args.dropFirst()))
    switch command {
    case "list":
        for session in try client.list() {
            print("\(session.id)\t\(session.position)\t\(session.provider)/\(session.model)\t\(session.cwd)")
        }
    case "new":
        let id = options["id"] ?? UUID().uuidString.lowercased()
        let workspace = NSString(string: options["cwd"] ?? host.currentDirectory).expandingTildeInPath
        let provider = options["provider"] ?? "codex"
        guard ["codex", "opencode-go", "anthropic", "gemini"].contains(provider) else {
            throw PuckDaemonError.rejected("puckd supports codex, opencode-go, anthropic, and gemini providers")
        }
        if ["anthropic", "gemini"].contains(provider),
           options["model"]?.isEmpty != false || options["account"]?.isEmpty != false {
            throw PuckDaemonError.rejected("\(provider) requires --model and --account (a separately billed API key)")
        }
        let session = try client.create(id: id, provider: provider,
                                        account: options["account"], model: options["model"],
                                        workspace: workspace)
        print("\(session.id)\t\(session.provider)/\(session.model)\t\(session.cwd)")
        if let prompt = options["prompt"] { try client.turn(id, prompt: prompt) }
    case "show":
        let id = try options.required("id")
        let session = try client.get(id)
        print("\(session.id)\t\(session.position)\t\(session.provider)/\(session.model)\t\(session.cwd)")
        if let pending = session.pendingApproval {
            print("approval \(pending.callID): \(pending.tool) \(pending.arguments)")
        }
        if let pending = session.pendingQuestion { printPendingQuestion(pending) }
        let firstPage = try client.events(id)
        for event in try client.replay(id, initial: firstPage) { printPuckEvent(event) }
    case "turn":
        try client.turn(options.required("id"), prompt: options.required("prompt"))
    case "decide":
        let decision = try options.required("decision")
        guard ["approve", "deny", "session"].contains(decision) else {
            throw PuckDaemonError.rejected("decision must be approve, deny, or session")
        }
        try client.decide(options.required("id"), callID: options.required("call-id"), decision: decision)
    case "answer":
        try client.answer(options.required("id"), callID: options.required("call-id"),
                          selections: PuckQuestionSelection.decodeJSON(options.required("selections")))
    case "attach":
        let id = try options.required("id")
        let (connection, attached) = try client.attach(id)
        print("\(attached.summary.id) · \(attached.summary.provider)/\(attached.summary.model) · \(attached.summary.position)")
        let replayed = try client.replay(id, initial: attached.batch)
        for event in replayed { printPuckEvent(event) }
        if let pending = attached.summary.pendingQuestion { printPendingQuestion(pending) }
        let approval = PuckApprovalState(attached.summary.pendingApproval?.callID)
        let reader = Thread {
            do {
                var cursor = replayed.last?.cursor ?? attached.batch.cursor
                while let events = try client.receive(connection, session: id, after: cursor) {
                    for event in events {
                        cursor = event.cursor
                        if event.kind == "approval_pending" { approval.set(event.callID) }
                        if event.kind == "approval_decided" { approval.set(nil) }
                        printPuckEvent(event)
                    }
                }
            } catch {
                fputs("puckd: \(error.localizedDescription)\n", stderr)
            }
        }
        reader.start()
        print("Enter a prompt, /approve, /deny, /session, /answer, or /detach.")
        while let line = readLine() {
            let input = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if input == "/detach" { break }
            if ["/approve", "/deny", "/session"].contains(input) {
                guard let callID = approval.get() else {
                    print("No approval is pending")
                    continue
                }
                try client.decide(id, callID: callID, decision: String(input.dropFirst()))
            } else if input == "/answer" {
                guard let pending = try client.get(id).pendingQuestion else {
                    print("No question is pending")
                    continue
                }
                printPendingQuestion(pending)
                var selections: [PuckQuestionSelection] = []
                for question in pending.questions {
                    while true {
                        guard let response = readLine() else { break }
                        if let selection = PuckQuestionSelection.parse(response, for: question) {
                            selections.append(selection)
                            break
                        }
                        print("Enter an option number, comma-separated numbers, or text:your answer when offered.")
                    }
                }
                if selections.count == pending.questions.count {
                    try client.answer(id, callID: pending.callID, selections: selections)
                }
            } else if !input.isEmpty {
                try client.turn(id, prompt: input)
            }
        }
        connection.disconnect()
    default:
        throw PuckDaemonError.rejected("unknown puck subcommand '\(command)'")
    }
}

private struct PuckOptions {
    private let values: [String: String]

    init(_ args: [String]) throws {
        var result: [String: String] = [:]
        var index = 0
        while index < args.count {
            let option = args[index]
            guard option.hasPrefix("--"), index + 1 < args.count else {
                throw PuckDaemonError.rejected("expected --option VALUE")
            }
            let name = String(option.dropFirst(2))
            guard ["id", "cwd", "provider", "account", "model", "prompt", "call-id", "decision", "selections"].contains(name) else {
                throw PuckDaemonError.rejected("unknown puck option '\(option)'")
            }
            result[name] = args[index + 1]
            index += 2
        }
        values = result
    }

    subscript(_ key: String) -> String? { values[key] }

    func required(_ key: String) throws -> String {
        guard let value = values[key], !value.isEmpty else {
            throw PuckDaemonError.rejected("missing --\(key)")
        }
        return value
    }
}

private final class PuckApprovalState {
    private let lock = NSLock()
    private var callID: String?

    init(_ callID: String?) { self.callID = callID }

    func set(_ value: String?) {
        lock.lock()
        callID = value
        lock.unlock()
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return callID
    }
}

private func printPuckEvent(_ event: PuckSessionEvent) {
    if let text = event.displayText { print("[\(event.cursor)] \(text)") }
}

private func printPendingQuestion(_ pending: PuckPendingQuestion) {
    print("question \(pending.callID):")
    for question in pending.questions {
        print("\(question.header): \(question.question)")
        for (index, option) in question.options.enumerated() {
            print("  \(index + 1). \(option.label) — \(option.description)")
        }
        if question.multiple { print("  Pick multiple with comma-separated numbers.") }
        if question.custom { print("  Or enter text:your answer") }
    }
}
