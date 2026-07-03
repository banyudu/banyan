import Foundation

protocol AgentSupervisorBackend {
    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot?
    func captureVisibleText(paneID: String, lineLimit: Int) -> String
}

extension TmuxBackend: AgentSupervisorBackend {}

struct AgentSupervisor {
    struct Result {
        let status: SessionStatus
        let tone: SessionTone
    }

    private let backend: any AgentSupervisorBackend
    private let longRunningThreshold: TimeInterval
    private let processDescendants: (Int) -> [ProcessInfoRow]

    init(
        backend: any AgentSupervisorBackend = TmuxBackend.shared,
        longRunningThreshold: TimeInterval = 120,
        processDescendants: @escaping (Int) -> [ProcessInfoRow] = { rootPID in
            ProcessTable.snapshot(rootPID: rootPID).descendants
        }
    ) {
        self.backend = backend
        self.longRunningThreshold = longRunningThreshold
        self.processDescendants = processDescendants
    }

    func inspect(tmuxSessionName: String, launchCommand: String, currentStatus: SessionStatus) -> Result? {
        guard currentStatus != .closed else { return nil }
        guard let pane = backend.primaryPaneSnapshot(named: tmuxSessionName), !pane.isDead else {
            return currentStatus == .closed ? nil : Result(status: .closed, tone: .neutral)
        }

        let descendants = processDescendants(pane.rootPID)
        let isAgent = Self.isSupportedAgentCommand(launchCommand)
            || Self.isSupportedAgentCommand(pane.currentCommand)
            || descendants.contains { $0.isSupportedAgent }

        guard isAgent else {
            return Result(status: .running, tone: .blue)
        }

        let rootAgentProcessCount = Self.isSupportedAgentCommand(pane.currentCommand) ? 1 : 0
        let agentProcesses = descendants.filter(\.isSupportedAgent)
        if rootAgentProcessCount + agentProcesses.count > 1 {
            return Result(status: .subagents, tone: .purple)
        }

        let externalProcesses = descendants.filter { process in
            !process.isSupportedAgent
                && !process.isShellOrWrapper
                && !process.isTmuxPlumbing
        }

        if externalProcesses.contains(where: { $0.elapsed >= longRunningThreshold }) {
            return Result(status: .longRunningShell, tone: .yellow)
        }

        if !externalProcesses.isEmpty {
            return Result(status: .executing, tone: .blue)
        }

        let visibleText = backend.captureVisibleText(paneID: pane.paneID, lineLimit: 60)
        if Self.looksLikeAgentQuestion(visibleText) {
            return Result(status: .asking, tone: .yellow)
        }
        if Self.looksLikeAgentExecuting(visibleText) {
            return Result(status: .executing, tone: .blue)
        }

        return Result(status: .needInput, tone: .yellow)
    }

    static func isSupportedAgentCommand(_ command: String) -> Bool {
        let normalized = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        let firstToken = normalized
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? normalized
        let executable = URL(fileURLWithPath: firstToken).lastPathComponent
        return ["claude", "codex", "opencode"].contains(executable)
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

    private static func looksLikeAgentExecuting(_ text: String) -> Bool {
        let lowercased = text
            .lowercased()
            .split(separator: "\n")
            .suffix(8)
            .joined(separator: "\n")
        let executingPhrases = [
            "thinking",
            "working",
            "running",
            "executing",
            "reading",
            "editing",
            "searching",
            "esc to interrupt",
            "ctrl-c to interrupt"
        ]
        return executingPhrases.contains(where: lowercased.contains)
    }
}

private struct ProcessTable {
    let descendants: [ProcessInfoRow]

    static func snapshot(rootPID: Int) -> ProcessTable {
        let rows = ProcessInfoRow.load()
        let childrenByParent = Dictionary(grouping: rows, by: \.parentPID)
        var descendants: [ProcessInfoRow] = []
        var queue = childrenByParent[rootPID] ?? []
        var visited = Set<Int>()

        while let process = queue.popLast() {
            guard !visited.contains(process.pid) else { continue }
            visited.insert(process.pid)
            descendants.append(process)
            queue.append(contentsOf: childrenByParent[process.pid] ?? [])
        }

        return ProcessTable(descendants: descendants)
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
        AgentSupervisor.isSupportedAgentCommand(commandName)
            || AgentSupervisor.isSupportedAgentCommand(arguments)
            || arguments
                .lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "/" })
                .contains { ["claude", "codex", "opencode"].contains(String($0)) }
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

    static func load() -> [ProcessInfoRow] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,stat=,etimes=,comm=,command="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        guard process.terminationStatus == 0 else { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(separator: "\n").compactMap(parse)
    }

    private static func parse(_ line: Substring) -> ProcessInfoRow? {
        let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
        guard parts.count >= 6,
              let pid = Int(parts[0]),
              let parentPID = Int(parts[1]),
              let elapsed = TimeInterval(parts[3])
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
}
