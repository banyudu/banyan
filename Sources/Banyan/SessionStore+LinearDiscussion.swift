import BanyanCore
import Foundation

private enum LinearIssueDiscussionPrompt {
    private static let fallbackTemplate = """
    请用中文围绕 Linear issue {{issue_id}} 讨论。先查看 issue 内容和可验证的当前证据，评估问题是否成立、描述是否清楚、范围是否合理、是否可执行，再给出简明结论并一次问我一个问题。
    """

    private static let fixedBoundaries = """
    本次讨论不要调用 workit、创建 worktree、修改代码或开始实现。补充 issue 时只新增有来源的已确认背景，不改状态、优先级、负责人或验收标准。若无法访问或更新 Linear，请提供建议草稿并说明原因；不要猜测或声称已完成更新。
    """

    static func make(template: String?, issueID: String, issueURL: String) -> String {
        let configuredTemplate = template?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: String
        if let configuredTemplate, !configuredTemplate.isEmpty {
            source = configuredTemplate
        } else {
            source = fallbackTemplate
        }
        let includesIssueID = source.contains("{{issue_id}}")
        let includesIssueURL = source.contains("{{issue_url}}")
        var prompt = source
            .replacingOccurrences(of: "{{issue_id}}", with: issueID)
            .replacingOccurrences(of: "{{issue_url}}", with: issueURL)
        if !includesIssueID { prompt += "\n\nLinear issue ID: \(issueID)" }
        if !includesIssueURL { prompt += "\nLinear issue URL: \(issueURL)" }
        return "\(prompt)\n\n\(fixedBoundaries)"
    }
}

extension SessionStore {
    func discussLinearIssue(_ reference: String) {
        guard let issueID = LinearIssueReference.issueID(in: reference),
              let launch = linearDiscussionLaunch else {
            return
        }

        let issueURL = LinearIssueReference.issueURL(for: issueID, environment: environment)
        let prompt = LinearIssueDiscussionPrompt.make(
            template: linearDiscussionPromptTemplate,
            issueID: issueID,
            issueURL: issueURL
        )
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
