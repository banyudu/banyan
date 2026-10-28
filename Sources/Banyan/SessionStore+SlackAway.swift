import BanyanCore
import Foundation

extension SessionStore {
    func slackAwayStatusObject(_ state: SlackAwayJournal.State) -> [String: Any] {
        ["enabled": state.enabled, "sessionIDs": state.sessionIDs, "projectIDs": state.projectIDs,
         "activationID": state.activationID as Any? ?? NSNull(), "checkpointEpoch": state.checkpointEpoch as Any? ?? NSNull(),
         "checkpointCursor": state.checkpointCursor as Any? ?? NSNull(), "revision": state.revision]
    }

    /// A cursor is meaningful only within this app epoch and Away activation.
    /// Gaps request an authoritative snapshot instead of suggesting full replay.
    func slackAwayEvents(_ request: SlackBrowserRequest) throws -> [String: Any] {
        try authorizeSlackBrowser(request.principal)
        let away = try slackAwayJournal.status(principal: request.principal)
        let latest = sessionEvents(since: nil).cursor
        let validCursor = request.eventEpoch == slackSessionEventEpoch && request.eventCursor.map { $0 >= 0 && $0 <= latest } == true
        let sameActivation = request.awayActivationID == away.activationID && request.awayRevision == away.revision
        let batch = validCursor ? sessionEvents(since: request.eventCursor) : sessionEvents(since: nil)
        let gap = away.enabled && (!validCursor || batch.truncated)
        let refresh = away.enabled && (gap || !sameActivation)
        let scoped = Set(sessions.filter { !$0.isImportedHistory && $0.status != .closed &&
            slackAwayJournal.includes(sessionID: $0.id, projectID: $0.projectGroupID, principal: request.principal) }.map(\.id))
        return ["enabled": away.enabled, "activationID": away.activationID as Any? ?? NSNull(),
                "revision": away.revision, "epoch": slackSessionEventEpoch, "cursor": batch.cursor,
                "gap": gap, "refresh": refresh,
                "events": away.enabled && !refresh ? batch.events.filter { scoped.contains($0.sessionID) }.map {
                    ["cursor": $0.cursor, "sessionID": $0.sessionID, "status": $0.status.rawValue]
                } : []]
    }

    /// Reconciles one event against current runtime state without reading a
    /// provider transcript. Only an actual parsed pending prompt is actionable.
    func slackAwaySession(_ request: SlackBrowserRequest) async throws -> [String: Any] {
        let away = try slackAwayJournal.status(principal: request.principal)
        guard away.enabled, let id = request.sessionID, let session = sessions.first(where: { $0.id == id }),
              !session.isImportedHistory, session.status != .closed,
              slackAwayJournal.includes(sessionID: id, projectID: session.projectGroupID, principal: request.principal) else {
            throw CodexRemoteError.invalid("Session is not in the Away scope")
        }
        let policy = codexRemote.policyGeneration
        var pending = false
        var question: String?
        if session.status.isAwaitingHumanAnswer, let terminal = session as? TerminalSession {
            let reset = terminal.lastConversationResetAt, agentID = terminal.agentSessionID
            let reading = try? await readPaneOutput(id: id, lines: nil)
            try authorizeSlackBrowser(request.principal)
            guard codexRemote.policyGeneration == policy, slackAwayJournal.state.revision == away.revision,
                  sessions.contains(where: { $0 === terminal }), terminal.status != .closed,
                  terminal.lastConversationResetAt == reset, terminal.agentSessionID == agentID else {
                throw CodexRemoteError.invalid("Away scope or session changed")
            }
            if let reading, !reading.isSuspended, !reading.isFrozen, !reading.isDeepSuspended, !reading.paneInMode,
               let prompt = reading.prompt { pending = true; question = prompt.question }
        } else if let native = session as? CodexSession {
            pending = native.state.pendingRequests.contains { codexThreads.requestIsAnswerable(sessionID: id, requestID: $0.id) }
        } else if session.status.isAwaitingHumanAnswer, let puck = session as? PuckSession {
            let daemon = puck.daemon, binding = puck.binding
            let summary = await Task.detached(priority: .userInitiated) { try? daemon.get(id) }.value
            try authorizeSlackBrowser(request.principal)
            guard codexRemote.policyGeneration == policy, slackAwayJournal.state.revision == away.revision,
                  sessions.contains(where: { $0 === puck }), puck.binding == binding else {
                throw CodexRemoteError.invalid("Away scope or session changed")
            }
            pending = summary?.id == id && (summary?.pendingApproval != nil || summary?.pendingQuestion != nil)
        }
        try authorizeSlackBrowser(request.principal)
        guard codexRemote.policyGeneration == policy, slackAwayJournal.state.revision == away.revision,
              sessions.contains(where: { $0 === session }), session.status != .closed,
              slackAwayJournal.includes(sessionID: id, projectID: session.projectGroupID, principal: request.principal) else {
            throw CodexRemoteError.invalid("Away scope or session changed")
        }
        return ["sessionID": id, "title": session.displayTitle, "project": session.projectGroupTitle,
                "status": session.status.rawValue, "backend": session.backendKind.rawValue, "pending": pending,
                "question": question as Any? ?? NSNull(), "activationID": away.activationID as Any? ?? NSNull(),
                "revision": away.revision]
    }

    /// Captures the cursor before any pane work. Status transitions arriving
    /// during the await remain in the bounded event log and are returned too.
    func slackAwaySnapshot(_ request: SlackBrowserRequest) async throws -> [String: Any] {
        let away = try slackAwayJournal.status(principal: request.principal)
        guard away.enabled, let activation = away.activationID else { throw CodexRemoteError.invalid("Away is off") }
        let policyGeneration = codexRemote.policyGeneration
        let boundary = sessionEvents(since: nil).cursor
        let replayStart = away.checkpointEpoch == slackSessionEventEpoch ? away.checkpointCursor : nil
        let initial = sessions.filter { !$0.isImportedHistory && $0.status != .closed &&
            slackAwayJournal.includes(sessionID: $0.id, projectID: $0.projectGroupID, principal: request.principal) }
        var decisions: [[String: Any]] = []
        for session in initial {
            guard session.status.isAwaitingHumanAnswer else { continue }
            if let terminal = session as? TerminalSession {
                let reset = terminal.lastConversationResetAt, agentID = terminal.agentSessionID
                let reading = try? await readPaneOutput(id: terminal.id, lines: nil)
                try authorizeSlackBrowser(request.principal)
                guard codexRemote.policyGeneration == policyGeneration, slackAwayJournal.state.revision == away.revision,
                      sessions.contains(where: { $0 === terminal }), terminal.status != .closed,
                      terminal.lastConversationResetAt == reset, terminal.agentSessionID == agentID else {
                    throw CodexRemoteError.invalid("Away scope or session changed during catch-up")
                }
                if let reading, !reading.isSuspended, !reading.isFrozen, !reading.isDeepSuspended, !reading.paneInMode,
                   let prompt = reading.prompt {
                    decisions.append(["sessionID": terminal.id, "question": prompt.question,
                                      "options": prompt.options.map { ["index": $0.index, "label": $0.label] }])
                }
            } else if let native = session as? CodexSession {
                let pending = native.state.pendingRequests.filter { codexThreads.requestIsAnswerable(sessionID: native.id, requestID: $0.id) }
                if !pending.isEmpty { decisions.append(["sessionID": native.id, "count": pending.count]) }
            } else if let puck = session as? PuckSession {
                let daemon = puck.daemon, id = puck.id, binding = puck.binding
                let summary = await Task.detached(priority: .userInitiated) { try? daemon.get(id) }.value
                try authorizeSlackBrowser(request.principal)
                guard codexRemote.policyGeneration == policyGeneration, slackAwayJournal.state.revision == away.revision,
                      sessions.contains(where: { $0 === puck }), puck.binding == binding else {
                    throw CodexRemoteError.invalid("Away scope or session changed during catch-up")
                }
                if let summary, summary.id == id, summary.pendingApproval != nil || summary.pendingQuestion != nil {
                    decisions.append(["sessionID": id, "count": 1])
                }
            }
        }
        try authorizeSlackBrowser(request.principal)
        guard codexRemote.policyGeneration == policyGeneration, slackAwayJournal.state.revision == away.revision,
              slackAwayJournal.state.enabled else { throw CodexRemoteError.invalid("Away changed during catch-up") }
        let current = sessions.filter { !$0.isImportedHistory && $0.status != .closed &&
            slackAwayJournal.includes(sessionID: $0.id, projectID: $0.projectGroupID, principal: request.principal) }
        let rows: [[String: Any]] = current.map { ["sessionID": $0.id, "title": $0.displayTitle,
            "project": $0.projectGroupTitle, "status": $0.status.rawValue, "backend": $0.backendKind.rawValue] }
        let currentIDs = Set(current.map(\.id))
        decisions.removeAll { item in guard let id = item["sessionID"] as? String else { return true }; return !currentIDs.contains(id) }
        let changes = sessionEvents(since: replayStart)
        let epochGap = away.checkpointEpoch != slackSessionEventEpoch
        return ["activationID": activation, "revision": away.revision, "epoch": slackSessionEventEpoch, "startCursor": replayStart as Any? ?? NSNull(), "snapshotCursor": boundary,
                "cursor": changes.cursor, "gap": epochGap || changes.truncated,
                "sessions": rows, "decisions": decisions,
                "events": changes.events.filter { currentIDs.contains($0.sessionID) }.map {
                    ["cursor": $0.cursor, "sessionID": $0.sessionID, "status": $0.status.rawValue]
                }]
    }
}
