import BanyanCore
import Foundation

private enum SlackPaneDispatch: Sendable { case sent, refused, uncertain }

extension SessionStore {
    /// Resolve a decision only from the supervisor's current classified capture.
    /// An idle composer or a picker in copy mode never creates controls.
    func slackTerminalDecision(_ request: SlackBrowserRequest) async throws -> [String: Any] {
        guard let id = request.sessionID, let identity = request.identity, identity.kind == "terminalCodex",
              let root = request.slackThread, let terminal = sessions.first(where: { $0.id == id }) as? TerminalSession,
              terminal.status != .closed else { throw CodexRemoteError.invalid("Terminal binding is unavailable") }
        let generation = codexRemote.policyGeneration
        let reset = terminal.lastConversationResetAt, agentID = terminal.agentSessionID
        var bound = request
        bound.action = "boundContext"; bound.cursor = nil; bound.terminalOutput = false
        _ = try await slackBrowser(bound)
        let reading = try await readPaneOutput(id: id, lines: nil)
        try authorizeSlackBrowser(request.principal)
        guard codexRemote.policyGeneration == generation, sessions.contains(where: { $0 === terminal }),
              terminal.status != .closed, terminal.lastConversationResetAt == reset, terminal.agentSessionID == agentID else {
            throw CodexRemoteError.invalid("Session or authorization changed while reading")
        }
        // Revalidate conversation after the potentially slow pane inspection,
        // then classify a fresh capture before publishing controls.
        let context = try await slackBrowser(bound)
        let fresh = try await readPaneOutput(id: id, lines: nil)
        try authorizeSlackBrowser(request.principal)
        guard codexRemote.policyGeneration == generation, sessions.contains(where: { $0 === terminal }),
              terminal.status != .closed, terminal.lastConversationResetAt == reset, terminal.agentSessionID == agentID,
              reading.paneID == fresh.paneID, reading.rootPID == fresh.rootPID else {
            throw CodexRemoteError.invalid("Session or authorization changed while reading")
        }
        // A parked or obscured pane is not evidence that the request resolved.
        // Keep its receipt fenced until a later authoritative observation.
        guard !fresh.isSuspended, !fresh.isFrozen, !fresh.isDeepSuspended, !fresh.paneInMode else {
            return ["status": "unavailable", "requestID": NSNull(), "options": [], "answerable": false]
        }
        let prompt = fresh.prompt
        let observed = try slackDecisionJournal.observe(sessionID: id, identity: identity, principal: request.principal,
            slackThread: root, paneID: fresh.paneID, rootPID: fresh.rootPID, footprint: prompt?.footprint)
        guard let prompt, let observed else { return ["status": "resolved", "requestID": NSNull(), "options": []] }
        noteSlackObservedPrompt(sessionID: id, footprint: prompt.footprint)
        return ["status": observed.status, "requestID": observed.id, "question": prompt.question,
                "context": prompt.context, "options": prompt.options.map { ["index": $0.index, "label": $0.label] },
                "recentContext": context["messages"] ?? [], "answerable": observed.status == "pending"]
    }

    func slackTerminalAnswer(_ request: SlackBrowserRequest) async throws -> [String: Any] {
        guard let id = request.sessionID, let identity = request.identity, identity.kind == "terminalCodex",
              let root = request.slackThread, let requestID = request.requestID,
              let operationID = request.operationID, let option = request.option,
              let terminal = sessions.first(where: { $0.id == id }) as? TerminalSession else {
            throw CodexRemoteError.invalid("Bound request, operation, and option are required")
        }
        let oldRequest = try slackDecisionJournal.request(id: requestID, sessionID: id, identity: identity,
            principal: request.principal, slackThread: root)
        if let old = try slackDecisionJournal.receipt(operationID: operationID, principal: request.principal) {
            guard old.requestID == requestID, old.option == option else { throw CodexRemoteError.invalid("Operation ID reused for different input") }
            return slackDecisionReceiptObject(old)
        }
        let generation = codexRemote.policyGeneration
        var bound = request
        bound.action = "boundContext"; bound.cursor = nil; bound.terminalOutput = false
        _ = try await slackBrowser(bound)
        try authorizeSlackBrowser(request.principal)
        guard codexRemote.policyGeneration == generation, sessions.contains(where: { $0 === terminal }),
              terminal.status != .closed, !terminal.isSuspended, !terminal.isFrozen, !terminal.isDeepSuspended else {
            throw CodexRemoteError.invalid("Session or authorization changed")
        }
        let (receipt, claimed) = try slackDecisionJournal.claim(operationID: operationID, principal: request.principal,
            request: oldRequest, option: option)
        if !claimed { return slackDecisionReceiptObject(receipt) }
        let reading: SessionPaneReading
        do {
            reading = try await readPaneOutput(id: id, lines: nil)
            try authorizeSlackBrowser(request.principal)
            guard codexRemote.policyGeneration == generation, sessions.contains(where: { $0 === terminal }),
                  terminal.status != .closed, !terminal.isSuspended, !terminal.isFrozen, !terminal.isDeepSuspended,
                  !reading.paneInMode, reading.paneID == oldRequest.paneID, reading.rootPID == oldRequest.rootPID,
                  let prompt = reading.prompt, prompt.footprint == oldRequest.footprint else {
                try slackDecisionJournal.reject(receipt, reason: "stale_or_unavailable")
                return ["status": "rejected", "reason": "stale_or_unavailable"]
            }
        } catch {
            try? slackDecisionJournal.reject(receipt, reason: "authorization_or_read_failed")
            throw error
        }
        let answer = AgentAnswerRequest(option: option, footprint: oldRequest.footprint)
        let decision = decideAnswer(id: id, request: answer, reading: reading)
        guard case .send(let keys, _) = decision, let prompt = reading.prompt else {
            try slackDecisionJournal.reject(receipt, reason: "stale_or_invalid_option")
            return ["status": "rejected", "reason": "stale_or_invalid_option"]
        }
        do { try slackDecisionJournal.markSending(receipt) }
        catch {
            releaseConsumedAnswer(id: id)
            try? slackDecisionJournal.reject(receipt, reason: "request_changed")
            throw error
        }
        let backend = tmuxBackend, name = terminal.tmuxSessionName, fence = codexRemote.policyFence
        let contextReader = slackTerminalContext, requestFence = slackDecisionJournal.fence
        let dispatched = await Task.detached(priority: .userInitiated) { () -> SlackPaneDispatch in
            guard fence.matches(generation), requestFence.contains(requestID),
                  let currentContext = try? await contextReader.read(sessionID: id, sessionName: name, provider: .codex,
                      earlier: nil, limit: 1, terminalOutput: false), currentContext.binding == identity,
                  fence.matches(generation), requestFence.contains(requestID), let pane = backend.primaryPaneSnapshot(named: name),
                  pane.paneID == reading.paneID, pane.rootPID == reading.rootPID, !pane.isDead, !pane.isInMode else { return .refused }
            let text = backend.captureVisibleText(paneID: pane.paneID, lineLimit: AgentSupervisor.captureLineLimit)
            guard text == reading.visibleText, let current = AgentPromptParser.parse(visibleText: text),
                  current.footprint == prompt.footprint, current.selectedIndex == prompt.selectedIndex,
                  fence.matches(generation), requestFence.contains(requestID) else { return .refused }
            do { try backend.sendKeys(paneID: pane.paneID, keys: keys); return .sent }
            catch { return .uncertain }
        }.value
        let outcome: [String: Any]
        switch dispatched {
        case .sent:
            try slackDecisionJournal.finish(receipt, sent: true, reason: nil)
            noteInjection(id: id)
            outcome = ["status": "submitted"]
        case .refused:
            releaseConsumedAnswer(id: id)
            try slackDecisionJournal.rejectBeforeSend(receipt, reason: "pane_or_authorization_changed")
            outcome = ["status": "rejected", "reason": "pane_or_authorization_changed"]
        case .uncertain:
            try slackDecisionJournal.finish(receipt, sent: false, reason: "delivery_outcome_unknown")
            outcome = ["status": "uncertain", "reason": "delivery_outcome_unknown"]
        }
        try requireSlackAuthorization(request.principal, generation: generation)
        return outcome
    }

    func slackDecisionReceiptObject(_ receipt: SlackDecisionJournal.Receipt) -> [String: Any] {
        ["operationID": receipt.operationID, "requestID": receipt.requestID, "status": receipt.status,
         "reason": receipt.reason as Any? ?? NSNull()]
    }
}
