import BanyanCore
import Foundation

protocol AgentSupervisorBackend {
    func hasSession(named name: String) -> Bool
    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot?
    func captureVisibleText(paneID: String, lineLimit: Int) -> String
}

extension TmuxBackend: AgentSupervisorBackend {}

struct AgentSupervisor {
    struct Result {
        let status: SessionStatus
        let tone: SessionTone
        let provider: CodingAgentProvider?
        let currentPath: String?
    }

    private let backend: any AgentSupervisorBackend
    private let processDescendants: (Int) -> [ProcessInfoRow]

    init(
        backend: any AgentSupervisorBackend = TmuxBackend.shared,
        processDescendants: @escaping (Int) -> [ProcessInfoRow] = { rootPID in
            ProcessTable.snapshot().descendants(of: rootPID)
        }
    ) {
        self.backend = backend
        self.processDescendants = processDescendants
    }

    func inspect(tmuxSessionName: String, launchCommand: String, currentStatus: SessionStatus) -> Result? {
        guard currentStatus != .closed else { return nil }
        guard let pane = backend.primaryPaneSnapshot(named: tmuxSessionName) else {
            return backend.hasSession(named: tmuxSessionName) ? nil : Result(status: .closed, tone: .neutral, provider: nil, currentPath: nil)
        }
        guard !pane.isDead else {
            return Result(status: .closed, tone: .neutral, provider: nil, currentPath: pane.currentPath)
        }

        let descendants = processDescendants(pane.rootPID)
        let provider = Self.detectProvider(
            launchCommand: launchCommand,
            paneCommand: pane.currentCommand,
            descendants: descendants
        )

        guard let provider else {
            return Result(status: .running, tone: .blue, provider: nil, currentPath: pane.currentPath)
        }

        let rootAgentProcessCount = Self.isSupportedAgentCommand(pane.currentCommand)
            && !descendants.contains { $0.pid == pane.rootPID && $0.isSupportedAgent } ? 1 : 0
        let agentProcessCount = Self.logicalAgentProcessCount(in: descendants)
        if rootAgentProcessCount + agentProcessCount > 1 {
            return Result(status: .subagents, tone: .purple, provider: provider, currentPath: pane.currentPath)
        }

        let helperPIDs = Self.agentHelperPIDs(in: descendants)
        let externalProcesses = descendants.filter { process in
            process.pid != pane.rootPID
                && !process.isSupportedAgent
                && !process.isShellOrWrapper
                && !process.isTmuxPlumbing
                && !helperPIDs.contains(process.pid)
        }

        if !externalProcesses.isEmpty {
            return Result(status: .executing, tone: .blue, provider: provider, currentPath: pane.currentPath)
        }

        let visibleText = backend.captureVisibleText(paneID: pane.paneID, lineLimit: 60)
        if Self.looksLikeAgentQuestion(visibleText) {
            return Result(status: .asking, tone: .yellow, provider: provider, currentPath: pane.currentPath)
        }
        if Self.looksLikeAgentExecuting(visibleText) {
            return Result(status: .executing, tone: .blue, provider: provider, currentPath: pane.currentPath)
        }

        return Result(status: .needInput, tone: .yellow, provider: provider, currentPath: pane.currentPath)
    }

    static func isSupportedAgentCommand(_ command: String) -> Bool {
        CodingAgentProvider.isSupportedCommand(command)
    }

    static func detectProvider(
        launchCommand: String,
        paneCommand: String,
        descendants: [ProcessInfoRow]
    ) -> CodingAgentProvider? {
        if let provider = CodingAgentProvider.detect(in: launchCommand) {
            return provider
        }
        if let provider = CodingAgentProvider.detect(in: paneCommand) {
            return provider
        }
        return descendants.compactMap(\.supportedAgentProvider).first
    }

    /// PIDs of the persistent MCP-server helpers a coding agent spawns and keeps
    /// alive across turns, plus any workers they fork. An MCP server is launched
    /// as a direct child of the agent process at startup and lives for the whole
    /// session, so — unlike a genuine command execution — it must not pin the
    /// session to `.executing` and hide idle-only affordances like the handoff
    /// button. We match them by name rather than by "any non-shell child" so a
    /// real foreground command the agent runs directly is still seen as work.
    static func agentHelperPIDs(in descendants: [ProcessInfoRow]) -> Set<Int> {
        let agentPIDs = Set(descendants.filter(\.isSupportedAgent).map(\.pid))
        guard !agentPIDs.isEmpty else { return [] }

        var helperPIDs = Set(
            descendants
                .filter { process in
                    agentPIDs.contains(process.parentPID) && process.isLikelyMCPServer
                }
                .map(\.pid)
        )
        guard !helperPIDs.isEmpty else { return [] }

        // Fold in any workers a helper forks (e.g. a node MCP server spawning a
        // child), so the whole persistent subtree is treated as idle plumbing.
        let childrenByParent = Dictionary(grouping: descendants, by: \.parentPID)
        var queue = Array(helperPIDs)
        while let pid = queue.popLast() {
            for child in childrenByParent[pid] ?? [] where !helperPIDs.contains(child.pid) {
                helperPIDs.insert(child.pid)
                queue.append(child.pid)
            }
        }
        return helperPIDs
    }

    static func logicalAgentProcessCount(in descendants: [ProcessInfoRow]) -> Int {
        let agentProcesses = descendants.filter(\.isSupportedAgent)
        let agentProcessesByParent = Dictionary(grouping: agentProcesses, by: \.parentPID)

        return agentProcesses.filter { process in
            guard process.isNodeAgentLauncher else { return true }
            guard let provider = process.supportedAgentProvider else { return true }
            let childAgents = agentProcessesByParent[process.pid] ?? []
            return !childAgents.contains { $0.supportedAgentProvider == provider }
        }.count
    }

    private static func looksLikeAgentQuestion(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let questionPhrases = [
            "do you want",
            "would you like",
            "should i",
            "can i",
            "shall i",
            "approve",
            "approval required",
            "permission required",
            "allow this",
            "continue?"
        ]
        if questionPhrases.contains(where: lowercased.contains) {
            return true
        }

        let trimmedLines = lowercased
            .split(separator: "\n")
            .suffix(8)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return trimmedLines.contains { line in
            line.hasSuffix("?") && line.count >= 8
        }
    }

    /// True only when the visible tail shows the agent is *actively* working —
    /// not merely that its finished output happens to mention work. Matching bare
    /// words like `working`/`editing`/`running` pinned idle sessions to
    /// `.executing` forever, because an agent's completion summary is full of them
    /// (e.g. Codex prints `Worked for 3m 38s` and bullets like `Ran … before
    /// editing.` while sitting at an idle prompt). TUI agents instead render a
    /// live "interrupt" affordance only while a turn is in flight and drop it the
    /// instant they return to the prompt, so that hint is the reliable signal.
    private static func looksLikeAgentExecuting(_ text: String) -> Bool {
        let tail = text
            .lowercased()
            .split(separator: "\n")
            .suffix(8)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // A live interrupt affordance is shown only while a turn is running
        // (Claude: "esc to interrupt", Codex: "Esc to interrupt", etc.).
        let interruptHints = [
            "esc to interrupt",
            "esc to stop",
            "ctrl-c to interrupt",
            "ctrl+c to interrupt"
        ]
        if tail.contains(where: { line in interruptHints.contains(where: line.contains) }) {
            return true
        }

        // Fallback for agents without an interrupt hint: a work verb on a line
        // that is still animating (trailing ellipsis). A past-tense summary line
        // such as "Worked for 3m 38s" or "Ran git diff --check." ends in a period,
        // not an ellipsis, so it deliberately does not match.
        let progressVerbs = [
            "thinking", "working", "running", "executing",
            "reading", "editing", "searching", "generating"
        ]
        return tail.contains { line in
            guard line.hasSuffix("…") || line.hasSuffix("...") else { return false }
            return progressVerbs.contains(where: line.contains)
        }
    }
}

struct ProcessTable {
    private let childrenByParent: [Int: [ProcessInfoRow]]
    private let rowByPID: [Int: ProcessInfoRow]

    init(rows: [ProcessInfoRow]) {
        self.childrenByParent = Dictionary(grouping: rows, by: \.parentPID)
        self.rowByPID = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
    }

    static func snapshot() -> ProcessTable {
        ProcessTable(rows: ProcessInfoRow.load())
    }

    func descendants(of rootPID: Int) -> [ProcessInfoRow] {
        var descendants: [ProcessInfoRow] = rowByPID[rootPID].map { [$0] } ?? []
        var queue = childrenByParent[rootPID] ?? []
        var visited = Set(descendants.map(\.pid))

        while let process = queue.popLast() {
            guard !visited.contains(process.pid) else { continue }
            visited.insert(process.pid)
            descendants.append(process)
            queue.append(contentsOf: childrenByParent[process.pid] ?? [])
        }

        return descendants
    }
}

struct ProcessInfoRow {
    let pid: Int
    let parentPID: Int
    let state: String
    let elapsed: TimeInterval
    let commandName: String
    let arguments: String

    var isSupportedAgent: Bool {
        supportedAgentProvider != nil
    }

    var supportedAgentProvider: CodingAgentProvider? {
        CodingAgentProvider.detect(in: commandName)
            ?? CodingAgentProvider.detect(in: arguments)
            ?? arguments
                .lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "/" })
                .compactMap { CodingAgentProvider.detect(in: String($0)) }
                .first
    }

    var isShellOrWrapper: Bool {
        let name = URL(fileURLWithPath: commandName).lastPathComponent.lowercased()
        return [
            "bash", "zsh", "sh", "fish", "login", "env", "script"
        ].contains(name)
    }

    var isTmuxPlumbing: Bool {
        let name = URL(fileURLWithPath: commandName).lastPathComponent.lowercased()
        return name == "tmux" || name == "reattach-to-user-namespace"
    }

    var isNodeAgentLauncher: Bool {
        URL(fileURLWithPath: commandName).lastPathComponent.lowercased() == "node"
    }

    /// A persistent MCP server (e.g. `axiom-mcp`, `npx @modelcontextprotocol/…`,
    /// `uvx mcp-server-foo`, `node mcp-server.js`). Matched by name so it can be
    /// distinguished from a real foreground command an agent runs directly.
    var isLikelyMCPServer: Bool {
        let haystack = (commandName + " " + arguments).lowercased()
        return haystack.contains("modelcontextprotocol")
            || haystack.contains("mcp-server")
            || haystack.contains("mcp_server")
            || haystack.contains("-mcp")
            || haystack.contains("/mcp")
            || haystack.contains(" mcp")
            || haystack.hasPrefix("mcp")
    }

    static func load() -> [ProcessInfoRow] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,stat=,etime=,comm=,command="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }

        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(separator: "\n").compactMap(parse)
    }

    private static func parse(_ line: Substring) -> ProcessInfoRow? {
        let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
        guard parts.count >= 6,
              let pid = Int(parts[0]),
              let parentPID = Int(parts[1]),
              let elapsed = parseElapsedTime(parts[3])
        else {
            return nil
        }

        return ProcessInfoRow(
            pid: pid,
            parentPID: parentPID,
            state: String(parts[2]),
            elapsed: elapsed,
            commandName: String(parts[4]),
            arguments: String(parts[5])
        )
    }

    private static func parseElapsedTime(_ value: Substring) -> TimeInterval? {
        let dayAndTime = value.split(separator: "-", maxSplits: 1)
        let dayCount: Int
        let timePart: Substring
        if dayAndTime.count == 2 {
            guard let days = Int(dayAndTime[0]) else { return nil }
            dayCount = days
            timePart = dayAndTime[1]
        } else {
            dayCount = 0
            timePart = value
        }

        let components = timePart.split(separator: ":").compactMap { Int($0) }
        guard components.count == 2 || components.count == 3 else { return nil }

        let seconds: Int
        if components.count == 3 {
            seconds = components[0] * 3600 + components[1] * 60 + components[2]
        } else {
            seconds = components[0] * 60 + components[1]
        }
        return TimeInterval(dayCount * 86_400 + seconds)
    }
}
