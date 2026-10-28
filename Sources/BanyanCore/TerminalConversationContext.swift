import Foundation

/// Stable conversation identity to bind a Slack thread to one runtime.
public struct SlackConversationIdentity: Codable, Hashable, Sendable {
    public let kind: String
    public let conversationID: String
    public let generation: String

    public init(kind: String, conversationID: String, generation: String) {
        self.kind = kind; self.conversationID = conversationID; self.generation = generation
    }
}

/// Assigns a new opaque generation after a reset, replacement, or rewrite.
public protocol ConversationGenerationTracking: Sendable {
    func identity(sessionID: String, conversationID: String, proof: ConversationHistoryReader.Proof) async throws -> SlackConversationIdentity
}

/// Useful for isolated readers. The app injects a durable tracker instead.
public actor TransientConversationGenerationTracker: ConversationGenerationTracking {
    private struct Key: Hashable { let sessionID: String; let conversationID: String }
    private struct Record { let proof: ConversationHistoryReader.Proof; let generation: String }
    private var records: [Key: Record] = [:]
    private var order: [Key] = []

    public init() {}
    public func identity(sessionID: String, conversationID: String, proof: ConversationHistoryReader.Proof) async throws -> SlackConversationIdentity {
        let key = Key(sessionID: sessionID, conversationID: conversationID)
        let prior = records[key]
        let same = prior.map { old in
            old.proof.deviceNumber == proof.deviceNumber && old.proof.fileNumber == proof.fileNumber &&
            old.proof.resetCount == proof.resetCount && proof.bytes.starts(with: old.proof.bytes)
        } ?? false
        let generation = same ? prior!.generation : UUID().uuidString
        records[key] = Record(proof: proof, generation: generation)
        order.removeAll { $0 == key }; order.append(key)
        while order.count > 8 { records.removeValue(forKey: order.removeFirst()) }
        return SlackConversationIdentity(kind: "terminalCodex", conversationID: conversationID, generation: generation)
    }
}

/// Reads on demand without starting, resuming, or writing to an agent. The
/// caller must still recheck its own authorization and row identity after the
/// await, before returning or publishing the result.
public protocol TerminalConversationContextReading: Sendable {
    func read(sessionID: String, sessionName: String, provider: CodingAgentProvider?,
              earlier: String?, limit: Int, terminalOutput: Bool) async throws -> TerminalConversationContextReader.Context
}

public actor TerminalConversationContextReader: TerminalConversationContextReading {
    public enum Source: String, Codable, Sendable { case providerTranscript, terminalOutput, unavailable }
    public struct Context: Sendable {
        public let source: Source
        public let conversationID: String?
        public let binding: SlackConversationIdentity?
        public let messages: [ConversationHistoryReader.Message]
        public let earlier: String?
        public let output: String?
        public let limitation: String?
        public let truncated: Bool
        public let mayBeStale: Bool
    }
    public enum ContextError: Error, Equatable { case changed, invalidCursor }

    private let backend: any TmuxSessionBackend
    private let inspector: any CodexTUIProcessInspecting
    private let history: ConversationHistoryReader
    private let generations: any ConversationGenerationTracking
    private var bindings: [UUID: SlackConversationIdentity] = [:]
    private var bindingOrder: [UUID] = []

    public init(backend: any TmuxSessionBackend, inspector: any CodexTUIProcessInspecting,
                history: ConversationHistoryReader = ConversationHistoryReader(),
                generations: any ConversationGenerationTracking = TransientConversationGenerationTracker()) {
        self.backend = backend; self.inspector = inspector; self.history = history; self.generations = generations
    }

    public func read(sessionID: String, sessionName: String, provider: CodingAgentProvider?,
                     earlier: String? = nil, limit: Int = 20, terminalOutput: Bool = false) async throws -> Context {
        guard !sessionID.isEmpty, !sessionName.isEmpty else { throw ContextError.changed }
        if terminalOutput {
            guard earlier == nil else { throw ContextError.invalidCursor }
            return await fallback(sessionName: sessionName, limitation: "Retained terminal output; older conversation history may be unavailable.")
        }
        guard provider == .codex else {
            guard earlier == nil else { throw ContextError.invalidCursor }
            return await fallback(sessionName: sessionName, limitation: "Exact provider transcript identity is unavailable; showing retained terminal output.")
        }
        let backend = self.backend, inspector = self.inspector
        let initial = await Task.detached(priority: .userInitiated) {
            try? CodexTerminalConversationResolver.resolve(sessionName: sessionName, backend: backend, inspector: inspector)
        }.value
        guard let initial else {
            guard earlier == nil else { throw ContextError.changed }
            return await fallback(sessionName: sessionName, limitation: "Exact provider transcript identity is unavailable or ambiguous; showing retained terminal output.")
        }
        let page: ConversationHistoryReader.Page
        do {
            page = try await history.page(identity: initial.historyIdentity(sessionID: sessionID), earlier: earlier, limit: limit)
        } catch {
            if earlier != nil { throw ContextError.changed }
            return await fallback(sessionName: sessionName, limitation: "Provider history is unavailable or changed; showing retained terminal output.")
        }
        var binding: SlackConversationIdentity?
        if earlier == nil, let proof = page.proof {
            binding = try? await generations.identity(sessionID: sessionID, conversationID: initial.conversationID, proof: proof)
            if let binding {
                bindings[page.snapshotID] = binding; bindingOrder.append(page.snapshotID)
                while bindingOrder.count > 8 { bindings.removeValue(forKey: bindingOrder.removeFirst()) }
            }
        } else if earlier != nil {
            binding = bindings[page.snapshotID]
        }
        if binding == nil {
            // Keep recent history readable even when its full generation cannot
            // be established; this pane-only binding never authorizes input.
            let fallbackContext = await fallback(sessionName: sessionName, limitation: "Conversation generation is unavailable.")
            let pane = Self.paneBinding(paneID: initial.paneID, root: initial.root)
            guard fallbackContext.binding == pane else { throw ContextError.changed }
            // The full generation is unknown. Tie this read-only binding to
            // the verified snapshot window, so changed content cannot be
            // published through the old thread as a different conversation.
            let paneBinding = SlackConversationIdentity(kind: pane.kind, conversationID: pane.conversationID,
                                                         generation: pane.generation + ":" + page.windowDigest)
            binding = paneBinding
            if bindings[page.snapshotID] == nil {
                bindings[page.snapshotID] = paneBinding; bindingOrder.append(page.snapshotID)
                while bindingOrder.count > 8 { bindings.removeValue(forKey: bindingOrder.removeFirst()) }
            }
        }
        let current = await Task.detached(priority: .userInitiated) {
            try? CodexTerminalConversationResolver.resolve(sessionName: sessionName, backend: backend, inspector: inspector)
        }.value
        guard current == initial else { throw ContextError.changed }
        do { try await history.revalidate(identity: initial.historyIdentity(sessionID: sessionID), snapshotID: page.snapshotID) }
        catch { throw ContextError.changed }
        let limitation: String?
        if page.incompleteTail { limitation = "The transcript is still being written; the incomplete record is omitted. Replies are disabled until its identity is verified." }
        else if binding?.kind == "terminalPane" { limitation = "The full conversation generation could not be verified. History is limited and replies are disabled." }
        else { limitation = nil }
        return Context(source: .providerTranscript, conversationID: initial.conversationID, binding: binding, messages: page.messages,
                       earlier: page.earlier, output: nil, limitation: limitation,
                       truncated: page.truncatedBefore || page.messages.contains(where: \.truncated), mayBeStale: page.incompleteTail)
    }

    private func fallback(sessionName: String, limitation: String) async -> Context {
        let backend = self.backend, inspector = self.inspector
        let output = await Task.detached(priority: .userInitiated) { () -> (String, String, AgentProcessIdentity)? in
            guard let pane = backend.primaryPaneSnapshot(named: sessionName), !pane.isDead,
                  pane.rootPID > 0, pane.rootPID <= Int(Int32.max),
                  let root = Self.rootIdentity(pane.rootPID, inspector: inspector) else { return nil }
            let text = backend.captureVisibleText(paneID: pane.paneID, lineLimit: 200)
            guard let fresh = backend.primaryPaneSnapshot(named: sessionName), !fresh.isDead,
                  fresh.paneID == pane.paneID, fresh.rootPID == pane.rootPID,
                  Self.rootIdentity(pane.rootPID, inspector: inspector) == root else { return nil }
            return (String(text.suffix(40_000)), pane.paneID, root)
        }.value
        guard let output else {
            return Context(source: .unavailable, conversationID: nil, binding: nil, messages: [], earlier: nil, output: nil,
                           limitation: "History and retained terminal output are unavailable.", truncated: false, mayBeStale: true)
        }
        // This binds only the pane process generation, not an inferred provider
        // conversation. It is deliberately read-only: remote input requires a
        // separately verified exact conversation identity.
        let binding = Self.paneBinding(paneID: output.1, root: output.2)
        guard !output.0.isEmpty else {
            return Context(source: .unavailable, conversationID: nil, binding: binding, messages: [], earlier: nil, output: nil,
                           limitation: "Retained terminal output is empty or unavailable; replies are disabled without an exact conversation identity.",
                           truncated: false, mayBeStale: true)
        }
        return Context(source: .terminalOutput, conversationID: nil, binding: binding, messages: [], earlier: nil, output: output.0,
                       limitation: limitation + " Replies are disabled without an exact conversation identity.", truncated: true, mayBeStale: true)
    }

    nonisolated private static func paneBinding(paneID: String, root: AgentProcessIdentity) -> SlackConversationIdentity {
        SlackConversationIdentity(kind: "terminalPane", conversationID: paneID,
            generation: "\(root.pid):\(root.startSeconds):\(root.startMicroseconds)")
    }

    nonisolated private static func rootIdentity(_ pid: Int, inspector: any CodexTUIProcessInspecting) -> AgentProcessIdentity? {
        if let tree = try? inspector.tree(rootPID: Int32(pid)), let root = tree.first(where: { $0.identity.pid == pid })?.identity {
            return root
        }
        // Even if provider-file inspection fails, a kernel start time can still
        // prove that the same pane process was captured twice.
        return AgentProcessSample.read(pid: Int32(pid))?.identity
    }

}
