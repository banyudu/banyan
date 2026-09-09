import Foundation

/// A branch a missing worktree could be restored onto.
public struct WorktreeBranchCandidate: Sendable, Equatable {
    /// Local branch name to check out, e.g. `yudu/eng-1234-abc123`.
    public let name: String
    /// Ref to start from: the branch itself when it exists locally, otherwise a
    /// remote-tracking ref such as `origin/yudu/eng-1234-abc123`.
    public let ref: String
    public let isRemote: Bool

    public init(name: String, ref: String, isRemote: Bool) {
        self.name = name
        self.ref = ref
        self.isRemote = isRemote
    }
}

public struct WorktreeRecoveryPlan: Sendable, Equatable {
    public let worktreePath: String
    public let branch: String
    /// Non-nil when the local branch does not exist yet and must be created from
    /// this start point.
    public let startPoint: String?
    /// How the branch was determined, for reporting it back to the user.
    public let source: Source

    public enum Source: Sendable, Equatable {
        /// Git still has the worktree registered, so the branch is exact.
        case registered
        /// Recovered from a branch Banyan recorded while the session was live.
        case recorded
        /// Inferred from the directory name. Correct for the naming convention,
        /// but a worktree whose branch changed after creation keeps its original
        /// directory name — so this can name a real but different branch.
        case inferred(tier: Int)
    }

    public init(worktreePath: String, branch: String, startPoint: String?, source: Source) {
        self.worktreePath = worktreePath
        self.branch = branch
        self.startPoint = startPoint
        self.source = source
    }
}

public enum WorktreeRecoveryResolution: Sendable, Equatable {
    case plan(WorktreeRecoveryPlan)
    /// Several branches fit the directory name equally well. Picking one would
    /// be a coin flip, so the caller offers the choice instead.
    case ambiguous([String])
    case noCandidate
}

/// Works out which branch a deleted worktree directory belonged to.
///
/// Worktree directories are named after their branch with `/` replaced by `-`,
/// so the name is usually enough to find the branch again — but only as a way to
/// *match* branches that actually exist. Deriving a name and checking it out
/// blind would invent branches; every rule here filters the real branch list.
///
/// Measured against 37 live worktrees in a repository using this convention:
/// 36 resolved to the right branch, 0 were ambiguous, and 1 resolved to a real
/// but different branch because that worktree had been moved onto a new branch
/// after it was created. Callers must report the branch they restored so that
/// case is visible rather than silent.
public enum WorktreeRecoveryPolicy {
    public static func resolve(
        worktreePath: String,
        recordedBranch: String?,
        registeredBranch: String?,
        candidates: [WorktreeBranchCandidate]
    ) -> WorktreeRecoveryResolution {
        // Git's own record beats any inference from the name.
        if let registeredBranch, !registeredBranch.isEmpty {
            return resolution(
                for: registeredBranch,
                worktreePath: worktreePath,
                candidates: candidates,
                source: .registered
            )
        }
        if let recordedBranch, !recordedBranch.isEmpty {
            return resolution(
                for: recordedBranch,
                worktreePath: worktreePath,
                candidates: candidates,
                source: .recorded
            )
        }

        let directoryName = URL(fileURLWithPath: worktreePath).lastPathComponent
        guard !directoryName.isEmpty else { return .noCandidate }

        for tier in 1...3 {
            let tierMatches = candidates.filter {
                matches($0.name, directoryName: directoryName, tier: tier)
            }
            guard !tierMatches.isEmpty else { continue }
            // A branch present both locally and on a remote is one branch; and a
            // local checkout is what the worktree had, so it wins outright.
            let preferred = tierMatches.contains { !$0.isRemote }
                ? tierMatches.filter { !$0.isRemote }
                : tierMatches
            let names = Set(preferred.map(\.name))
            guard names.count == 1, let candidate = preferred.first else {
                return .ambiguous(names.sorted())
            }
            return .plan(
                WorktreeRecoveryPlan(
                    worktreePath: worktreePath,
                    branch: candidate.name,
                    startPoint: candidate.isRemote ? candidate.ref : nil,
                    source: .inferred(tier: tier)
                )
            )
        }
        return .noCandidate
    }

    private static func resolution(
        for branch: String,
        worktreePath: String,
        candidates: [WorktreeBranchCandidate],
        source: WorktreeRecoveryPlan.Source
    ) -> WorktreeRecoveryResolution {
        let matching = candidates.filter { $0.name == branch }
        // A local branch needs no start point; a remote-only one is created from
        // its tracking ref. A branch that exists nowhere cannot be restored.
        guard let candidate = matching.first(where: { !$0.isRemote }) ?? matching.first else {
            return .noCandidate
        }
        return .plan(
            WorktreeRecoveryPlan(
                worktreePath: worktreePath,
                branch: candidate.name,
                startPoint: candidate.isRemote ? candidate.ref : nil,
                source: source
            )
        )
    }

    /// Tier 1 is the naming convention itself. Tiers 2 and 3 cover the ways
    /// directory names drift from it in practice: dropping the owner prefix, and
    /// keeping a short suffix where the branch carries a descriptive slug. Each
    /// tier is only consulted when the stricter ones found nothing.
    private static func matches(_ branch: String, directoryName: String, tier: Int) -> Bool {
        switch tier {
        case 1:
            return encoded(branch) == directoryName
        case 2:
            return encoded(branch).hasSuffix("-\(directoryName)")
                || encoded(branch.split(separator: "/").last.map(String.init) ?? branch) == directoryName
        default:
            guard let directoryIssue = LinearIssueReference.issueID(in: directoryName) else { return false }
            return LinearIssueReference.issueID(in: branch)?.caseInsensitiveCompare(directoryIssue) == .orderedSame
        }
    }

    public static func encoded(_ branch: String) -> String {
        branch.replacingOccurrences(of: "/", with: "-")
    }
}
