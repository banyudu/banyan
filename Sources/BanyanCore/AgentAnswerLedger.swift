import Foundation

/// A semantic answer to a blocked agent, as posted by a delivery target.
public struct AgentAnswerRequest: Sendable, Equatable {
    /// 1-based index from the `/output` that produced `footprint`.
    public let option: Int?
    public let choice: AgentPromptChoice?
    /// Accepts whichever option the agent has highlighted.
    public let confirm: Bool
    /// The `footprint` of the prompt the human was shown.
    public let footprint: String

    public init(option: Int? = nil, choice: AgentPromptChoice? = nil, confirm: Bool = false, footprint: String) {
        self.option = option
        self.choice = choice
        self.confirm = confirm
        self.footprint = footprint
    }
}

public enum AgentAnswerRejection: String, Sendable, Equatable, Codable {
    /// The pane no longer shows the prompt the answer was written against.
    case stalePrompt = "stale_prompt"
    /// This exact prompt was already answered; the platform redelivered the tap.
    case alreadyConsumed = "already_consumed"
    /// The supervisor does not currently report the session as awaiting a human.
    case notBlocked = "not_blocked"
    /// Nothing in the pane parsed as a prompt, so there is nothing to answer.
    case noPrompt = "no_prompt"
    /// No option, or more than one option, matched the requested `choice`.
    case unmatchedChoice = "unmatched_choice"
    case invalidOption = "invalid_option"
    /// Zero or several of `option` / `choice` / `confirm` were supplied.
    case ambiguousRequest = "ambiguous_request"

    public var httpStatus: Int {
        switch self {
        case .stalePrompt, .alreadyConsumed: return 409
        case .notBlocked, .noPrompt: return 409
        case .unmatchedChoice, .invalidOption, .ambiguousRequest: return 400
        }
    }

    public var message: String {
        switch self {
        case .stalePrompt: return "the pane no longer shows the prompt this answer was written for"
        case .alreadyConsumed: return "this prompt was already answered"
        case .notBlocked: return "the session is not waiting on a human"
        case .noPrompt: return "no prompt could be read from the pane"
        case .unmatchedChoice: return "no single option matched the requested choice"
        case .invalidOption: return "option is outside the prompt's option list"
        case .ambiguousRequest: return "provide exactly one of option, choice or confirm"
        }
    }
}

public enum AgentAnswerDecision: Sendable, Equatable {
    case send(keys: [TmuxKey], option: AgentPromptOption)
    case reject(AgentAnswerRejection)
}

/// Decides whether an answer may reach a pane, and remembers the ones that did.
///
/// Two independent guards, because a delivery target is slow and chatty in
/// different ways:
///
/// - **Staleness.** The answer carries the `footprint` of the prompt its human
///   was shown. It is re-derived from a capture taken now, and a mismatch means
///   the agent moved on — the tap would answer a question nobody read. This is
///   the failure that matters: the next dialog is often a *different* command
///   behind the same "Do you want to proceed?".
/// - **Idempotency.** Chat platforms redeliver actions. A footprint already
///   consumed for a session is refused rather than replayed.
///
/// The consumed entry is dropped as soon as any observation shows the pane on a
/// different prompt, so an agent that genuinely asks the same question twice is
/// answerable the second time — it just has to have moved in between.
public struct AgentAnswerLedger: Sendable {
    private var consumedFootprints: [String: String] = [:]

    public init() {}

    /// Records what a session is currently showing, retiring a consumed footprint
    /// once the pane has moved off it.
    public mutating func note(sessionID: String, observedFootprint: String?) {
        guard let consumed = consumedFootprints[sessionID] else { return }
        if consumed != observedFootprint {
            consumedFootprints[sessionID] = nil
        }
    }

    public mutating func decide(
        sessionID: String,
        request: AgentAnswerRequest,
        observedStatus: SessionStatus,
        observedPrompt: AgentPrompt?
    ) -> AgentAnswerDecision {
        note(sessionID: sessionID, observedFootprint: observedPrompt?.footprint)

        let forms = [request.option != nil, request.choice != nil, request.confirm].filter { $0 }
        guard forms.count == 1 else { return .reject(.ambiguousRequest) }
        guard observedStatus.isAwaitingHumanAnswer else { return .reject(.notBlocked) }
        // Every `/answer` is footprint-guarded, including `confirm`. A caller with
        // an unparseable prompt is meant to fall back to `/input`, which is the
        // explicit raw path — not to a guardless shortcut wearing this route's name.
        guard let prompt = observedPrompt else { return .reject(.noPrompt) }
        guard prompt.footprint == request.footprint else { return .reject(.stalePrompt) }
        guard consumedFootprints[sessionID] != prompt.footprint else { return .reject(.alreadyConsumed) }

        let target: AgentPromptOption
        if let index = request.option {
            guard let option = prompt.options.first(where: { $0.index == index }) else {
                return .reject(.invalidOption)
            }
            target = option
        } else if let choice = request.choice {
            guard let option = AgentPromptAnswer.option(for: choice, in: prompt) else {
                return .reject(.unmatchedChoice)
            }
            target = option
        } else {
            guard let option = prompt.options.first(where: { $0.index == prompt.selectedIndex }) else {
                return .reject(.invalidOption)
            }
            target = option
        }

        guard let keys = AgentPromptAnswer.keystrokes(selecting: target.index, in: prompt) else {
            return .reject(.invalidOption)
        }
        consumedFootprints[sessionID] = prompt.footprint
        return .send(keys: keys, option: target)
    }

    public mutating func forget(sessionID: String) {
        consumedFootprints[sessionID] = nil
    }

    public func consumedFootprint(sessionID: String) -> String? {
        consumedFootprints[sessionID]
    }
}
