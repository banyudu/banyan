import Foundation

/// Evidence tying a live tmux pane and process generation to one open rollout.
/// The caller must resolve again after an asynchronous history read and compare
/// the result before publishing it. This is not a persisted resume identity.
public struct CodexTerminalConversation: Equatable, Sendable {
    public let paneID: String
    public let root: AgentProcessIdentity
    public let writer: AgentProcessIdentity
    public let conversationID: String
    public let transcriptURL: URL

    public func historyIdentity(sessionID: String) -> ConversationHistoryReader.Identity {
        .init(provider: .codex, conversationID: conversationID, transcriptURL: transcriptURL,
              terminalOwner: .init(sessionID: sessionID, paneID: paneID, root: root, writer: writer))
    }
}

/// Resolves only files currently held open by the pane's one verified Codex
/// process. A working directory, title, timestamp, or inferred session ID is not
/// evidence of conversation ownership.
public enum CodexTerminalConversationResolver {
    public enum ResolutionError: Error, Equatable {
        case unavailable, ambiguous, changed, invalidTranscript
    }

    public static func resolve(sessionName: String, backend: any TmuxSessionBackend,
                               inspector: any CodexTUIProcessInspecting) throws -> CodexTerminalConversation {
        guard let pane = backend.primaryPaneSnapshot(named: sessionName), !pane.isDead,
              pane.rootPID > 0, pane.rootPID <= Int(Int32.max) else { throw ResolutionError.unavailable }
        let first = try inspect(pane: pane, inspector: inspector)
        let id = try transcriptID(first.url)
        guard let freshPane = backend.primaryPaneSnapshot(named: sessionName), !freshPane.isDead,
              freshPane.paneID == pane.paneID, freshPane.rootPID == pane.rootPID else {
            throw ResolutionError.changed
        }
        let second = try inspect(pane: freshPane, inspector: inspector)
        guard first.root == second.root, first.writer == second.writer, first.url == second.url,
              try transcriptID(second.url) == id else { throw ResolutionError.changed }
        return CodexTerminalConversation(paneID: pane.paneID, root: first.root, writer: first.writer,
                                         conversationID: id, transcriptURL: first.url)
    }

    private static func inspect(pane: TmuxPaneSnapshot, inspector: any CodexTUIProcessInspecting) throws
        -> (root: AgentProcessIdentity, writer: AgentProcessIdentity, url: URL) {
        let tree: [CodexTUIProcess]
        do { tree = try inspector.tree(rootPID: Int32(pane.rootPID)) }
        catch { throw ResolutionError.unavailable }
        guard let root = tree.first(where: { $0.identity.pid == pane.rootPID }) else { throw ResolutionError.unavailable }
        let writers = tree.filter(\.isCodex)
        guard writers.count == 1, let writer = writers.first else { throw ResolutionError.ambiguous }
        let rollouts = Set(writer.openRollouts.compactMap { path -> URL? in
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" else { return nil }
            return url
        })
        guard rollouts.count == 1, let url = rollouts.first else { throw ResolutionError.ambiguous }
        return (root.identity, writer.identity, url)
    }

    private static func transcriptID(_ url: URL) throws -> String {
        guard let file = try? FileHandle(forReadingFrom: url) else { throw ResolutionError.unavailable }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: 65_536), let newline = bytes.firstIndex(of: 10),
              let row = (try? JSONSerialization.jsonObject(with: Data(bytes.prefix(upTo: newline)))) as? [String: Any],
              row["type"] as? String == "session_meta", let payload = row["payload"] as? [String: Any] else {
            throw ResolutionError.invalidTranscript
        }
        let ids = [payload["id"] as? String, payload["session_id"] as? String].compactMap { $0 }
        guard let id = ids.first, !id.isEmpty, ids.allSatisfy({ $0 == id }) else { throw ResolutionError.invalidTranscript }
        return id
    }
}
