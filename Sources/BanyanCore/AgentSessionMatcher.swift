import Foundation

public struct AgentSessionMatchInput: Equatable, Sendable {
    public let id: String
    public let cwd: String
    public let createdAt: Date
    public let resetAt: Date?
    public let provider: CodingAgentProvider?

    public init(
        id: String,
        cwd: String,
        createdAt: Date,
        resetAt: Date?,
        provider: CodingAgentProvider?
    ) {
        self.id = id
        self.cwd = cwd
        self.createdAt = createdAt
        self.resetAt = resetAt
        self.provider = provider
    }
}

/// Matches live sessions to imported coding-agent history without frontend
/// state or presentation concerns.
public enum AgentSessionMatcher {
    public static func participatesInLiveAgentMatch(
        isImportedHistory: Bool,
        status: SessionStatus,
        provider: CodingAgentProvider?
    ) -> Bool {
        guard !isImportedHistory, status != .closed else { return false }
        guard let provider else { return true }
        return [.claude, .codex].contains(provider)
    }

    public static func bestPromptTitleMatch(
        sessionCWD: String,
        sessionCreatedAt: Date,
        sessionResetAt: Date?,
        provider: CodingAgentProvider?,
        in candidates: [ImportedAgentSession]
    ) -> ImportedAgentSession? {
        let normalizedCWD = PathDisplayName.canonicalPath(sessionCWD)
        let matchWindow: TimeInterval = 5 * 60
        let resetWindow: TimeInterval = 30
        let matchingCandidates = candidates.filter {
            (provider == nil || $0.provider == provider)
                && PathDisplayName.canonicalPath($0.cwd) == normalizedCWD
        }

        if let sessionResetAt {
            return matchingCandidates
                .filter { $0.updatedAt >= sessionResetAt.addingTimeInterval(-resetWindow) }
                .max { $0.updatedAt < $1.updatedAt }
        }

        return matchingCandidates
            .filter { abs($0.createdAt.timeIntervalSince(sessionCreatedAt)) <= matchWindow }
            .min {
                abs($0.createdAt.timeIntervalSince(sessionCreatedAt))
                    < abs($1.createdAt.timeIntervalSince(sessionCreatedAt))
            }
    }

    public static func bestHistoryResumeMatch(
        sessionCWD: String,
        sessionCreatedAt: Date,
        sessionUpdatedAt: Date,
        sessionResetAt: Date?,
        provider: CodingAgentProvider?,
        in candidates: [ImportedAgentSession]
    ) -> ImportedAgentSession? {
        if let strictMatch = bestPromptTitleMatch(
            sessionCWD: sessionCWD,
            sessionCreatedAt: sessionCreatedAt,
            sessionResetAt: sessionResetAt,
            provider: provider,
            in: candidates
        ) {
            return strictMatch
        }

        let normalizedCWD = PathDisplayName.canonicalPath(sessionCWD)
        return candidates
            .filter {
                (provider == nil || $0.provider == provider)
                    && PathDisplayName.canonicalPath($0.cwd) == normalizedCWD
            }
            .min {
                let lhsDistance = abs($0.updatedAt.timeIntervalSince(sessionUpdatedAt))
                let rhsDistance = abs($1.updatedAt.timeIntervalSince(sessionUpdatedAt))
                if lhsDistance == rhsDistance {
                    return $0.updatedAt > $1.updatedAt
                }
                return lhsDistance < rhsDistance
            }
    }

    public static func bestPromptTitleAssignments(
        for sessions: [AgentSessionMatchInput],
        in candidates: [ImportedAgentSession]
    ) -> [String: ImportedAgentSession] {
        struct Pair {
            let candidate: ImportedAgentSession
            let score: TimeInterval
        }

        let optionsBySessionID = Dictionary(uniqueKeysWithValues: sessions.map { session in
            let options = promptTitleMatchCandidates(for: session, in: candidates).map { candidate in
                Pair(
                    candidate: candidate,
                    score: promptTitleMatchScore(session: session, candidate: candidate)
                )
            }.sorted {
                if $0.score == $1.score {
                    return $0.candidate.updatedAt > $1.candidate.updatedAt
                }
                return $0.score < $1.score
            }
            return (session.id, options)
        })
        let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let orderedSessionIDs = sessions
            .filter { optionsBySessionID[$0.id]?.isEmpty == false }
            .sorted {
                let lhsCount = optionsBySessionID[$0.id]?.count ?? 0
                let rhsCount = optionsBySessionID[$1.id]?.count ?? 0
                if lhsCount == rhsCount {
                    return $0.createdAt < $1.createdAt
                }
                return lhsCount < rhsCount
            }
            .map(\.id)

        var sessionIDByCandidateID: [String: String] = [:]

        func assign(_ sessionID: String, visitedCandidateIDs: inout Set<String>) -> Bool {
            guard let options = optionsBySessionID[sessionID] else { return false }
            for pair in options {
                let candidateID = pair.candidate.id
                guard !visitedCandidateIDs.contains(candidateID) else { continue }
                visitedCandidateIDs.insert(candidateID)

                if let displacedSessionID = sessionIDByCandidateID[candidateID],
                   !assign(displacedSessionID, visitedCandidateIDs: &visitedCandidateIDs) {
                    continue
                }

                sessionIDByCandidateID[candidateID] = sessionID
                return true
            }
            return false
        }

        for sessionID in orderedSessionIDs {
            var visitedCandidateIDs = Set<String>()
            _ = assign(sessionID, visitedCandidateIDs: &visitedCandidateIDs)
        }

        var result: [String: ImportedAgentSession] = [:]
        for (candidateID, sessionID) in sessionIDByCandidateID {
            if let candidate = candidateByID[candidateID] {
                result[sessionID] = candidate
            }
        }
        return result
    }

    private static func promptTitleMatchCandidates(
        for session: AgentSessionMatchInput,
        in candidates: [ImportedAgentSession]
    ) -> [ImportedAgentSession] {
        let normalizedCWD = PathDisplayName.canonicalPath(session.cwd)
        let matchWindow: TimeInterval = 5 * 60
        let resetWindow: TimeInterval = 30
        let matchingCandidates = candidates.filter {
            (session.provider == nil || $0.provider == session.provider)
                && PathDisplayName.canonicalPath($0.cwd) == normalizedCWD
        }

        if let resetAt = session.resetAt {
            return matchingCandidates.filter {
                $0.updatedAt >= resetAt.addingTimeInterval(-resetWindow)
            }
        }

        return matchingCandidates.filter {
            abs($0.createdAt.timeIntervalSince(session.createdAt)) <= matchWindow
        }
    }

    private static func promptTitleMatchScore(
        session: AgentSessionMatchInput,
        candidate: ImportedAgentSession
    ) -> TimeInterval {
        if session.resetAt != nil {
            return -candidate.updatedAt.timeIntervalSinceReferenceDate
        }
        return abs(candidate.createdAt.timeIntervalSince(session.createdAt))
    }
}
