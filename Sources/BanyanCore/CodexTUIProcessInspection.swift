import Foundation

public struct CodexTUIProcess: Sendable {
    public let identity: AgentProcessIdentity
    public let isCodex: Bool
    public let openRollouts: [String]

    public init(identity: AgentProcessIdentity, isCodex: Bool, openRollouts: [String]) {
        self.identity = identity
        self.isCodex = isCodex
        self.openRollouts = openRollouts
    }
}

public protocol CodexTUIProcessInspecting: Sendable {
    /// Must throw if enumeration, argv, or any live member's identity is unreadable.
    func tree(rootPID: Int32) throws -> [CodexTUIProcess]
    /// Distinguishes a missing process from an unreadable live process or reused PID.
    func hasExited(_ identity: AgentProcessIdentity) throws -> Bool
}

/// Read-only and user-invoked. Never signals a process, even to test existence.
public struct CodexTUIProcessInspector: CodexTUIProcessInspecting {
    public init() {}

    public func tree(rootPID: Int32) throws -> [CodexTUIProcess] {
        let rows = try ProcessTableSource.rowsForSignaling()
        guard rows.contains(where: { $0.pid == rootPID }) else {
            throw CodexTUIHandoffError.refused("The complete pane root could not be enumerated. Retry the handoff check.")
        }
        var pids: Set<Int> = [Int(rootPID)]
        let children = Dictionary(grouping: rows, by: \.parentPID)
        var queue = [Int(rootPID)]
        while let parent = queue.popLast() {
            for child in children[parent] ?? [] where !child.state.hasPrefix("Z") {
                if pids.insert(child.pid).inserted { queue.append(child.pid) }
            }
        }
        let commands = ProcessTableSource.commandLines(forPIDs: Array(pids))
        let result = try pids.sorted().map { pid in
            guard let sample = AgentProcessSample.read(pid: Int32(pid)),
                  let command = commands[pid], !command.arguments.isEmpty else {
                throw CodexTUIHandoffError.refused("Cannot inspect the complete live pane process tree. Retry; CLI exit has not been confirmed.")
            }
            let classified = ProcessInfoRow(pid: pid, parentPID: Int(sample.parentPID), state: "S", elapsed: 0,
                commandName: command.name, arguments: command.arguments)
            let isCodex = classified.isSupportedAgent && classified.supportedAgentProvider == .codex
            let paths: [String]
            if isCodex {
                let result = try SubprocessRunner.run(arguments: ["/usr/sbin/lsof", "-nP", "-a", "-p", String(pid), "-Fn"],
                    cwd: "/", environment: ["PATH": "/usr/bin:/bin:/usr/sbin"], timeout: 5)
                guard result.terminationStatus == 0 else {
                    throw CodexTUIHandoffError.refused("Cannot inspect Codex's open transcript. Retry; no handoff was confirmed.")
                }
                paths = String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n")
                    .filter { $0.hasPrefix("n/") && $0.hasSuffix(".jsonl") }
                    .map { String($0.dropFirst()) }
            } else { paths = [] }
            guard AgentProcessSample.read(pid: Int32(pid))?.identity == sample.identity else {
                throw CodexTUIHandoffError.refused("Pane process identity changed during inspection. Retry handoff.")
            }
            return CodexTUIProcess(identity: sample.identity, isCodex: isCodex, openRollouts: paths)
        }
        let fresh = try ProcessTableSource.rowsForSignaling()
        let freshTree = ProcessTable(tableRows: fresh).descendants(of: Int(rootPID)).filter { !$0.isExited }
        guard Set(freshTree.map(\.pid)) == pids,
              result.allSatisfy({ AgentProcessSample.read(pid: $0.identity.pid)?.identity == $0.identity }) else {
            throw CodexTUIHandoffError.refused("The pane process tree changed during inspection. Retry; no exit has been confirmed.")
        }
        return result
    }

    public func hasExited(_ identity: AgentProcessIdentity) throws -> Bool {
        // A successful complete kernel listing distinguishes ESRCH from an
        // inaccessible/zombie process. Missing argv/sample alone never proves exit.
        let rows = try ProcessTableSource.rowsForSignaling()
        guard let row = rows.first(where: { $0.pid == identity.pid }) else { return true }
        guard let current = AgentProcessSample.read(pid: identity.pid)?.identity else {
            throw CodexTUIHandoffError.refused("The recorded process still exists but its identity is unreadable (state \(row.state)). Retry the exit check.")
        }
        guard current == identity else {
            throw CodexTUIHandoffError.refused("A recorded process ID was reused. Prepare handoff again; this receipt cannot confirm ownership.")
        }
        return false
    }
}
