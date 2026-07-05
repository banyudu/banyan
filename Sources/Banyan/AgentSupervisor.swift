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
    }

    private let backend: any AgentSupervisorBackend
    private let longRunningThreshold: TimeInterval
    private let processDescendants: (Int) -> [ProcessInfoRow]

    init(
        backend: any AgentSupervisorBackend = TmuxBackend.shared,
        longRunningThreshold: TimeInterval = 120,
        processDescendants: @escaping (Int) -> [ProcessInfoRow] = { rootPID in
            ProcessTable.snapshot().descendants(of: rootPID)
        }
    ) {
        self.backend = backend
        self.longRunningThreshold = longRunningThreshold
        self.processDescendants = processDescendants
    }

    func inspect(tmuxSessionName: String, launchCommand: String, currentStatus: SessionStatus) -> Result? {
        guard currentStatus != .closed else { return nil }
        guard let pane = backend.primaryPaneSnapshot(named: tmuxSessionName) else {
            return backend.hasSession(named: tmuxSessionName) ? nil : Result(status: .closed, tone: .neutral, provider: nil)
        }
        guard !pane.isDead else {
            return Result(status: .closed, tone: .neutral, provider: nil)
        }

        let descendants = processDescendants(pane.rootPID)
        let provider = Self.detectProvider(
            launchCommand: launchCommand,
            paneCommand: pane.currentCommand,
            descendants: descendants
        )

        guard let provider else {
            return Result(status: .running, tone: .blue, provider: nil)
        }

        let rootAgentProcessCount = Self.isSupportedAgentCommand(pane.currentCommand) ? 1 : 0
        let agentProcesses = descendants.filter(\.isSupportedAgent)
        if rootAgentProcessCount + agentProcesses.count > 1 {
            return Result(status: .subagents, tone: .purple, provider: provider)
        }

        let externalProcesses = descendants.filter { process in
            process.pid != pane.rootPID
                && !process.isSupportedAgent
                && !process.isShellOrWrapper
                && !process.isTmuxPlumbing
        }

        if externalProcesses.contains(where: { $0.elapsed >= longRunningThreshold }) {
            return Result(status: .longRunningShell, tone: .yellow, provider: provider)
        }

        if !externalProcesses.isEmpty {
            return Result(status: .executing, tone: .blue, provider: provider)
        }

        let visibleText = backend.captureVisibleText(paneID: pane.paneID, lineLimit: 60)
        if Self.looksLikeAgentQuestion(visibleText) {
            return Result(status: .asking, tone: .yellow, provider: provider)
        }
        if Self.looksLikeAgentExecuting(visibleText) {
            return Result(status: .executing, tone: .blue, provider: provider)
        }

        return Result(status: .needInput, tone: .yellow, provider: provider)
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
