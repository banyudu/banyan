import BanyanCore
import Foundation

extension SessionStore {
    /// Puck owns the turn. The remote path never creates a missing row, queues
    /// behind admission, or retries a daemon submission with an unknown outcome.
    func slackPuckFollowUp(_ request: SlackBrowserRequest) async throws -> [String: Any] {
        guard let id = request.sessionID, let identity = request.identity, identity.kind == "puck",
              identity.conversationID == id, let root = request.slackThread,
              let operationID = request.operationID, let text = request.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 16_384,
              !text.unicodeScalars.contains(where: { $0.value == 0 }),
              let session = sessions.first(where: { $0.id == id }) as? PuckSession,
              session.status != .closed, !session.isSuspended else { throw CodexRemoteError.invalid("Puck session is unavailable") }
        let generation = codexRemote.policyGeneration, originalBinding = session.binding, cwd = session.cwd
        var bound = request; bound.action = "boundContext"; bound.cursor = nil; bound.terminalOutput = false
        _ = try await slackBrowser(bound)
        try authorizeSlackBrowser(request.principal)
        guard codexRemote.policyGeneration == generation, sessions.contains(where: { $0 === session }),
              session.status != .closed, !session.isSuspended, session.binding == originalBinding, session.cwd == cwd else {
            throw CodexRemoteError.invalid("Puck session or authorization changed")
        }
        let (receipt, claimed) = try slackFollowUpJournal.claim(operationID: operationID, principal: request.principal,
            sessionID: id, identity: identity, slackThread: root, text: text)
        if !claimed { return slackFollowUpReceiptObject(receipt) }
        var sending = false
        let outcome: [String: Any]
        do {
            let daemon = session.daemon
            let summary = try await Task.detached(priority: .userInitiated) { try daemon.get(id) }.value
            try authorizeSlackBrowser(request.principal)
            guard codexRemote.policyGeneration == generation, sessions.contains(where: { $0 === session }),
                  session.status != .closed, !session.isSuspended, session.binding == originalBinding, session.cwd == cwd,
                  summary.id == id, summary.cwd == cwd, PuckSessionBinding(summary: summary) == originalBinding,
                  ["idle", "hibernated", "interrupted"].contains(summary.position),
                  summary.pendingApproval == nil, summary.pendingQuestion == nil else {
                try slackFollowUpJournal.reject(receipt, reason: "busy_or_unavailable")
                return ["status": "rejected", "reason": "busy_or_unavailable"]
            }
            session.apply(summary: summary)
            let policyFence = codexRemote.policyFence, operationFence = slackFollowUpJournal.fence
            let operationKey = SlackFollowUpJournal.key(receipt)
            let expiresAt = Date().addingTimeInterval(4)
            _ = try await startPuckTurnImmediately(id: id, prompt: text, expiresAt: expiresAt, authorization: {
                try self.authorizeSlackBrowser(request.principal)
                guard self.codexRemote.policyGeneration == generation, self.sessions.contains(where: { $0 === session }),
                      self.admissionPuckSessions[id] === session,
                      session.status != .closed, !session.isSuspended, session.binding == originalBinding, session.cwd == cwd,
                      try self.slackThreadJournal.lookup(sessionID: id, identity: identity, principal: request.principal)?.slackThread == root else {
                    throw CodexRemoteError.invalid("Puck session or authorization changed")
                }
            }, willSubmit: {
                try self.slackFollowUpJournal.markSending(receipt); sending = true
            }, mayDispatch: {
                guard policyFence.matches(generation), operationFence.contains(operationKey), Date() < expiresAt,
                      let latest = try? daemon.get(id), latest.id == id, latest.cwd == cwd,
                      PuckSessionBinding(summary: latest) == originalBinding,
                      ["idle", "hibernated", "interrupted"].contains(latest.position),
                      latest.pendingApproval == nil, latest.pendingQuestion == nil else { return false }
                return policyFence.matches(generation) && operationFence.contains(operationKey) && Date() < expiresAt
            })
            try slackFollowUpJournal.finish(receipt, sent: true)
            outcome = ["status": "submitted"]
        } catch {
            if sending {
                if case .rejected = error as? PuckDaemonError {
                    try? slackFollowUpJournal.rejectBeforeSend(receipt, reason: "daemon_rejected")
                    outcome = ["status": "rejected", "reason": "daemon_rejected"]
                } else {
                    try? slackFollowUpJournal.finish(receipt, sent: false)
                    outcome = ["status": "uncertain", "reason": "delivery_outcome_unknown"]
                }
            } else {
                try? slackFollowUpJournal.reject(receipt, reason: "busy_or_unavailable")
                throw error
            }
        }
        try requireSlackAuthorization(request.principal, generation: generation)
        return outcome
    }
}
