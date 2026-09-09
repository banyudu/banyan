import BanyanCore
import Foundation

/// Recreates a git worktree whose directory was deleted while a Banyan session
/// still pointed at it.
///
/// Worktrees are removed routinely once their branch merges, which leaves the
/// session that ran there unable to start: every attach re-runs the launch
/// command in a directory that no longer exists. The conversation itself
/// usually survives — Codex and Claude key their transcripts by path, not by
/// the directory existing — so restoring the worktree is enough to make the
/// session resumable again.
///
/// Every git call is read-only except the final `worktree add`, and each is
/// bounded so a wedged git cannot hang an attach.
enum WorktreeRecovery {
    enum Failure: Error, Equatable {
        case notAWorktreePath
        case noRepository
        case ambiguousBranch([String])
        case noCandidate
        case gitFailed(String)

        var message: String {
            switch self {
            case .notAWorktreePath:
                return "This session's folder is missing and is not inside a git worktree, so Banyan cannot recreate it."
            case .noRepository:
                return "This session's folder is missing and Banyan could not find the repository it belonged to."
            case .ambiguousBranch(let branches):
                return "Several branches match this worktree's name, so Banyan did not guess: \(branches.joined(separator: ", "))."
            case .noCandidate:
                return "This session's worktree was deleted and no branch matching its name still exists, locally or on a remote."
            case .gitFailed(let detail):
                return "Recreating the worktree failed: \(detail)"
            }
        }
    }

    struct Recovered: Equatable {
        let path: String
        let branch: String
        let source: WorktreeRecoveryPlan.Source

        /// Shown to the user after an automatic recovery. Naming the branch
        /// matters: a directory keeps the name of the branch it was *created*
        /// from, so an inferred recovery can land on a real but different branch
        /// and this is what makes that visible instead of silent.
        var message: String {
            switch source {
            case .registered, .recorded:
                return "Recreated worktree \(path) on branch \(branch)."
            case .inferred:
                return "Recreated worktree \(path) on branch \(branch), matched from the folder name. "
                    + "If that is not the branch you expected, remove the worktree and recreate it by hand."
            }
        }
    }

    private static let gitTimeout: TimeInterval = 20

    /// Whether `cwd` is a path Banyan should try to restore before attaching.
    static func isRecoverable(cwd: String) -> Bool {
        !FileManager.default.fileExists(atPath: cwd)
    }

    static func recover(
        cwd: String,
        recordedBranch: String?,
        environment: [String: String]
    ) async -> Result<Recovered, Failure> {
        guard let repository = repositoryRoot(forMissingPath: cwd, environment: environment) else {
            return .failure(FileManager.default.fileExists(atPath: parentPath(of: cwd))
                ? .noRepository
                : .notAWorktreePath)
        }

        let resolution = WorktreeRecoveryPolicy.resolve(
            worktreePath: cwd,
            recordedBranch: recordedBranch,
            registeredBranch: registeredBranch(forWorktreePath: cwd, repository: repository, environment: environment),
            candidates: branchCandidates(in: repository, environment: environment)
        )

        switch resolution {
        case .ambiguous(let branches):
            return .failure(.ambiguousBranch(branches))
        case .noCandidate:
            return .failure(.noCandidate)
        case .plan(let plan):
            // A worktree git still has registered but whose directory is gone
            // blocks `worktree add` on the same path; pruning clears the record.
            _ = await git(["worktree", "prune"], cwd: repository, environment: environment)
            var arguments = ["worktree", "add"]
            if let startPoint = plan.startPoint {
                arguments += ["-b", plan.branch, plan.worktreePath, startPoint]
            } else {
                arguments += [plan.worktreePath, plan.branch]
            }
            let result = await git(arguments, cwd: repository, environment: environment)
            guard result.exitCode == 0 else {
                return .failure(.gitFailed(result.errorSummary))
            }
            return .success(Recovered(path: plan.worktreePath, branch: plan.branch, source: plan.source))
        }
    }

    /// Walks up from the missing directory to the nearest ancestor that still
    /// exists and is inside a git repository, then takes that repository's main
    /// checkout — `worktree add` has to run from a real working tree.
    private static func repositoryRoot(
        forMissingPath path: String,
        environment: [String: String]
    ) -> String? {
        var current = parentPath(of: path)
        while current != "/" && !current.isEmpty {
            if FileManager.default.fileExists(atPath: current) {
                let result = gitSync(
                    ["rev-parse", "--path-format=absolute", "--git-common-dir"],
                    cwd: current,
                    environment: environment
                )
                if result.exitCode == 0, !result.output.isEmpty {
                    // `--git-common-dir` points at the shared `.git` of the main
                    // checkout even when run from inside a linked worktree.
                    let commonDirectory = URL(fileURLWithPath: result.output)
                    return commonDirectory.lastPathComponent == ".git"
                        ? commonDirectory.deletingLastPathComponent().path
                        : commonDirectory.path
                }
            }
            current = parentPath(of: current)
        }
        return nil
    }

    private static func registeredBranch(
        forWorktreePath path: String,
        repository: String,
        environment: [String: String]
    ) -> String? {
        let result = gitSync(["worktree", "list", "--porcelain"], cwd: repository, environment: environment)
        guard result.exitCode == 0 else { return nil }
        let target = PathDisplayName.canonicalPath(path)
        var currentPath: String?
        for line in result.output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("worktree ") {
                currentPath = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch "), let currentPath,
                      PathDisplayName.canonicalPath(currentPath) == target {
                return String(line.dropFirst("branch ".count))
                    .replacingOccurrences(of: "refs/heads/", with: "")
            }
        }
        return nil
    }

    private static func branchCandidates(
        in repository: String,
        environment: [String: String]
    ) -> [WorktreeBranchCandidate] {
        let locals = gitSync(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
            cwd: repository,
            environment: environment
        )
        let remotes = gitSync(
            ["for-each-ref", "--format=%(refname:short)", "refs/remotes"],
            cwd: repository,
            environment: environment
        )
        let remoteNames = Set(
            gitSync(["remote"], cwd: repository, environment: environment)
                .output
                .split(whereSeparator: \.isNewline)
                .map(String.init)
        )

        var candidates = locals.output
            .split(whereSeparator: \.isNewline)
            .map { WorktreeBranchCandidate(name: String($0), ref: String($0), isRemote: false) }

        for line in remotes.output.split(whereSeparator: \.isNewline) {
            let ref = String(line)
            // `origin/HEAD` is a symbolic pointer, not a branch anyone works on.
            guard !ref.hasSuffix("/HEAD") else { continue }
            guard let remote = remoteNames.first(where: { ref.hasPrefix("\($0)/") }) else { continue }
            let name = String(ref.dropFirst(remote.count + 1))
            guard !name.isEmpty else { continue }
            candidates.append(WorktreeBranchCandidate(name: name, ref: ref, isRemote: true))
        }
        return candidates
    }

    private static func parentPath(of path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    private struct GitResult {
        let exitCode: Int32
        let output: String
        let errorSummary: String
    }

    private static func git(
        _ arguments: [String],
        cwd: String,
        environment: [String: String]
    ) async -> GitResult {
        do {
            let output = try await SubprocessRunner.runAsync(
                arguments: ["git", "-C", cwd] + arguments,
                cwd: cwd,
                environment: environment,
                timeout: gitTimeout
            )
            return makeResult(output)
        } catch {
            return GitResult(exitCode: -1, output: "", errorSummary: error.localizedDescription)
        }
    }

    private static func gitSync(
        _ arguments: [String],
        cwd: String,
        environment: [String: String]
    ) -> GitResult {
        do {
            let output = try SubprocessRunner.run(
                arguments: ["git", "-C", cwd] + arguments,
                cwd: cwd,
                environment: environment,
                timeout: gitTimeout
            )
            return makeResult(output)
        } catch {
            return GitResult(exitCode: -1, output: "", errorSummary: error.localizedDescription)
        }
    }

    private static func makeResult(_ output: SubprocessRunner.Output) -> GitResult {
        let standardError = String(decoding: output.standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return GitResult(
            exitCode: output.terminationStatus,
            output: String(decoding: output.standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            errorSummary: standardError.isEmpty
                ? "git exited with status \(output.terminationStatus)"
                : String(standardError.split(whereSeparator: \.isNewline).first ?? "")
        )
    }
}
