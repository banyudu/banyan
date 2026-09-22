import Foundation

/// A proposal pushed into a running Banyan app from outside it, parked until a
/// human approves or dismisses it.
///
/// Every other control route acts immediately; this is the one that waits. It
/// exists so the *policy* behind a nudge — which issue has gone stale, whose SLA
/// is about to breach — can stay in the script that already computes it, while
/// Banyan owns only the interaction: render it, capture the decision, and run the
/// command on approval.
///
/// The payload is deliberately provider-agnostic: an opaque `command` plus an
/// opaque `target`. The same route can suggest a Linear issue today and a pull
/// request review tomorrow without the app learning either.
public struct InboundSuggestion: Identifiable, Equatable, Sendable {
    /// How long a suggestion stays live when the caller does not say.
    /// A picker on a 15-minute cron therefore raises any given nudge at most
    /// once an hour.
    public static let defaultTTL: TimeInterval = 60 * 60
    public static let minimumTTL: TimeInterval = 60
    public static let maximumTTL: TimeInterval = 24 * 60 * 60

    public let id: UUID
    /// Dedup key: two suggestions sharing it are the same nudge, so the second is
    /// refused while the first is still live. Defaults to `target`, then to the
    /// command. A caller that keys on the issue id alone collapses every kind of
    /// nudge about that issue into one; `<kind>:<issue>` keeps them separate.
    public let key: String
    public let title: String
    /// Why this is worth attention, e.g. "In Review for 6 days, no reviewer".
    public let detail: String?
    /// Opaque subject — an issue id, a URL. Expanded into the command's
    /// `{{target}}` placeholders on approval, and shown so the human knows what
    /// the suggestion is about.
    public let target: String?
    /// The shell command to run once the human approves. It runs at no other
    /// time; an inbound suggestion never executes anything by itself.
    public let command: String
    /// Where to run it. Absent means the selected session's directory, the same
    /// default a palette command gets.
    public let cwd: String?
    public let run: CommandRunMode
    public let receivedAt: Date
    /// When this suggestion stops holding the pending slot and its key stops
    /// being suppressed.
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        key: String? = nil,
        title: String,
        detail: String? = nil,
        target: String? = nil,
        command: String,
        cwd: String? = nil,
        run: CommandRunMode = .session,
        receivedAt: Date = Date(),
        ttl: TimeInterval? = nil
    ) {
        self.id = id
        self.title = SessionInputPolicy.normalizedOptionalText(title) ?? title
        self.detail = SessionInputPolicy.normalizedOptionalText(detail)
        self.target = SessionInputPolicy.normalizedOptionalText(target)
        self.command = SessionInputPolicy.normalizedOptionalText(command) ?? command
        self.cwd = SessionInputPolicy.normalizedOptionalText(cwd)
        self.run = run
        self.receivedAt = receivedAt
        self.key = SessionInputPolicy.normalizedOptionalText(key)
            ?? SessionInputPolicy.normalizedOptionalText(target)
            ?? self.command
        let requested = ttl ?? Self.defaultTTL
        let clamped = min(max(requested, Self.minimumTTL), Self.maximumTTL)
        self.expiresAt = receivedAt.addingTimeInterval(clamped)
    }
}

/// The app's single pending-suggestion slot plus the dedup window that keeps a
/// cron firing every fifteen minutes from re-raising the same nudge.
///
/// One TTL governs both effects: while a suggestion is live it holds the slot,
/// and its key is refused. Approving or dismissing frees the slot immediately but
/// leaves the key suppressed until it expires — acting on a nudge must not invite
/// the next tick to repeat it.
///
/// Nothing here runs on a timer. Expiry is evaluated when the next suggestion
/// arrives, which is the only moment it can change an answer; a suggestion that
/// outlived its TTL stays on screen and stays actionable until something replaces
/// it or the human answers it.
public struct SuggestionInbox: Sendable {
    /// Why a suggestion was refused. Both are ordinary outcomes for a scheduled
    /// picker, not errors in its invocation.
    public enum Rejection: String, Sendable, Equatable {
        /// This key was already delivered and is still inside its TTL.
        case duplicate = "duplicate_suggestion"
        /// A different suggestion is still waiting on the human.
        case slotBusy = "suggestion_pending"

        public var message: String {
            switch self {
            case .duplicate:
                return "a suggestion with this key was already delivered and has not expired yet"
            case .slotBusy:
                return "another suggestion is still waiting for a decision"
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case accepted(InboundSuggestion)
        case rejected(Rejection)
    }

    /// Past this many remembered keys the soonest-expiring are forgotten. A long
    /// uptime with a busy picker should cost a bounded amount of memory; the only
    /// consequence of forgetting a key early is that its nudge may be raised
    /// again sooner than its TTL asked for.
    public static let maximumSuppressedKeys = 256

    public private(set) var pending: InboundSuggestion?
    private(set) var suppressedUntil: [String: Date] = [:]

    public init() {}

    /// Offers a suggestion for the pending slot.
    ///
    /// Expired state is cleared first, so a caller that reads `pending` after this
    /// returns sees the truth whether the offer was accepted or refused.
    public mutating func offer(_ suggestion: InboundSuggestion, now: Date = Date()) -> Outcome {
        prune(now: now)
        if suppressedUntil[suggestion.key] != nil {
            return .rejected(.duplicate)
        }
        if pending != nil {
            return .rejected(.slotBusy)
        }
        pending = suggestion
        suppressedUntil[suggestion.key] = suggestion.expiresAt
        capSuppressedKeys()
        return .accepted(suggestion)
    }

    /// Frees the slot once the human has answered. The key stays suppressed for
    /// the rest of its TTL, so answering does not re-open the door to the same
    /// nudge.
    @discardableResult
    public mutating func resolve(id: UUID) -> InboundSuggestion? {
        guard let answered = pending, answered.id == id else { return nil }
        pending = nil
        return answered
    }

    /// Drops the pending suggestion and every suppressed key that has outlived
    /// its TTL.
    private mutating func prune(now: Date) {
        suppressedUntil = suppressedUntil.filter { $0.value > now }
        if let pending, pending.expiresAt <= now {
            self.pending = nil
        }
    }

    private mutating func capSuppressedKeys() {
        guard suppressedUntil.count > Self.maximumSuppressedKeys else { return }
        var kept = suppressedUntil
            .sorted { $0.value > $1.value }
            .prefix(Self.maximumSuppressedKeys)
            .reduce(into: [String: Date]()) { $0[$1.key] = $1.value }
        // The suggestion currently on screen keeps its suppression regardless of
        // where its expiry sorts, so the slot it holds and the key it reserves
        // never disagree.
        if let pendingKey = pending?.key, kept[pendingKey] == nil {
            kept[pendingKey] = suppressedUntil[pendingKey]
        }
        suppressedUntil = kept
    }
}
