import BanyanCore
import CryptoKit
import Foundation

private enum PuckSlackDispatch: Sendable { case sent, refused, uncertain }

/// A daemon request is identified by its call ID and all of the displayed
/// question/choice data. The journal retains only its digest, not its content.
struct PuckSlackDecision: Sendable {
    enum Payload: Sendable {
        case approval(PuckPendingApproval)
        case question(PuckPendingQuestion)
    }
    let payload: Payload
    let footprint: String
    let question: String
    let context: [String]
    let options: [(index: Int, label: String)]
    let supported: Bool
    let questions: [PuckQuestion]
    let kind: String

    init?(_ summary: PuckSessionSummary) {
        guard (summary.pendingApproval == nil) != (summary.pendingQuestion == nil) else { return nil }
        let canonical: [String: Any]
        if let approval = summary.pendingApproval {
            payload = .approval(approval)
            question = "Approval needed: \(approval.tool)"
            context = [approval.arguments]
            options = [(1, "Approve"), (2, "Approve for Session"), (3, "Deny")]
            supported = true
            questions = []; kind = "puckApproval"
            canonical = ["kind": "approval", "callID": approval.callID, "tool": approval.tool,
                         "arguments": approval.arguments, "expiresAtMS": approval.expiresAtMS]
        } else if let pending = summary.pendingQuestion {
            payload = .question(pending)
            question = pending.questions.map(\.question).joined(separator: "\n\n")
            context = pending.questions.flatMap { [$0.header] + $0.options.map { "\($0.label): \($0.description)" } }
            let single = pending.questions.count == 1 ? pending.questions.first : nil
            options = single?.options.enumerated().map { ($0.offset + 1, $0.element.label) } ?? []
            kind = "puckQuestion"
            questions = pending.questions
            // Slack's form limits must not truncate a choice into a different
            // answer. Oversized or ambiguous forms remain desktop-only.
            supported = !pending.questions.isEmpty && pending.questions.count <= 12 && pending.questions.allSatisfy { question in
                !question.question.isEmpty && question.question.utf8.count <= 2000 && question.options.count <= 100 &&
                (!question.options.isEmpty || question.custom) &&
                question.options.allSatisfy { !$0.label.isEmpty && $0.label.utf8.count <= 75 } &&
                Set(question.options.map(\.label)).count == question.options.count
            }
            canonical = ["kind": "question", "callID": pending.callID, "expiresAtMS": pending.expiresAtMS,
                         "questions": pending.questions.map { question in
                            ["header": question.header, "question": question.question, "multiple": question.multiple,
                             "custom": question.custom, "default": question.defaultAnswer as Any? ?? NSNull(),
                             "options": question.options.map { ["label": $0.label, "description": $0.description] }] as [String: Any]
                         }]
        } else { return nil }
        guard let bytes = try? JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys]) else { return nil }
        footprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    var expiresAtMS: UInt64 {
        switch payload {
        case .approval(let approval): return approval.expiresAtMS
        case .question(let question): return question.expiresAtMS
        }
    }
    var isUnexpired: Bool { expiresAtMS > UInt64(max(0, Date().timeIntervalSince1970 * 1000)) }

    func valid(option: Int, selections: [SlackPuckSelection]?) -> Bool {
        guard supported, isUnexpired else { return false }
        switch payload {
        case .approval:
            return selections == nil && options.contains(where: { $0.index == option })
        case .question(let pending):
            guard let selections else {
                return pending.questions.count == 1 && !pending.questions[0].multiple && !pending.questions[0].custom &&
                    options.contains(where: { $0.index == option })
            }
            guard selections.count == pending.questions.count else { return false }
            return zip(pending.questions, selections).allSatisfy { question, selection in
                let text = selection.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard text.utf8.count <= 4000, !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return false }
                if !text.isEmpty { return question.custom && selection.labels.isEmpty }
                let labels = selection.labels
                return !labels.isEmpty && (question.multiple || labels.count == 1) &&
                    Set(labels).count == labels.count && labels.allSatisfy { label in question.options.contains { $0.label == label } }
            }
        }
    }

    func submit(to daemon: any PuckDaemonService, sessionID: String, option: Int,
                selections: [SlackPuckSelection]?) throws {
        guard valid(option: option, selections: selections) else {
            throw CodexRemoteError.invalid("Puck decision is no longer answerable")
        }
        switch payload {
        case .approval(let pending):
            let choices = ["approve", "session", "deny"]
            try daemon.decide(sessionID, callID: pending.callID, decision: choices[option - 1])
        case .question(let pending):
            let answers: [PuckQuestionSelection]
            if let selections {
                answers = zip(pending.questions, selections).map { question, selection in
                    let text = selection.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return text.isEmpty ? .init(labels: question.options.map(\.label).filter { selection.labels.contains($0) }) : .init(text: text)
                }
            } else { answers = [.init(labels: [pending.questions[0].options[option - 1].label])] }
            try daemon.answer(sessionID, callID: pending.callID, selections: answers)
        }
    }
}

extension SessionStore {
    func slackPuckDecision(_ request: SlackBrowserRequest) async throws -> [String: Any] {
        guard let id = request.sessionID, let identity = request.identity, identity.kind == "puck",
              identity.conversationID == id, let root = request.slackThread,
              let session = sessions.first(where: { $0.id == id }) as? PuckSession,
              session.status != .closed, !session.isSuspended else { throw CodexRemoteError.invalid("Puck binding is unavailable") }
        let generation = codexRemote.policyGeneration, binding = session.binding, cwd = session.cwd, daemon = session.daemon
        var bound = request; bound.action = "boundContext"; bound.cursor = nil; bound.terminalOutput = false
        let context = try await slackBrowser(bound)
        let summary = try await Task.detached(priority: .userInitiated) { try daemon.get(id) }.value
        try requireSlackAuthorization(request.principal, generation: generation)
        guard sessions.contains(where: { $0 === session }), session.status != .closed, !session.isSuspended,
              session.binding == binding, session.cwd == cwd, summary.id == id, summary.cwd == cwd,
              PuckSessionBinding(summary: summary) == binding else {
            throw CodexRemoteError.invalid("Puck session changed while reading")
        }
        if summary.pendingApproval != nil && summary.pendingQuestion != nil {
            return ["status": "unavailable", "requestID": NSNull(), "options": [], "answerable": false]
        }
        let decision = PuckSlackDecision(summary).flatMap { $0.isUnexpired ? $0 : nil }
        let observed = try slackDecisionJournal.observe(sessionID: id, identity: identity, principal: request.principal,
            slackThread: root, paneID: "puck:\(id)", rootPID: 0, footprint: decision?.footprint)
        guard let decision, let observed else { return ["status": "resolved", "requestID": NSNull(), "options": []] }
        return ["status": decision.supported ? observed.status : "unsupported", "requestID": observed.id,
                "kind": decision.kind, "question": decision.question,
                "questions": decision.questions.enumerated().map { index, question in
                    ["id": String(index), "header": question.header, "question": question.question,
                     "multiple": question.multiple, "custom": question.custom,
                     "options": question.options.map { ["label": $0.label, "description": $0.description] }] as [String: Any]
                }, "context": decision.context,
                "options": decision.options.map { ["index": $0.index, "label": $0.label] },
                "recentContext": context["messages"] ?? [], "answerable": decision.supported && observed.status == "pending"]
    }

    func slackPuckAnswer(_ request: SlackBrowserRequest) async throws -> [String: Any] {
        guard let id = request.sessionID, let identity = request.identity, identity.kind == "puck",
              identity.conversationID == id, let root = request.slackThread, let requestID = request.requestID,
              let operationID = request.operationID, let option = request.option,
              let session = sessions.first(where: { $0.id == id }) as? PuckSession else {
            throw CodexRemoteError.invalid("Bound Puck request, operation and option are required")
        }
        let digest: String?
        if let selections = request.selections {
            guard selections.count <= 12 else { throw CodexRemoteError.invalid("Too many answers") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(selections)
            guard bytes.count <= 64 * 1024 else { throw CodexRemoteError.invalid("Answers are too large") }
            digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        } else { digest = nil }
        let oldRequest = try slackDecisionJournal.request(id: requestID, sessionID: id, identity: identity,
            principal: request.principal, slackThread: root)
        if let old = try slackDecisionJournal.receipt(operationID: operationID, principal: request.principal) {
            guard old.requestID == requestID, old.option == option, old.payloadDigest == digest else { throw CodexRemoteError.invalid("Operation ID reused for different input") }
            return slackDecisionReceiptObject(old)
        }
        let generation = codexRemote.policyGeneration, binding = session.binding, cwd = session.cwd, daemon = session.daemon
        var current = request; current.action = "decision"
        let card = try await slackPuckDecision(current)
        try requireSlackAuthorization(request.principal, generation: generation)
        guard card["requestID"] as? String == requestID, card["answerable"] as? Bool == true,
              sessions.contains(where: { $0 === session }), session.binding == binding, session.cwd == cwd,
              session.status != .closed, !session.isSuspended else { throw CodexRemoteError.invalid("Puck request changed") }
        let (receipt, claimed) = try slackDecisionJournal.claim(operationID: operationID, principal: request.principal,
            request: oldRequest, option: option, payloadDigest: digest)
        if !claimed { return slackDecisionReceiptObject(receipt) }
        do { try slackDecisionJournal.markSending(receipt) }
        catch { try? slackDecisionJournal.reject(receipt, reason: "request_changed"); throw error }
        let policyFence = codexRemote.policyFence, requestFence = slackDecisionJournal.fence
        let selections = request.selections
        let dispatched = await Task.detached(priority: .userInitiated) { () -> PuckSlackDispatch in
            guard policyFence.matches(generation), requestFence.contains(requestID),
                  let summary = try? daemon.get(id), summary.id == id, summary.cwd == cwd, PuckSessionBinding(summary: summary) == binding,
                  let decision = PuckSlackDecision(summary), decision.footprint == oldRequest.footprint,
                  decision.valid(option: option, selections: selections),
                  policyFence.matches(generation), requestFence.contains(requestID) else { return .refused }
            do { try decision.submit(to: daemon, sessionID: id, option: option, selections: selections); return .sent }
            catch PuckDaemonError.rejected(_) { return .refused }
            catch { return .uncertain }
        }.value
        let outcome: [String: Any]
        switch dispatched {
        case .sent:
            try slackDecisionJournal.finish(receipt, sent: true, reason: nil)
            outcome = ["status": "submitted"]
        case .refused:
            try slackDecisionJournal.rejectBeforeSend(receipt, reason: "request_or_authorization_changed")
            outcome = ["status": "rejected", "reason": "request_or_authorization_changed"]
        case .uncertain:
            try slackDecisionJournal.finish(receipt, sent: false, reason: "delivery_outcome_unknown")
            outcome = ["status": "uncertain", "reason": "delivery_outcome_unknown"]
        }
        try requireSlackAuthorization(request.principal, generation: generation)
        return outcome
    }
}
