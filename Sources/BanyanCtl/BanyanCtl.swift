import BanyanCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct BanyanCtl {
    let arguments: [String]
    let host: HostRuntimeContext
    var baseURL: URL {
        let address = host.environment["BANYAN_FIXTURE_CONTROL_URL"] ?? "http://127.0.0.1:7842"
        guard let url = URL(string: address), url.scheme == "http", url.host == "127.0.0.1" else {
            preconditionFailure("Invalid local Banyan control address")
        }
        return url
    }

    init(arguments: [String]) {
        self.arguments = arguments
        self.host = HostRuntimeContext(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: URL(fileURLWithPath: NSHomeDirectory()),
            currentDirectory: FileManager.default.currentDirectoryPath
        )
    }

    func run() {
        guard let command = arguments.first else {
            printHelp()
            return
        }

        do {
            switch command {
            case SessionTitleMCP.subcommand:
                let payload = try parsePayload(Array(arguments.dropFirst()))
                guard let id = payload["id"], !id.isEmpty else { throw CLIError.message("session title MCP requires --id") }
                runSessionTitleMCP(id: id)
            case "spawn":
                try post("/spawn", payload: withDefaultParent(parsePayload(Array(arguments.dropFirst()))))
            case "session":
                try runSessionCommand(Array(arguments.dropFirst()))
            case "agent":
                try runAgentCommand(Array(arguments.dropFirst()))
            case "puck":
                try runPuckCtl(Array(arguments.dropFirst()), host: host)
            case "perf":
                try runPerfCommand(Array(arguments.dropFirst()))
            case "mark":
                try post("/mark", payload: parsePayload(Array(arguments.dropFirst())))
            case "coordination":
                if arguments.count == 1 || arguments[1] == "--help" { printHelp(); return }
                var payload = try workflowPayload(Array(arguments.dropFirst(2)))
                payload["action"] = arguments[1]
                try post("/coordination", payload: payload)
            case "workflow":
                guard arguments.count >= 2, ["set", "wake", "resolve", "close-verified"].contains(arguments[1]) else {
                    throw CLIError.message("workflow requires set, wake, resolve or close-verified")
                }
                try post("/workflow-\(arguments[1])", payload: workflowPayload(Array(arguments.dropFirst(2))))
            case "select":
                try post("/select", payload: parsePayload(Array(arguments.dropFirst())))
            case "reparent":
                try post("/reparent", payload: reparentPayload(Array(arguments.dropFirst())))
            case "tick":
                try post("/tick", payload: parsePayload(Array(arguments.dropFirst())))
            case "suspend":
                try post("/suspend", payload: parsePayload(Array(arguments.dropFirst())))
            case "freeze", "unfreeze":
                try post("/\(command)", payload: parsePayload(Array(arguments.dropFirst())))
            case "resume":
                try post("/resume", payload: parsePayload(Array(arguments.dropFirst())))
            case "close":
                try post("/close", payload: parsePayload(Array(arguments.dropFirst())))
            case "respawn":
                try post("/respawn", payload: parsePayload(Array(arguments.dropFirst())))
            case "restart":
                try post("/restart", payload: parsePayload(Array(arguments.dropFirst())))
            case "remove":
                try post("/remove", payload: parsePayload(Array(arguments.dropFirst())))
            case "screenshot":
                try post("/screenshot", payload: parseScreenshotPayload(Array(arguments.dropFirst())))
            case "output":
                try get("/output", query: parseOutputOptions(Array(arguments.dropFirst())))
            case "send":
                try postJSON("/input", payload: parseSendPayload(Array(arguments.dropFirst())))
            case "codex-remote":
                let payload = try parsePayload(Array(arguments.dropFirst(2)))
                switch arguments.dropFirst().first {
                case "configure":
                    guard let path = payload["path"] else { throw NSError(domain: "BanyanCtl", code: 64, userInfo: [NSLocalizedDescriptionKey: "configure requires --path policy.json"]) }
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                    try postJSON("/codex-remote-configure", payload: object)
                case "resolve": try post("/codex-remote-resolve", payload: payload)
                default: throw NSError(domain: "BanyanCtl", code: 64, userInfo: [NSLocalizedDescriptionKey: "Use codex-remote configure --path policy.json or resolve --workspace ID --operationID ID"])
                }
            case "codex-handoff":
                try post("/codex-handoff", payload: parsePayload(Array(arguments.dropFirst())))
            case "answer":
                try postJSON("/answer", payload: parseAnswerPayload(Array(arguments.dropFirst())))
            case "events":
                try get("/events", query: parseEventsOptions(Array(arguments.dropFirst())), timeout: 35)
            case "suggest":
                try post("/suggest", payload: parseSuggestPayload(Array(arguments.dropFirst())))
            case "prune":
                try post("/prune", payload: parsePrunePayload(Array(arguments.dropFirst())))
            case "list":
                try get("/list", query: SessionListOptions(arguments: Array(arguments.dropFirst())).queryItems)
            case "window-state":
                try get("/window-state")
            case "help", "--help", "-h":
                printHelp()
            default:
                throw CLIError.message("unknown command '\(command)'")
            }
        } catch let error as CLIError {
            fputs("banyanctl: \(error.localizedDescription)\n", stderr)
            exit(error.exitCode)
        } catch let error as ControlValidationError {
            fputs("banyanctl: \(error.localizedDescription)\n", stderr)
            exit(ExitCode.badInput)
        } catch {
            fputs("banyanctl: \(error.localizedDescription)\n", stderr)
            exit(ExitCode.serverUnavailable)
        }
    }
}
