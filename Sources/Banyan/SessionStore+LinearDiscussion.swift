import BanyanCore
import Foundation

private enum LinearIssueDiscussionPrompt {
    static func make(issueID: String, issueURL: String) -> String {
        """
        Discuss Linear issue \(issueID) with me before implementation.
        First read its current description, acceptance criteria, and comments in Linear: \(issueURL)
        Assess whether it describes a valid problem, has a reasonable scope, and is actionable. Identify ambiguous requirements, missing decisions, dependencies, and risks. Give me a concise assessment, then ask one focused question at a time so we can decide whether and how to proceed.
        Keep this discussion-only. Do not run workit, create a worktree, edit code, change the issue, or begin implementation unless I explicitly ask. If you cannot access the issue, ask me to paste its details rather than guessing.
        """
    }
}

extension SessionStore {
    func discussLinearIssue(_ reference: String) {
        guard let issueID = LinearIssueReference.issueID(in: reference),
              let launch = linearDiscussionLaunch else {
            return
        }

        let issueURL = LinearIssueReference.issueURL(for: issueID, environment: environment)
        let prompt = LinearIssueDiscussionPrompt.make(issueID: issueID, issueURL: issueURL)
        let title = "Discuss \(issueID)"
        let cwd = selectedSession?.cwd ?? homeDirectory
        let parentSessionID = selectedSession?.parentSessionID

        if let puck = launch.puck {
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await createPuckSession(
                        binding: puck.binding,
                        cwd: cwd,
                        title: title,
                        parentSessionID: parentSessionID,
                        prompt: prompt
                    )
                } catch {
                    puckSessionError = error.localizedDescription
                }
            }
            return
        }

        guard launch.provider != nil else { return }
        let command = launch.resolvedCommand(codexLaunchMode: codexLaunchMode)
        guard !command.isEmpty else { return }
        _ = spawn(
            title: title,
            cwd: cwd,
            command: "\(command) \(AgentLaunchCommand.shellQuote(prompt))",
            parentSessionID: parentSessionID
        )
    }

    private var linearDiscussionLaunch: NewSessionLaunch? {
        if let paletteAgentLaunch {
            return paletteAgentLaunch
        }
        if let selectedSession,
           let launch = sessionLaunchProfile(for: selectedSession),
           launch.provider != nil || launch.puck != nil {
            return launch
        }
        return paletteAgentProfiles.first(where: { $0.id == "codex" })
            ?? paletteAgentProfiles.first
    }
}
