import BanyanCore
import Foundation

private enum SlackFollowUpDispatch: Sendable { case sent, refused, uncertain }

extension SessionStore {
    func slackTerminalFollowUp(_ request: SlackBrowserRequest) async throws -> [String: Any] {
        guard let id = request.sessionID, let identity = request.identity, identity.kind == "terminalCodex",
              let root = request.slackThread, let operationID = request.operationID, let text = request.text,
              TerminalFollowUpGate.acceptsText(text),
              let terminal = sessions.first(where: { $0.id == id }) as? TerminalSession else {
            throw CodexRemoteError.invalid("A bound terminal and one printable line are required")
        }
        let generation = codexRemote.policyGeneration
        let reset = terminal.lastConversationResetAt, agentID = terminal.agentSessionID
        var bound = request
        bound.action = "boundContext"; bound.cursor = nil; bound.terminalOutput = false
        _ = try await slackBrowser(bound)
        try authorizeSlackBrowser(request.principal)
        guard codexRemote.policyGeneration == generation, sessions.contains(where: { $0 === terminal }),
              terminal.status != .closed, !terminal.isSuspended, !terminal.isFrozen, !terminal.isDeepSuspended,
              terminal.lastConversationResetAt == reset, terminal.agentSessionID == agentID else {
            throw CodexRemoteError.invalid("Session or authorization changed")
        }
        let (receipt, claimed) = try slackFollowUpJournal.claim(operationID: operationID, principal: request.principal,
            sessionID: id, identity: identity, slackThread: root, text: text)
        if !claimed { return slackFollowUpReceiptObject(receipt) }
        let reading: SessionPaneReading
        do {
            reading = try await readPaneOutput(id: id, lines: nil)
            try authorizeSlackBrowser(request.principal)
            guard codexRemote.policyGeneration == generation, sessions.contains(where: { $0 === terminal }),
                  terminal.status != .closed, terminal.lastConversationResetAt == reset, terminal.agentSessionID == agentID,
                  TerminalFollowUpGate.permits(provider: terminal.agentProvider, status: reading.status,
                    paneInMode: reading.paneInMode, isSuspended: reading.isSuspended, isFrozen: reading.isFrozen,
                    isDeepSuspended: reading.isDeepSuspended, visibleText: reading.visibleText) else {
                try slackFollowUpJournal.reject(receipt, reason: "busy_or_unavailable")
                return ["status": "rejected", "reason": "busy_or_unavailable"]
            }
        } catch {
            try? slackFollowUpJournal.reject(receipt, reason: "authorization_or_read_failed")
            throw error
        }
        let target: SessionPaneTarget
        do { target = try paneTarget(id: id) }
        catch {
            try? slackFollowUpJournal.reject(receipt, reason: "session_unavailable")
            throw error
        }
        try slackFollowUpJournal.markSending(receipt)
        let backend = tmuxBackend, processes = processTable, contextReader = slackTerminalContext
        let policyFence = codexRemote.policyFence, operationFence = slackFollowUpJournal.fence
        let operationKey = SlackFollowUpJournal.key(receipt)
        let sent = await Task.detached(priority: .userInitiated) { () -> SlackFollowUpDispatch in
            guard policyFence.matches(generation), operationFence.contains(operationKey),
                  let current = try? await contextReader.read(sessionID: id, sessionName: target.tmuxSessionName,
                    provider: .codex, earlier: nil, limit: 1, terminalOutput: false), current.binding == identity,
                  policyFence.matches(generation), operationFence.contains(operationKey),
                  let fresh = Self.read(target, lines: nil, backend: backend, processTable: processes.snapshot()),
                  fresh.paneID == reading.paneID, fresh.rootPID == reading.rootPID, fresh.visibleText == reading.visibleText,
                  TerminalFollowUpGate.permits(provider: .codex, status: fresh.status, paneInMode: fresh.paneInMode,
                    isSuspended: fresh.isSuspended, isFrozen: fresh.isFrozen, isDeepSuspended: fresh.isDeepSuspended,
                    visibleText: fresh.visibleText), policyFence.matches(generation), operationFence.contains(operationKey) else { return .refused }
            do {
                try await backend.sendPrompt(paneID: fresh.paneID, text: text, isCancelled: {
                    !policyFence.matches(generation) || !operationFence.contains(operationKey)
                })
                return .sent
            } catch { return .uncertain }
        }.value
        let outcome: [String: Any]
        switch sent {
        case .sent:
            try slackFollowUpJournal.finish(receipt, sent: true)
            terminal.noteUserSubmittedInput(text)
            noteInjection(id: id)
            outcome = ["status": "submitted"]
        case .refused:
            try slackFollowUpJournal.rejectBeforeSend(receipt, reason: "pane_or_authorization_changed")
            outcome = ["status": "rejected", "reason": "pane_or_authorization_changed"]
        case .uncertain:
            try slackFollowUpJournal.finish(receipt, sent: false)
            outcome = ["status": "uncertain", "reason": "delivery_outcome_unknown"]
        }
        try requireSlackAuthorization(request.principal, generation: generation)
        return outcome
    }

    func slackFollowUpReceiptObject(_ receipt: SlackFollowUpJournal.Receipt) -> [String: Any] {
        ["operationID": receipt.operationID, "status": receipt.status, "reason": receipt.reason as Any? ?? NSNull()]
    }
}
