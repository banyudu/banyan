import Foundation

public enum CodexTUIHandoffError: LocalizedError {
    case refused(String)
    case busy(String)
    public var errorDescription: String? {
        switch self { case .refused(let reason), .busy(let reason): return reason }
    }
}

/// A receipt records preservation, not acquisition by Desktop/Remote. Exiting
/// one CLI cannot prove that another client has released the same writer.
public struct CodexTUIHandoffReceipt: Codable, Equatable, Sendable {
    public let threadID: String
    public let cwd: String
    public let transcriptPath: String
    public let paneID: String
    public let root: AgentProcessIdentity
    public let cli: AgentProcessIdentity
}

public protocol CodexTUIHandoffBackend: TmuxSessionBackend {
    func preserveCodexHandoffPane(_ receipt: CodexTUIHandoffReceipt) throws
    func codexHandoffReceipt(paneID: String) throws -> CodexTUIHandoffReceipt?
}

public struct CodexTUIOwnershipObservation: Sendable {
    public let threadID: String
    public let state: CodexTUIOwnership
    public let observedAt: Date
    public init(threadID: String, state: CodexTUIOwnership, observedAt: Date = Date()) {
        self.threadID = threadID
        self.state = state
        self.observedAt = observedAt
    }
}

public enum CodexTUIOwnership: String, Sendable {
    case turnPending
    case awaitingCLIExit
    case cliExited

    public var title: String {
        switch self {
        case .turnPending: return "Turn or request pending"
        case .awaitingCLIExit: return "Completed turn — ready to exit CLI"
        case .cliExited: return "Last check: CLI exited"
        }
    }

    public var message: String {
        switch self {
        case .turnPending:
            return "Codex has a running turn or pending request. Finish it before preparing handoff or entering /quit. No agent was stopped."
        case .awaitingCLIExit:
            return "The recorded Codex process is still open and may hold this thread's writer. When the turn and pending requests finish, enter /quit in that CLI, then Check CLI Exit. The tmux pane, transcript, and worktree are preserved. Detaching the terminal display does not release the writer. If /quit has already completed, use the remaining daemon/client's supported lifecycle."
        case .cliExited:
            return "At the last check, the recorded Codex CLI had exited. Recheck after any terminal activity. Reopen this same thread in ChatGPT Remote. If reconnect fails, another client or daemon may own the writer. Exit or detach that client using its supported lifecycle, then retry Remote. Keep this pane for history and avoid restarting the CLI while Remote is using the thread."
        }
    }
}

/// Legacy interactive CLIs expose no external, atomic idle-and-shutdown RPC.
/// Arm preservation first, then let the human use the supported /quit command.
/// Never type into a potentially changed composer, signal an agent, or start a
/// replacement thread. Both preparation and confirmation are explicit actions.
public enum CodexTUIHandoff {
    public static func prepare(threadID: String, cwd: String, transcriptURL requestedURL: URL? = nil,
                               sessionName: String, backend: any CodexTUIHandoffBackend,
                               inspector: any CodexTUIProcessInspecting) throws -> CodexTUIHandoffReceipt {
        guard let pane = backend.primaryPaneSnapshot(named: sessionName), !pane.isDead, !pane.isInMode else {
            throw CodexTUIHandoffError.refused("No verifiable interactive Codex CLI in this pane. Exit copy mode or select its live terminal; native sessions use their own detach path.")
        }
        let tree = try inspector.tree(rootPID: Int32(pane.rootPID))
        let candidates = tree.filter(\.isCodex).flatMap(\.openRollouts).map { URL(fileURLWithPath: $0) }
        guard let transcriptURL = requestedURL ?? candidates.first(where: {
            (try? validateTranscriptIdentity($0, threadID: threadID, cwd: cwd)) != nil
        }) else {
            throw CodexTUIHandoffError.refused("No open Codex rollout matches this exact thread ID and working directory. Refresh history or check its CLI storage configuration; no new thread will be started.")
        }
        guard let root = tree.first(where: { $0.identity.pid == pane.rootPID }),
              let cli = tree.first(where: { $0.isCodex && $0.openRollouts.contains(where: { canonical($0) == canonical(transcriptURL.path) }) }),
              tree.filter({ $0.isCodex }).allSatisfy({ $0.openRollouts.isEmpty || $0.openRollouts.allSatisfy({ canonical($0) == canonical(transcriptURL.path) }) }) else {
            throw CodexTUIHandoffError.refused("The live Codex CLI does not have this exact thread's transcript open. Its imported ID may be stale. Refresh history; no exit was requested.")
        }
        let text = backend.captureVisibleText(paneID: pane.paneID, lineLimit: 80)
        guard !AgentSupervisor.looksLikeAgentExecuting(text),
              AgentPromptParser.parse(visibleText: text) == nil else {
            throw CodexTUIHandoffError.busy("Wait for the running turn and answer pending requests before preparing Remote handoff.")
        }
        try validateCompletedTranscript(transcriptURL, threadID: threadID, cwd: cwd)
        let receipt = CodexTUIHandoffReceipt(threadID: threadID, cwd: cwd, transcriptPath: transcriptURL.path,
            paneID: pane.paneID, root: root.identity, cli: cli.identity)
        // Critical for older one-shot panes: without remain-on-exit, /quit can
        // destroy their final pane and session. Failure must stop this workflow.
        guard let fresh = backend.primaryPaneSnapshot(named: sessionName), fresh.paneID == pane.paneID,
              fresh.rootPID == pane.rootPID, !fresh.isDead,
              try !inspector.hasExited(root.identity), try !inspector.hasExited(cli.identity) else {
            throw CodexTUIHandoffError.refused("The pane or CLI changed while preparing handoff. Retry; no exit was requested.")
        }
        try backend.preserveCodexHandoffPane(receipt)
        return receipt
    }

    public static func check(sessionName: String, threadID: String,
                             backend: any CodexTUIHandoffBackend, inspector: any CodexTUIProcessInspecting) throws -> CodexTUIOwnership {
        guard let pane = backend.primaryPaneSnapshot(named: sessionName),
              let receipt = try backend.codexHandoffReceipt(paneID: pane.paneID),
              receipt.threadID == threadID, receipt.paneID == pane.paneID, receipt.root.pid == pane.rootPID else {
            throw CodexTUIHandoffError.refused("Prepare Remote Handoff for this thread first. Its pane or process identity changed; no writer release has been confirmed.")
        }
        guard FileManager.default.fileExists(atPath: receipt.transcriptPath),
              FileManager.default.fileExists(atPath: receipt.cwd) else {
            throw CodexTUIHandoffError.refused("The recorded transcript or working directory is missing. Restore it before reconnecting; Banyan will not start another thread.")
        }
        try validateTranscriptIdentity(URL(fileURLWithPath: receipt.transcriptPath), threadID: receipt.threadID, cwd: receipt.cwd)
        if pane.isDead {
            guard try inspector.hasExited(receipt.root), try inspector.hasExited(receipt.cli) else {
                throw CodexTUIHandoffError.refused("The pane is dead but its recorded processes have not exited. Retry the check.")
            }
            return .cliExited
        }
        let tree = try inspector.tree(rootPID: Int32(pane.rootPID))
        guard tree.contains(where: { $0.identity == receipt.root }) else {
            throw CodexTUIHandoffError.refused("The pane root's kernel identity changed. Prepare handoff again.")
        }
        if tree.contains(where: { $0.isCodex && $0.identity != receipt.cli && !$0.openRollouts.isEmpty }) {
            throw CodexTUIHandoffError.refused("Another CLI has started in this pane. Prepare a new handoff for its current thread.")
        }
        if try inspector.hasExited(receipt.cli) {
            guard !tree.contains(where: \.isCodex) else {
                throw CodexTUIHandoffError.refused("A new Codex process is running. Prepare handoff again; the previous exit observation is stale.")
            }
            return .cliExited
        }
        guard tree.contains(where: { $0.identity == receipt.cli && $0.openRollouts.contains(where: { canonical($0) == canonical(receipt.transcriptPath) }) }) else {
            throw CodexTUIHandoffError.refused("The CLI changed its active thread. Refresh history and prepare a new handoff.")
        }
        do {
            try validateCompletedTranscript(URL(fileURLWithPath: receipt.transcriptPath), threadID: receipt.threadID, cwd: receipt.cwd)
        } catch CodexTUIHandoffError.busy { return .turnPending }
        return .awaitingCLIExit
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func validateTranscriptIdentity(_ url: URL, threadID: String, cwd: String) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try file.read(upToCount: 65_536) ?? Data()
        guard let first = header.split(separator: 10).first,
              let row = try? JSONDecoder().decode(CodexJSONValue.self, from: Data(first)),
              row.objectValue?["type"] == .string("session_meta"),
              let meta = row.objectValue?["payload"]?.objectValue,
              meta["id"] == .string(threadID), meta["cwd"] == .string(cwd) else {
            throw CodexTUIHandoffError.refused("The persisted transcript does not match this exact thread and working directory. Refresh history before handoff.")
        }
    }

    /// Read the header and a bounded tail instead of loading a long conversation.
    /// An incomplete write, a new user message, or an uncompleted task fails closed.
    static func validateCompletedTranscript(_ url: URL, threadID: String, cwd: String) throws {
        try validateTranscriptIdentity(url, threadID: threadID, cwd: cwd)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        let offset = length > 1_048_576 ? length - 1_048_576 : 0
        try file.seek(toOffset: offset)
        let tail = try file.read(upToCount: Int(length - offset)) ?? Data()
        guard try file.seekToEnd() == length else {
            throw CodexTUIHandoffError.busy("The Codex transcript changed during the handoff check. Wait for turn completion and retry.")
        }
        guard tail.last == 10 else {
            throw CodexTUIHandoffError.refused("Codex is still writing its transcript. Wait for turn completion and retry.")
        }
        var lines = tail.split(separator: 10)
        if offset > 0 { lines = Array(lines.dropFirst()) }
        var completed = false
        for line in lines {
            guard let row = try? JSONDecoder().decode(CodexJSONValue.self, from: Data(line)) else {
                throw CodexTUIHandoffError.refused("The Codex transcript is incomplete. Wait and retry; no exit was requested.")
            }
            guard row.objectValue?["type"] == .string("event_msg"),
                  let event = row.objectValue?["payload"]?.objectValue?["type"]?.stringValue else { continue }
            switch event {
            case "task_complete": completed = true
            case "task_started", "user_message", "turn_aborted": completed = false
            default: break
            }
        }
        guard completed else {
            throw CodexTUIHandoffError.busy("A completed Codex turn is required. Finish the active turn and pending requests, then retry Remote handoff.")
        }
    }
}
