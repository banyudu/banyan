import BanyanCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension BanyanCtl {
    func runSessionCommand(_ args: [String]) throws {
        guard let subcommand = args.first else {
            throw CLIError.message("session requires a subcommand")
        }
        switch subcommand {
        case "list":
            try listUnifiedSessions(options: SessionListOptions(arguments: Array(args.dropFirst())))
        case "new", "spawn":
            try post("/spawn", payload: withDefaultParent(parsePayload(Array(args.dropFirst()))))
        case "title":
            var payload = try parsePayload(Array(args.dropFirst()))
            if payload["id"] == nil {
                payload["id"] = host.environment[BanyanSessionEnvironment.sessionIDKey]
                    ?? enclosingTmuxSessionID(environment: host.environment)
            }
            guard let id = payload["id"], let title = payload["title"] else {
                throw CLIError.message("session title requires --title TEXT and an enclosing session or --id ID")
            }
            print(try updateSessionTitle(id: id, title: title) ? "Session title updated" : "Manual session title preserved")
        case "current":
            guard args.count == 1, let id = currentSessionID() else {
                throw CLIError.message("Cannot identify this process's Banyan session; run from the main conversation")
            }
            print(String(decoding: try JSONSerialization.data(withJSONObject: ["id": id]), as: UTF8.self))
        case "suspend":
            try post("/agent-suspend", payload: sessionLifecyclePayload(Array(args.dropFirst())))
        case "freeze", "unfreeze":
            try post("/\(subcommand)", payload: parsePayload(Array(args.dropFirst())))
        case "resume":
            try post("/agent-resume", payload: sessionLifecyclePayload(Array(args.dropFirst())))
        default:
            throw CLIError.message("unknown session subcommand '\(subcommand)'")
        }
    }

    func sessionLifecyclePayload(_ args: [String]) throws -> [String: String] {
        if args.count == 1, let id = args.first, !id.hasPrefix("-") { return ["id": id] }
        return try parsePayload(args)
    }

    func workflowPayload(_ args: [String]) throws -> [String: String] {
        var payload = try parsePayload(args)
        if let jobID = payload.removeValue(forKey: "job-id") { payload["jobID"] = jobID }
        if let wakeID = payload.removeValue(forKey: "wake-id") { payload["wakeID"] = wakeID }
        if let runID = payload.removeValue(forKey: "run-id") { payload["runID"] = runID }
        if let groupID = payload.removeValue(forKey: "group-id") { payload["groupID"] = groupID }
        if let value = payload.removeValue(forKey: "intervention-id") { payload["interventionID"] = value }
        if let value = payload.removeValue(forKey: "inspection-id") { payload["inspectionID"] = value }
        return payload
    }

    /// One catalog for shell and daemon sessions. The daemon half remains
    /// available when the Banyan app is closed. The app lists the daemon
    /// sessions it shows as its own rows, so those appear once, as the app's.
    private func listUnifiedSessions(options: SessionListOptions) throws {
        var sessions: [[String: Any]] = []
        var appSessionIDs: Set<String> = []
        var shellAvailable = false
        var puckAvailable = false
        var workflowProtocol: Int?
        if let app = try? loadShellSessions(options: options) {
            sessions.append(contentsOf: app.sessions.map(UnifiedSessionCatalog.appRow))
            appSessionIDs = Set(app.sessions.compactMap { $0["id"] as? String }).union(app.puckIDs)
            workflowProtocol = app.workflowProtocol
            shellAvailable = true
        }
        let puckClient = PuckDaemonClient(environment: host.environment,
                                          homeDirectory: host.homeDirectory.path)
        if let puckSessions = try? puckClient.list() {
            sessions.append(contentsOf: puckSessions.filter { !appSessionIDs.contains($0.id) }.map { session in
                ["id": session.id, "backend": "puck", "provider": session.provider,
                 "model": session.model, "account": session.account,
                 "cwd": session.cwd, "workspace": session.workspace,
                 "status": session.position]
            })
            puckAvailable = true
        }
        guard shellAvailable || puckAvailable else { throw CLIError.serverUnavailable }
        // Also filter daemon rows and responses from older app versions that
        // do not yet apply the HTTP query parameters themselves.
        sessions = sessions.filter { row in
            options.matches(id: row["id"] as? String ?? "", status: row["status"] as? String ?? "") {
                ["title", "displayTitle", "reportedTitle", "generatedTitle", "contextualTitle", "cwd", "titleURL"]
                    .compactMap { row[$0] as? String }
            }
        }
        var output: [String: Any] = [
            "sessions": sessions,
            "shellAvailable": shellAvailable,
            "puckAvailable": puckAvailable
        ]
        if let workflowProtocol { output["workflowProtocol"] = workflowProtocol }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    func loadShellSessions(options: SessionListOptions) throws -> (sessions: [[String: Any]], workflowProtocol: Int?, puckIDs: [String]) {
        var components = URLComponents(url: baseURL.appendingPathComponent("list"), resolvingAgainstBaseURL: false)!
        components.queryItems = options.queryItems.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        try authorize(&request)
        let result = try exchange(request)
        guard result.statusCode < 400,
              let data = result.data,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = object["data"] as? [String: Any],
              let sessions = body["sessions"] as? [[String: Any]] else {
            throw CLIError.message("Banyan returned an invalid session list")
        }
        return (sessions, body["workflowProtocol"] as? Int, body["appPuckSessionIDs"] as? [String] ?? [])
    }

    func runAgentCommand(_ args: [String]) throws {
        guard let subcommand = args.first else {
            throw CLIError.message("agent requires a subcommand")
        }
        switch subcommand {
        case "run":
            try post("/spawn", payload: withDefaultParent(parseAgentRunPayload(Array(args.dropFirst()))))
        case "queue":
            let action = args.dropFirst().first ?? "status"
            if action == "status" { try get("/agent-queue"); return }
            guard args.count == 3 else { throw CLIError.message("agent queue requires cancel|prioritize|retry ID or limit N") }
            if action == "limit" {
                guard let limit = Int(args[2]), (1...AgentAdmissionController.maximumLimit).contains(limit) else { throw CLIError.message("agent limit must be between 1 and \(AgentAdmissionController.maximumLimit)") }
                try post("/agent-limit", payload: ["limit": String(limit)])
            } else {
                guard ["cancel", "prioritize", "retry"].contains(action) else { throw CLIError.message("unknown agent queue action") }
                try post("/agent-queue", payload: ["id": args[2], "detail": action])
            }
        default:
            throw CLIError.message("unknown agent subcommand '\(subcommand)'")
        }
    }

    /// Maps `--focus` / `--no-focus` / `--background` to a "true"/"false" flag,
    /// or nil for any other key (which is treated as a normal `--key value` pair).
    static func booleanFocusFlag(for rawKey: String) -> String? {
        switch rawKey {
        case "focus":
            return "true"
        case "no-focus", "background", "bg":
            return "false"
        default:
            return nil
        }
    }

    func reparentPayload(_ args: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < args.count {
            let flag = args[index]
            switch flag {
            case "--no-parent":
                guard result["parent"] == nil else { throw CLIError.message("choose exactly one of --parent or --no-parent") }
                result["parent"] = ""
                index += 1
            case "--id", "--parent":
                let key = String(flag.dropFirst(2))
                guard result[key] == nil else { throw CLIError.message("duplicate \(flag)") }
                guard index + 1 < args.count, !args[index + 1].hasPrefix("--"),
                      !args[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError.message("missing value for \(flag)")
                }
                result[key] = args[index + 1]
                index += 2
            default: throw CLIError.message("unexpected reparent argument '\(flag)'")
            }
        }
        guard result["id"] != nil else { throw CLIError.message("reparent requires --id") }
        guard result["parent"] != nil else { throw CLIError.message("reparent requires --parent ID or --no-parent") }
        return result
    }
}
