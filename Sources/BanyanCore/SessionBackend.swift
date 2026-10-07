import Foundation

/// The runtime that owns a session's agent. Frontends present every session the
/// same way; only starting, observing, and closing the backing work differ.
public enum SessionBackendKind: String, Codable, Sendable, CaseIterable {
    /// A command in a dedicated tmux session, rendered by a terminal client.
    case terminal
    /// Durable state in the local `puckd`, shared with other frontends such as
    /// Slack. Banyan attaches to it; it does not own the process.
    case puck
    /// A thread on the Banyan-owned Codex App Server.
    case codex
}

/// The model runtime a puck session runs on. Persisted with the row so the
/// sidebar keeps its identity, and "new session with the same model" still
/// works, while `puckd` is unavailable.
public struct PuckSessionBinding: Codable, Equatable, Hashable, Sendable {
    /// puck's provider name: `codex`, `opencode-go`, `anthropic`, or `gemini`.
    public let provider: String
    /// A label in puck's own account store. `nil` lets the daemon choose.
    public let account: String?
    /// `nil` lets the daemon choose the provider's default model.
    public let model: String?

    public init(provider: String, account: String? = nil, model: String? = nil) {
        self.provider = provider
        self.account = account.flatMap(Self.nonEmpty)
        self.model = model.flatMap(Self.nonEmpty)
    }

    public init(summary: PuckSessionSummary) {
        self.init(provider: summary.provider, account: summary.account, model: summary.model)
    }

    /// The providers `puckd` runs, in the order a picker lists them.
    public static let providers = ["codex", "opencode-go", "anthropic", "gemini"]

    /// Billed API providers have no default account or model to fall back on,
    /// so a session on one must name both.
    public static func requiresAccountAndModel(provider: String) -> Bool {
        provider == "anthropic" || provider == "gemini"
    }

    /// Why `puckd` would refuse this binding, or `nil` when it is complete.
    public var validationError: String? {
        guard Self.providers.contains(provider) else {
            return "puck provider must be \(Self.providers.formatted(.list(type: .or)))"
        }
        if Self.requiresAccountAndModel(provider: provider), account == nil || model == nil {
            return "\(provider) puck sessions require a model and an account"
        }
        return nil
    }

    /// Banyan's icon vocabulary for this runtime. OpenCode Go routes several
    /// vendors' models, so its model ID decides the brand, as it does for a
    /// terminal OpenCode session.
    public var agentProvider: CodingAgentProvider {
        switch provider {
        case "codex":
            return .codex
        case "anthropic":
            return .claude
        case "gemini":
            return .gemini
        default:
            return model.flatMap { CodingAgentProvider.runtimeProvider(modelID: $0, providerID: nil) }
                ?? .opencode
        }
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Maps a daemon session summary onto the status vocabulary the terminal
/// supervisor uses, so the sidebar, attention chord, and notifications treat
/// both backends alike.
public enum PuckSessionStatusPolicy {
    public static func status(
        position: String,
        historyItems: Int,
        hasPendingApproval: Bool,
        hasPendingQuestion: Bool
    ) -> SessionStatus {
        // A parked turn is waiting on exactly one of these; either is a question
        // the user has to answer before the agent can continue.
        if hasPendingApproval || hasPendingQuestion {
            return .asking
        }
        switch position {
        case "running":
            return .executing
        case "parked":
            return .asking
        case "interrupted":
            // A daemon restart cut the turn off; its tool effects may need a look.
            return .failed
        default:
            // `idle` and `hibernated` are the same to a user: the agent waits for
            // the next prompt. Like a terminal agent, a session with a finished
            // turn has a result to read, while an untouched one does not.
            return historyItems > 0 ? .needInput : .idle
        }
    }

    public static func status(for summary: PuckSessionSummary) -> SessionStatus {
        status(
            position: summary.position,
            historyItems: summary.historyItems,
            hasPendingApproval: summary.pendingApproval != nil,
            hasPendingQuestion: summary.pendingQuestion != nil
        )
    }

    public static func tone(for status: SessionStatus) -> SessionTone {
        switch status {
        case .asking, .needInput: return .yellow
        case .failed: return .red
        case .idle: return .neutral
        default: return .blue
        }
    }
}
