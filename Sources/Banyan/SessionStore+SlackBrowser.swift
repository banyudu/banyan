import BanyanCore
import CryptoKit
import Foundation

struct SlackPuckSelection: Codable, Sendable {
    var labels: [String]
    var text: String?
}

struct SlackBrowserRequest: Decodable {
    var action: String
    var principal: CodexRemotePrincipal
    var sessionID: String?
    var query: String?
    var filter: String?
    var offset: Int?
    var limit: Int?
    var cursor: String?
    var identity: SlackConversationIdentity?
    var slackThread: String?
    var terminalOutput: Bool?
    var requestID: String?
    var operationID: String?
    var option: Int?
    var selections: [SlackPuckSelection]?
    var text: String?
    var awayEnabled: Bool?
    var followSessionID: String?
    var followProjectID: String?
    var follow: Bool?
    var eventEpoch: String?
    var eventCursor: Int?
    var awayActivationID: String?
    var awayRevision: UInt64?
}

private enum SlackPuckHistory: Sendable {
    case paged(PuckHistoryPage)
    case recent(PuckRecentHistory)
}

extension SessionStore {
    /// The Slack transport supplies a tuple, never a filesystem path. The same
    /// authoritative policy that protects the native connector gates every read.
    func slackBrowser(_ request: SlackBrowserRequest) async throws -> [String: Any] {
        try authorizeSlackBrowser(request.principal)
        switch request.action {
        case "list":
            let query = (request.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.utf8.count <= 256 else { throw CodexRemoteError.invalid("Search is too long") }
            let filter = request.filter ?? "all"
            guard ["all", "needs", "working", "recent"].contains(filter) else { throw CodexRemoteError.invalid("Unknown session filter") }
            let offset = request.offset ?? 0
            guard (0...1_000_000).contains(offset) else { throw CodexRemoteError.invalid("Invalid session offset") }
            let limit = min(max(request.limit ?? 10, 1), 30)
            let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            let matching = sessions.filter { session in
                guard !session.isImportedHistory, session.status != .closed else { return false }
                let attention = SessionLifecyclePolicy.needsAttention(status: session.status,
                    isImportedHistory: session.isImportedHistory, isSuspended: session.isSuspended)
                switch filter {
                case "needs": guard attention else { return false }
                case "working": guard [.running, .executing, .longRunningShell, .subagents].contains(session.status) else { return false }
                case "recent": guard session.updatedAt >= cutoff else { return false }
                default: break
                }
                return query.isEmpty || [session.id, session.displayTitle, session.projectGroupTitle]
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }.sorted { lhs, rhs in
                if lhs.projectGroupTitle != rhs.projectGroupTitle {
                    return lhs.projectGroupTitle.localizedStandardCompare(rhs.projectGroupTitle) == .orderedAscending
                }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
            let start = min(offset, matching.count)
            let end = min(start + limit, matching.count)
            let rows: [[String: Any]] = matching[start..<end].map { session in
                ["sessionID": session.id, "title": session.displayTitle, "projectID": session.projectGroupID,
                 "project": session.projectGroupTitle, "backend": session.backendKind.rawValue,
                 "status": session.status.rawValue,
                 "needsAttention": SessionLifecyclePolicy.needsAttention(status: session.status,
                    isImportedHistory: session.isImportedHistory, isSuspended: session.isSuspended)]
            }
            return ["sessions": rows, "nextOffset": end < matching.count ? end as Any : NSNull(), "total": matching.count]
        case "awayStatus":
            return slackAwayStatusObject(try slackAwayJournal.status(principal: request.principal))
        case "awayConfigure":
            if request.follow == true, let id = request.followSessionID, !sessions.contains(where: { $0.id == id && !$0.isImportedHistory && $0.status != .closed }) {
                throw CodexRemoteError.invalid("Session is unavailable")
            }
            if request.follow == true, let project = request.followProjectID, !sessions.contains(where: { $0.projectGroupID == project && !$0.isImportedHistory && $0.status != .closed }) {
                throw CodexRemoteError.invalid("Project is unavailable")
            }
            let next = try slackAwayJournal.configure(principal: request.principal, enabled: request.awayEnabled,
                sessionID: request.followSessionID, projectID: request.followProjectID, follow: request.follow,
                epoch: slackSessionEventEpoch, cursor: sessionEvents(since: nil).cursor)
            return slackAwayStatusObject(next)
        case "awayCheck":
            let away = try slackAwayJournal.status(principal: request.principal)
            let selected = request.sessionID.flatMap { id in sessions.first(where: { $0.id == id && !$0.isImportedHistory && $0.status != .closed }) }
            let allowed = away.enabled && (request.sessionID == nil || selected.map {
                slackAwayJournal.includes(sessionID: $0.id, projectID: $0.projectGroupID, principal: request.principal)
            } == true)
            return ["allowed": allowed, "activationID": away.activationID as Any? ?? NSNull(), "revision": away.revision]
        case "awaySession":
            return try await slackAwaySession(request)
        case "awaySnapshot":
            return try await slackAwaySnapshot(request)
        case "awayEvents":
            return try slackAwayEvents(request)
        case "followup":
            if request.identity?.kind == "puck" { return try await slackPuckFollowUp(request) }
            return try await slackTerminalFollowUp(request)
        case "followupReceipt":
            guard let operationID = request.operationID else { throw CodexRemoteError.invalid("Operation ID is required") }
            guard let receipt = try slackFollowUpJournal.receipt(operationID: operationID, principal: request.principal) else {
                return ["status": "absent"]
            }
            return slackFollowUpReceiptObject(receipt)
        case "decision":
            if request.identity?.kind == "puck" { return try await slackPuckDecision(request) }
            return try await slackTerminalDecision(request)
        case "answer":
            if request.identity?.kind == "puck" { return try await slackPuckAnswer(request) }
            return try await slackTerminalAnswer(request)
        case "decisionReceipt":
            guard let operationID = request.operationID else { throw CodexRemoteError.invalid("Operation ID is required") }
            guard let receipt = try slackDecisionJournal.receipt(operationID: operationID, principal: request.principal) else {
                return ["status": "absent"]
            }
            return slackDecisionReceiptObject(receipt)
        case "boundContext":
            guard let id = request.sessionID, let expected = request.identity, let root = request.slackThread,
                  !(request.terminalOutput == true && request.cursor != nil) else {
                throw CodexRemoteError.invalid("Bound context requires its session, conversation, and thread")
            }
            let generation = codexRemote.policyGeneration
            var openRequest = request
            openRequest.action = "open"; openRequest.cursor = nil; openRequest.terminalOutput = nil
            let opened = try await slackBrowser(openRequest)
            guard slackIdentity(from: opened["binding"]) == expected,
                  let attachment = opened["attachment"] as? [String: Any],
                  attachment["sessionID"] as? String == id, attachment["slackThread"] as? String == root,
                  let latest = opened["context"] as? [String: Any] else {
                throw CodexRemoteError.invalid("Slack thread binding changed")
            }
            var context = latest
            if request.cursor != nil || request.terminalOutput == true {
                var readRequest = request
                readRequest.action = request.terminalOutput == true ? "output" : "context"
                context = try await slackBrowser(readRequest)
                if request.terminalOutput == true {
                    // Output has no transcript binding of its own. Recheck the
                    // authoritative conversation after capturing the pane.
                    let current = try await slackBrowser(openRequest)
                    guard slackIdentity(from: current["binding"]) == expected,
                          let currentAttachment = current["attachment"] as? [String: Any],
                          currentAttachment["sessionID"] as? String == id,
                          currentAttachment["slackThread"] as? String == root else {
                        throw CodexRemoteError.invalid("Slack thread binding changed")
                    }
                } else if slackIdentity(from: context["binding"]) != expected {
                    throw CodexRemoteError.invalid("Conversation changed while reading")
                }
            }
            try authorizeSlackBrowser(request.principal)
            guard codexRemote.policyGeneration == generation else { throw CodexRemoteError.invalid("Authorization changed while reading") }
            return context
        case "open", "bind":
            guard let id = request.sessionID, request.cursor == nil else {
                throw CodexRemoteError.invalid("Opening a session requires its ID")
            }
            var contextRequest = request
            contextRequest.action = "context"
            let context = try await slackBrowser(contextRequest)
            guard let rawIdentity = context["binding"] as? [String: Any],
                  let identity = slackIdentity(from: rawIdentity) else {
                if request.action == "open" { return ["context": context, "binding": NSNull(), "attachment": NSNull()] }
                throw CodexRemoteError.invalid("Conversation identity cannot be verified")
            }
            if request.action == "bind", request.identity != identity {
                throw CodexRemoteError.invalid("Conversation changed before thread binding")
            }
            let existingNative = codexRemote.attachments.first { $0.sessionID == id }
            if let native = existingNative {
                guard identity.kind == "nativeCodex", native.threadID == identity.conversationID,
                      native.workspace == request.principal.workspace, native.channel == request.principal.channel,
                      request.action != "bind" || request.slackThread == native.slackThread,
                      try slackThreadJournal.permitsNativeAttachment(sessionID: id, threadID: native.threadID,
                          principal: request.principal, slackThread: native.slackThread) else {
                    throw CodexRemoteError.invalid("Native conversation is already attached elsewhere")
                }
                return ["context": context, "binding": rawIdentity,
                        "attachment": ["id": native.id, "sessionID": id, "workspace": native.workspace,
                                       "channel": native.channel, "slackThread": native.slackThread]]
            }
            if request.action == "open" {
                let mapping = try slackThreadJournal.lookup(sessionID: id, identity: identity, principal: request.principal)
                return ["context": context, "binding": rawIdentity,
                        "attachment": mapping.map(slackMappingObject) as Any? ?? NSNull()]
            }
            guard let root = request.slackThread else { throw CodexRemoteError.invalid("Slack thread timestamp is required") }
            guard !codexRemote.attachments.contains(where: { $0.workspace == request.principal.workspace &&
                $0.channel == request.principal.channel && $0.slackThread == root }) else {
                throw CodexRemoteError.invalid("Slack thread is already attached to another session")
            }
            let mapping = try slackThreadJournal.bind(sessionID: id, identity: identity, principal: request.principal, slackThread: root)
            return ["context": context, "binding": rawIdentity, "attachment": slackMappingObject(mapping)]
        case "context", "output":
            if request.action == "context", let id = request.sessionID,
               let native = sessions.first(where: { $0.id == id }) as? CodexSession {
                return try await slackNativeHistory(request, session: native)
            }
            if request.action == "context", let id = request.sessionID,
               let puck = sessions.first(where: { $0.id == id }) as? PuckSession {
                return try await slackPuckHistory(request, session: puck)
            }
            guard let id = request.sessionID, let session = sessions.first(where: { $0.id == id }) as? TerminalSession,
                  !session.isImportedHistory, session.status != .closed else {
                throw CodexRemoteError.invalid("Terminal session is unavailable")
            }
            let generation = codexRemote.policyGeneration
            let name = session.tmuxSessionName
            let provider = session.agentProvider
            let reset = session.lastConversationResetAt
            let agentID = session.agentSessionID
            let context = try await slackTerminalContext.read(sessionID: id, sessionName: name, provider: provider,
                earlier: request.cursor, limit: request.limit ?? 20, terminalOutput: request.action == "output")
            // A disable/re-enable, removed row, reset, or session replacement
            // while reading must not publish the previously authorized content.
            try authorizeSlackBrowser(request.principal)
            guard codexRemote.policyGeneration == generation,
                  sessions.contains(where: { $0 === session }), session.status != .closed,
                  session.tmuxSessionName == name, session.agentProvider == provider,
                  session.lastConversationResetAt == reset, session.agentSessionID == agentID else {
                throw CodexRemoteError.invalid("Session or authorization changed while reading")
            }
            var binding = context.binding
            if let pane = binding, pane.kind == "terminalPane" {
                // Pane identity alone cannot prove a provider conversation. At
                // minimum, invalidate read-only thread mappings on observed
                // resets, changed provider IDs, or app restart. Never turn this
                // fallback into an input-capable conversation binding.
                let fields = [slackSessionEventEpoch, id, pane.generation, context.conversationID ?? "",
                              agentID ?? "", provider?.rawValue ?? "",
                              reset.map { String($0.timeIntervalSince1970.bitPattern) } ?? "",
                              context.source == .providerTranscript ? "" : (context.output ?? "")]
                let digest = SHA256.hash(data: try JSONEncoder().encode(fields))
                    .map { String(format: "%02x", $0) }.joined()
                binding = SlackConversationIdentity(kind: "terminalPane", conversationID: pane.conversationID, generation: digest)
            }
            return ["source": context.source.rawValue, "conversationID": context.conversationID as Any? ?? NSNull(),
                    "binding": binding.map(slackIdentityObject) as Any? ?? NSNull(),
                    "messages": context.messages.map { ["role": $0.role, "text": $0.text, "truncated": $0.truncated] },
                    "earlier": context.earlier as Any? ?? NSNull(), "output": context.output as Any? ?? NSNull(),
                    "limitation": context.limitation as Any? ?? NSNull(), "truncated": context.truncated,
                    "mayBeStale": context.mayBeStale]
        default:
            throw CodexRemoteError.invalid("Unknown session browser action")
        }
    }

    private func slackNativeHistory(_ request: SlackBrowserRequest, session: CodexSession) async throws -> [String: Any] {
        guard session.status != .closed, let threadID = session.state.binding.threadID, !threadID.isEmpty else {
            throw CodexRemoteError.invalid("Native conversation is unavailable")
        }
        let generation = codexRemote.policyGeneration
        let home = session.state.binding.codexHome
        let fileCursor = request.cursor?.hasPrefix("rollout:") == true
        if request.cursor == nil || fileCursor {
            let cursor = fileCursor ? String(request.cursor!.dropFirst("rollout:".count)) : nil
            let page: ConversationHistoryReader.Page?
            do {
                page = try await slackNativeTranscriptHistory.page(sessionID: session.id, threadID: threadID,
                    home: home, earlier: cursor, limit: request.limit ?? 20)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if fileCursor { throw CodexRemoteError.invalid("Native history changed; open latest") }
                page = nil
            }
            try requireSlackAuthorization(request.principal, generation: generation)
            guard sessions.contains(where: { $0 === session }), session.status != .closed,
                  session.state.binding.threadID == threadID, session.state.binding.codexHome == home else {
                throw CodexRemoteError.invalid("Conversation changed while reading")
            }
            if let page {
                let identity = SlackConversationIdentity(kind: "nativeCodex", conversationID: threadID, generation: "native")
                let limitation: String? = page.incompleteTail ? "The final record is still being written; earlier pages are unavailable." :
                    (page.truncatedBefore ? "Earlier pages are unavailable because the transcript generation cannot be fully verified." : nil)
                return ["source": "providerTranscript", "conversationID": threadID, "binding": slackIdentityObject(identity),
                        "messages": page.messages.map { ["role": $0.role, "text": $0.text, "truncated": $0.truncated] },
                        "earlier": page.earlier.map { "rollout:" + $0 } as Any? ?? NSNull(), "output": NSNull(),
                        "limitation": limitation as Any? ?? NSNull(),
                        "truncated": page.truncatedBefore || page.messages.contains(where: \.truncated), "mayBeStale": page.incompleteTail]
            }
            if fileCursor { throw CodexRemoteError.invalid("Native history changed; open latest") }
        }
        // thread/read is subscription-free and cannot start or resume a turn.
        let result: CodexJSONValue
        do { result = try await codexThreads.read(sessionID: session.id) }
        catch is CancellationError { throw CancellationError() }
        catch {
            guard request.cursor == nil else { throw CodexRemoteError.invalid("Native history changed; open latest") }
            try requireSlackAuthorization(request.principal, generation: generation)
            guard sessions.contains(where: { $0 === session }), session.status != .closed,
                  session.state.binding.threadID == threadID else {
                throw CodexRemoteError.invalid("Conversation changed while reading")
            }
            let identity = SlackConversationIdentity(kind: "nativeCodex", conversationID: threadID, generation: "native")
            return ["source": "unavailable", "conversationID": threadID, "binding": slackIdentityObject(identity),
                    "messages": [], "earlier": NSNull(), "output": NSNull(),
                    "limitation": "Native history is unavailable. Reopen it on the Mac or retry when the native service is available.",
                    "truncated": false, "mayBeStale": true]
        }
        try authorizeSlackBrowser(request.principal)
        guard codexRemote.policyGeneration == generation, sessions.contains(where: { $0 === session }),
              session.status != .closed, session.state.binding.threadID == threadID,
              let thread = result.objectValue?["thread"], thread.objectValue?["id"]?.stringValue == threadID else {
            throw CodexRemoteError.invalid("Conversation or authorization changed while reading")
        }
        var conversation = CodexConversation()
        conversation.hydrate(thread: thread, threadID: threadID)
        let page = try slackStructuredHistory.page(sessionID: session.id, threadID: threadID,
            entries: SlackStructuredHistory.entries(conversation),
            truncated: conversation.omittedTurns > 0 || conversation.omittedItems > 0,
            cursor: request.cursor, limit: request.limit ?? 20)
        let identity = SlackConversationIdentity(kind: "nativeCodex", conversationID: threadID, generation: "native")
        return ["source": "nativeCodex", "conversationID": threadID, "binding": slackIdentityObject(identity),
                "messages": page.entries.map { ["role": $0.role, "text": $0.text, "truncated": $0.truncated] },
                "earlier": page.earlier as Any? ?? NSNull(), "output": NSNull(),
                "limitation": page.truncated ? "Older or oversized native history was omitted." : NSNull(),
                "truncated": page.truncated, "mayBeStale": false]
    }

    private func slackPuckHistory(_ request: SlackBrowserRequest, session: PuckSession) async throws -> [String: Any] {
        guard session.status != .closed else { throw CodexRemoteError.invalid("Puck session is unavailable") }
        let generation = codexRemote.policyGeneration, id = session.id, binding = session.binding, daemon = session.daemon
        let cursor = request.cursor, limit = min(max(request.limit ?? 20, 1), 100)
        let result = try await PuckBackgroundIO.run { () -> (PuckSessionSummary, SlackPuckHistory, PuckSessionSummary) in
            let before = try daemon.get(id)
            let history: SlackPuckHistory
            if let cursor, cursor.hasPrefix("puck-history:") {
                history = .paged(try daemon.history(id, cursor: String(cursor.dropFirst("puck-history:".count)), limit: limit))
            } else if cursor != nil {
                guard let legacy = daemon as? any PuckRecentHistoryReading else { throw CodexRemoteError.invalid("Puck history cursor expired") }
                history = .recent(try legacy.recentEvents(id, maximum: 100))
            } else {
                do { history = .paged(try daemon.history(id, cursor: nil, limit: limit)) }
                catch {
                    guard let legacy = daemon as? any PuckRecentHistoryReading else { throw error }
                    history = .recent(try legacy.recentEvents(id, maximum: 100))
                }
            }
            let after = try daemon.get(id)
            return (before, history, after)
        }
        try authorizeSlackBrowser(request.principal)
        let before = result.0, history = result.1, after = result.2
        guard codexRemote.policyGeneration == generation, sessions.contains(where: { $0 === session }),
              session.status != .closed, session.binding == binding, before.id == id, after.id == id,
              before.cwd == session.cwd, PuckSessionBinding(summary: before) == binding,
              before.engine == after.engine, before.provider == after.provider, before.account == after.account,
              before.workspace == after.workspace, before.cwd == after.cwd else {
            throw CodexRemoteError.invalid("Puck session or authorization changed while reading")
        }
        let identity = SlackConversationIdentity(kind: "puck", conversationID: id, generation: "puck")
        switch history {
        case .paged(let page):
            guard page.session == id, ["asc", "desc"].contains(page.order), page.items.count <= limit,
                  page.nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 8192 }) ?? true else {
                throw CodexRemoteError.invalid("Puck history response is invalid")
            }
            let items = page.order == "desc" ? Array(page.items.reversed()) : page.items
            return ["source": "puckHistory", "conversationID": id, "binding": slackIdentityObject(identity),
                    "messages": items.map { ["role": $0.kind, "text": String($0.text.prefix(8_000)),
                                             "truncated": $0.truncated || $0.text.count > 8_000] },
                    "earlier": page.nextCursor.map { "puck-history:" + $0 } as Any? ?? NSNull(), "output": NSNull(),
                    "limitation": page.source == "legacy_projection" ? "Puck legacy history may omit earlier conversation content." : NSNull(),
                    "truncated": items.contains { $0.truncated || $0.text.count > 8_000 }, "mayBeStale": false]
        case .recent(let history):
            let page = try slackStructuredHistory.page(sessionID: id, threadID: "puck:" + id,
                entries: SlackStructuredHistory.entries(history), truncated: history.truncated || history.incomplete,
                cursor: cursor, limit: limit)
            return ["source": "puckEvents", "conversationID": id, "binding": slackIdentityObject(identity),
                    "messages": page.entries.map { ["role": $0.role, "text": $0.text, "truncated": $0.truncated] },
                    "earlier": page.earlier as Any? ?? NSNull(), "output": NSNull(),
                    "limitation": "Puck event history may omit user prompts; older events can be truncated.",
                    "truncated": page.truncated, "mayBeStale": history.incomplete]
        }
    }

    private func slackIdentity(from value: Any?) -> SlackConversationIdentity? {
        guard let object = value as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(SlackConversationIdentity.self, from: data)
    }

    private func slackIdentityObject(_ identity: SlackConversationIdentity) -> [String: Any] {
        ["kind": identity.kind, "conversationID": identity.conversationID, "generation": identity.generation]
    }

    private func slackMappingObject(_ mapping: SlackThreadJournal.Mapping) -> [String: Any] {
        ["id": mapping.id, "sessionID": mapping.sessionID, "workspace": mapping.workspace,
         "channel": mapping.channel, "slackThread": mapping.slackThread]
    }

    func authorizeSlackBrowser(_ principal: CodexRemotePrincipal) throws {
        guard codexRemote.storageError == nil, codexRemote.policy.permits(principal) else { throw CodexRemoteError.denied }
    }

    func requireSlackAuthorization(_ principal: CodexRemotePrincipal, generation: UInt64) throws {
        try authorizeSlackBrowser(principal)
        guard codexRemote.policyGeneration == generation else { throw CodexRemoteError.invalid("Authorization changed during the operation") }
    }
}
