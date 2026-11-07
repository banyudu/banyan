import BanyanCore
import Foundation

private enum LinearIssueDiscussionPrompt {
    static func make(issueID: String, issueURL: String) -> String {
        """
        我想先讨论 Linear issue \(issueID)，暂时不要开始实现。
        请按顺序处理：
        1. 阅读 issue 当前的标题、描述、验收标准、评论和关联信息：\(issueURL)
        2. 查找能说明问题现状的当前证据，例如相关代码、文档、运行记录或讨论。记录每条证据的来源，明确区分事实和推测。
        3. 根据已确认的证据补充 issue 的背景和上下文，例如问题现状、影响、复现线索、约束和依赖。保留原有目标与范围，不改变状态、优先级、负责人或验收标准。若无法可靠更新 Linear，就先把建议补充的内容发给我，并说明原因。
        4. 再判断 issue 描述是否准确、合理、清楚且可执行，包括范围和验收标准；指出证据、假设、缺失信息、依赖和风险。先给我简明的中文结论，然后一次只问我一个最关键的问题。

        不要运行 workit、创建 worktree、修改代码或开始实现。如果无法访问 issue 或找不到证据，请直接说明并向我询问，不要猜测或声称已完成更新。
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
