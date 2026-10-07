import Foundation

/// A tuple, rather than three independent lists, avoids accidental cross grants.
public struct CodexRemotePrincipal: Codable, Equatable, Sendable {
    public var workspace: String
    public var channel: String
    public var user: String
    public init(workspace: String, channel: String, user: String) {
        self.workspace = workspace; self.channel = channel; self.user = user
    }
}

public struct CodexRemotePolicy: Codable, Equatable, Sendable {
    public var enabled = false
    public var allowed: [CodexRemotePrincipal] = []
    public init(enabled: Bool = false, allowed: [CodexRemotePrincipal] = []) {
        self.enabled = enabled; self.allowed = allowed
    }
    public func permits(_ principal: CodexRemotePrincipal) -> Bool {
        enabled && !principal.workspace.isEmpty && !principal.channel.isEmpty && !principal.user.isEmpty
            && allowed.contains(principal)
    }
}

public struct CodexRemoteAttachment: Codable, Equatable, Sendable {
    public var id: String
    public var sessionID: String
    public var threadID: String
    public var workspace: String
    public var channel: String
    public var slackThread: String
}

public struct CodexRemoteRequest: Codable, Equatable, Sendable {
    public var action: String
    public var principal: CodexRemotePrincipal
    public var sessionID: String?
    public var threadID: String?
    public var attachmentID: String?
    public var slackThread: String?
    public var operationID: String?
    public var queuedOperationID: String?
    public var turnID: String?
    public var requestID: CodexJSONValue?
    public var text: String?
    public var decision: String?
    public var answers: [String: String]?
    public var cursor: Int?
    public var epoch: String?
}

public struct CodexRemoteReceipt: Codable, Sendable {
    public var request: CodexRemoteRequest
    /// queued -> submitting -> submitted. Crash/timeout becomes uncertain;
    /// uncertain is never replayed automatically, including after restart.
    public var status: String
    public var result: CodexJSONValue?
}

public enum CodexRemoteError: LocalizedError {
    case denied, invalid(String)
    public var errorDescription: String? {
        switch self {
        case .denied: return "Slack control is disabled or this workspace/channel/user is not allowed"
        case .invalid(let reason): return reason
        }
    }
}

/// Runtime-independent persistence and authorization around the ONE native
/// coordinator. Credentials and Slack networking never enter this layer.
@MainActor
public final class CodexRemoteControl {
    private struct Journal: Codable {
        var version = 1
        var policy = CodexRemotePolicy()
        var attachments: [CodexRemoteAttachment] = []
        var receipts: [CodexRemoteReceipt] = []
    }
    private struct Event {
        var cursor: Int
        var sessionID: String
        var kind: String
        var attachment: CodexRemoteAttachment
    }
    private var journal: Journal
    public nonisolated static let maximumJournalBytes = 32 * 1024 * 1024
    private let maximumJournalBytes: Int
    private let file: URL
    private let coordinator: CodexThreadCoordinator
    private var observer: UUID?
    private var conversations: [String: CodexConversation] = [:]
    private var events: [Event] = []
    private var previousAttention: [String: [CodexJSONValue]] = [:]
    private var cursor = 0
    private let epoch = UUID().uuidString
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var drains: [String: Task<Void, Never>] = [:]
    private var lease: Task<Void, Never>?
    public private(set) var isOnline = false
    public private(set) var storageError: String?
    public var onChange: (() -> Void)?
    /// Host supplies only native rows. No settings, credentials or raw logs.
    public var metadata: (String) -> (title: String, project: String)? = { _ in nil }
    public var recentConversation: (String) -> CodexConversation? = { _ in nil }
    public var policy: CodexRemotePolicy { journal.policy }
    public var attachments: [CodexRemoteAttachment] { journal.attachments }

    public init(coordinator: CodexThreadCoordinator, file: URL, maximumJournalBytes: Int = CodexRemoteControl.maximumJournalBytes) {
        self.maximumJournalBytes = maximumJournalBytes
        self.coordinator = coordinator; self.file = file
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                guard data.count <= maximumJournalBytes else { throw CodexRemoteError.invalid("Remote journal is too large") }
                journal = try JSONDecoder().decode(Journal.self, from: data)
                guard journal.version == 1 else { throw CodexRemoteError.invalid("Unsupported remote journal version") }
                for index in journal.receipts.indices where journal.receipts[index].status == "submitting" {
                    journal.receipts[index].status = "uncertain"
                }
            } else { journal = Journal() }
        } catch {
            journal = Journal()
            storageError = "Remote journal cannot be read; restore or repair it before enabling Slack"
        }
        observer = coordinator.observe(.init(
            change: { [weak self] id, state in self?.changed(id, state) },
            hydrate: { [weak self] id, thread in self?.hydrate(id, thread) },
            event: { [weak self] id, method, params in self?.receive(id, method, params) }))
    }

    deinit { lease?.cancel(); for task in drains.values { task.cancel() } }

    private func commit(_ mutation: (inout Journal) -> Void) throws {
        guard storageError == nil else { throw CodexRemoteError.invalid(storageError!) }
        var next = journal
        mutation(&next)
        let data = try JSONEncoder().encode(next)
        guard data.count <= maximumJournalBytes else {
            throw CodexRemoteError.invalid("Remote journal byte limit reached; preserve receipts and resolve/archive locally")
        }
        let directory = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            storageError = "Remote journal write failed; Slack control is unavailable"
            isOnline = false
            onChange?()
            throw error
        }
        journal = next
        onChange?()
    }

    /// Local administration only, guarded by the local control token. A remote
    /// action cannot enable itself or expand the allowlist.
    public func configure(_ policy: CodexRemotePolicy) throws {
        guard policy.allowed.count <= 256 else { throw CodexRemoteError.invalid("Too many allowlist entries") }
        try commit { next in
            next.policy = policy
            for index in next.receipts.indices where next.receipts[index].status == "queued"
                && !policy.allowed.contains(next.receipts[index].request.principal) {
                next.receipts[index].status = "cancelled"
            }
        }
        for attachment in journal.attachments where !isCurrent(attachment) {
            coordinator.setRemoteObservation(sessionID: attachment.sessionID, ownerID: attachment.id, retained: false)
        }
        if !policy.enabled {
            isOnline = false; lease?.cancel()
            conversations = [:]
            for task in drains.values { task.cancel() }
            events = []
        }
        wake()
        Task { [weak self] in await self?.restoreObservation() }
    }

    private func isCurrent(_ attachment: CodexRemoteAttachment) -> Bool {
        storageError == nil && journal.attachments.contains(attachment) && journal.policy.enabled
            && journal.policy.allowed.contains { $0.workspace == attachment.workspace && $0.channel == attachment.channel }
            && coordinator.states[attachment.sessionID]?.binding.threadID == attachment.threadID
            && metadata(attachment.sessionID) != nil
    }

    private func requireCurrent(_ attachment: CodexRemoteAttachment) throws {
        guard isCurrent(attachment) else { throw CodexRemoteError.invalid("Remote observation ownership changed") }
    }

    public func restoreObservation() async {
        for attachment in journal.attachments {
            let retain = isCurrent(attachment)
            do {
                try await coordinator.retainRemoteObservation(sessionID: attachment.sessionID, retained: retain,
                    ownerID: attachment.id, authorization: { [weak self] in
                        guard let self else { throw CodexRemoteError.denied }
                        try self.requireCurrent(attachment)
                    })
                if retain { try requireCurrent(attachment); scheduleDrain(attachment.sessionID) }
            } catch {
                if !isCurrent(attachment) {
                    try? await coordinator.retainRemoteObservation(sessionID: attachment.sessionID, retained: false, ownerID: attachment.id)
                } else { append(attachment.sessionID, "unavailable") }
            }
        }
        onChange?()
    }

    public func detachLocally(sessionID: String) throws {
        let old = journal.attachments.first { $0.sessionID == sessionID }
        try commit { next in
            next.attachments.removeAll { $0.sessionID == sessionID }
            for index in next.receipts.indices where next.receipts[index].request.sessionID == sessionID
                && next.receipts[index].status == "queued" { next.receipts[index].status = "cancelled" }
        }
        if let old {
            coordinator.setRemoteObservation(sessionID: sessionID, ownerID: old.id, retained: false)
            append(sessionID, "detached", attachment: old)
        }
        conversations.removeValue(forKey: sessionID)
        drains[sessionID]?.cancel()
        if let old {
            Task { [weak self] in try? await self?.coordinator.retainRemoteObservation(sessionID: sessionID, retained: false, ownerID: old.id) }
        }
    }

    /// After inspecting authoritative history, the local operator acknowledges
    /// an uncertain outcome. This never submits its text again. Keep the receipt
    /// as a replay tombstone and allow later queued work to proceed.
    public func resolveLocally(workspace: String, operationID: String) throws {
        guard let receipt = journal.receipts.first(where: {
            $0.request.principal.workspace == workspace && $0.request.operationID == operationID
        }), receipt.status == "uncertain" else {
            throw CodexRemoteError.invalid("Only uncertain receipts can be acknowledged locally")
        }
        try updateReceipt(receipt.request, status: "acknowledged", result: nil)
        if let id = receipt.request.sessionID { scheduleDrain(id); append(id, "reconciled") }
    }

    public func desktopStatus(sessionID: String) -> String? {
        guard let attachment = journal.attachments.first(where: { $0.sessionID == sessionID }) else { return nil }
        let pending = journal.receipts.filter { $0.request.sessionID == sessionID && ["queued", "submitting", "uncertain"].contains($0.status) }
        let count = pending.filter { $0.status == "queued" }.count
        let uncertain = pending.contains { $0.status == "uncertain" || $0.status == "submitting" }
        let availability = !policy.enabled || !isCurrent(attachment) ? "disabled" : (coordinator.states[sessionID]?.connection != .subscribed ? "unavailable" : (isOnline ? "connected" : "offline"))
        return "Slack \(availability) · \(attachment.channel) · \(count) queued" + (uncertain ? " · submission needs reconciliation" : "")
    }

    private func authorize(_ request: CodexRemoteRequest) throws {
        guard storageError == nil, journal.policy.permits(request.principal) else { throw CodexRemoteError.denied }
    }

    private func bound(_ request: CodexRemoteRequest) throws -> CodexRemoteAttachment {
        try authorize(request)
        guard let attachment = journal.attachments.first(where: { $0.sessionID == request.sessionID }),
              attachment.id == request.attachmentID, attachment.threadID == request.threadID,
              attachment.workspace == request.principal.workspace, attachment.channel == request.principal.channel,
              attachment.slackThread == request.slackThread,
              coordinator.states[attachment.sessionID]?.binding.threadID == attachment.threadID,
              metadata(attachment.sessionID) != nil else {
            throw CodexRemoteError.invalid("Attachment changed; refresh authoritative session state")
        }
        return attachment
    }

    public func handle(_ request: CodexRemoteRequest) async throws -> CodexJSONValue {
        try authorize(request) // Before ANY content, receipt, event or action.
        switch request.action {
        case "list":
            return .object(["sessions": .array(coordinator.states.keys.sorted().compactMap { id in
                guard metadata(id) != nil, coordinator.states[id]?.binding.threadID != nil else { return nil }
                // Listing reveals metadata only; context requires explicit attachment.
                return summary(id, context: false)
            })])
        case "sync":
            touchLease()
            // Recovery resumes only existing exact bindings, never thread/start.
            await restoreObservation()
            try authorize(request)
            return batch(request, refresh: true)
        case "offline":
            isOnline = false; lease?.cancel(); onChange?(); return .object([:])
        case "events":
            touchLease()
            if request.epoch == epoch, request.cursor == cursor, waiters.count < 32 {
                let id = UUID()
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(25))
                    self?.waiters.removeValue(forKey: id)?.resume()
                }
                await withCheckedContinuation { waiters[id] = $0 }
                timeout.cancel()
            }
            try authorize(request)
            return batch(request, refresh: false)
        case "reconcile":
            let attachment = try bound(request)
            let result = try await coordinator.refreshConversation(sessionID: attachment.sessionID, authorization: {
                _ = try self.bound(request)
            })
            _ = try bound(request)
            if let thread = result.objectValue?["thread"] { hydrate(attachment.sessionID, thread) }
            return summary(attachment.sessionID, context: true)
        case "snapshot":
            let attachment = try bound(request)
            return summary(attachment.sessionID, context: true)
        case "receipt":
            let attachment = try bound(request)
            guard let receipt = journal.receipts.first(where: {
                $0.request.operationID == request.operationID && $0.request.principal.workspace == request.principal.workspace
                    && $0.request.attachmentID == attachment.id
            }) else { return .object(["status": .string("absent")]) }
            return try value(receipt)
        case "attach":
            guard let id = request.sessionID, let threadID = request.threadID,
                  metadata(id) != nil, coordinator.states[id]?.binding.threadID == threadID,
                  let slackThread = request.slackThread, !slackThread.isEmpty, slackThread.utf8.count <= 100 else {
                throw CodexRemoteError.invalid("Attach requires an existing native session/thread and Slack thread timestamp")
            }
            if let old = journal.attachments.first(where: { $0.sessionID == id }) {
                guard old.threadID == threadID, old.workspace == request.principal.workspace,
                      old.channel == request.principal.channel, old.slackThread == slackThread else {
                    throw CodexRemoteError.invalid("Session already attached; detach before attaching elsewhere")
                }
            } else {
                guard !journal.attachments.contains(where: { $0.workspace == request.principal.workspace
                    && $0.channel == request.principal.channel && $0.slackThread == slackThread }) else {
                    throw CodexRemoteError.invalid("Slack thread already attached to another session")
                }
                let attachment = CodexRemoteAttachment(id: UUID().uuidString, sessionID: id, threadID: threadID,
                    workspace: request.principal.workspace, channel: request.principal.channel, slackThread: slackThread)
                try commit { $0.attachments.append(attachment) }
            }
            let attachment = journal.attachments.first { $0.sessionID == id }!
            do {
                try await coordinator.retainRemoteObservation(sessionID: id, retained: true, ownerID: attachment.id,
                    authorization: { [weak self] in
                        guard let self else { throw CodexRemoteError.denied }
                        try self.requireCurrent(attachment)
                    })
                try requireCurrent(attachment)
            } catch {
                if !isCurrent(attachment) {
                    try? await coordinator.retainRemoteObservation(sessionID: id, retained: false, ownerID: attachment.id)
                }
                throw error
            }
            try authorize(request)
            append(id, "attached")
            return summary(id, context: true)
        case "detach":
            let attachment = try bound(request)
            try detachLocally(sessionID: attachment.sessionID)
            return .object(["status": .string("detached")])
        case "queue", "steer", "stop", "respond":
            let attachment = try bound(request)
            guard let operationID = request.operationID, !operationID.isEmpty, operationID.utf8.count <= 256 else {
                throw CodexRemoteError.invalid("A bounded stable operationID is required")
            }
            if let receipt = journal.receipts.first(where: {
                $0.request.operationID == operationID && $0.request.principal.workspace == request.principal.workspace
            }) {
                guard receipt.request == request else { throw CodexRemoteError.invalid("Operation ID reused for different content") }
                return try value(receipt)
            }
            guard journal.receipts.count < 4096 else {
                throw CodexRemoteError.invalid("Operation journal full; archive locally before accepting new control")
            }
            if ["queue", "steer"].contains(request.action) {
                guard let text = request.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.utf8.count <= 16_384 else { throw CodexRemoteError.invalid("Message must contain 1–16384 bytes") }
            }
            if request.action == "queue" {
                guard journal.receipts.filter({ $0.status == "queued" }).count < 256 else {
                    throw CodexRemoteError.invalid("Remote queue full")
                }
                try commit { $0.receipts.append(.init(request: request, status: "queued")) }
                append(attachment.sessionID, "queued")
                scheduleDrain(attachment.sessionID)
            } else {
                // Validate before write-ahead; rejected stale controls cause no RPC.
                try validateAction(request)
                if let queuedID = request.queuedOperationID {
                    guard request.action == "steer", journal.receipts.contains(where: {
                        $0.request.operationID == queuedID && $0.request.attachmentID == request.attachmentID
                            && $0.request.text == request.text && $0.status == "queued"
                    }) else { throw CodexRemoteError.invalid("Queued message already submitted or changed") }
                }
                try commit { next in
                    if let queuedID = request.queuedOperationID,
                       let index = next.receipts.firstIndex(where: { $0.request.operationID == queuedID && $0.request.attachmentID == request.attachmentID }) {
                        next.receipts[index].status = "steered"
                    }
                    next.receipts.append(.init(request: request, status: "submitting"))
                }
                await submit(request)
            }
            _ = try bound(request)
            return try value(journal.receipts.first { $0.request == request }!)
        default: throw CodexRemoteError.invalid("Unknown native remote action")
        }
    }

    private func validateAction(_ request: CodexRemoteRequest) throws {
        let attachment = try bound(request)
        guard let state = coordinator.states[attachment.sessionID], state.connection == .subscribed else {
            throw CodexRemoteError.invalid("Native session is unavailable; reconnect before acting")
        }
        if request.action == "respond" {
            guard let pending = state.pendingRequests.first(where: { $0.id == request.requestID }),
                  coordinator.requestIsAnswerable(sessionID: attachment.sessionID, requestID: pending.id),
                  pending.params.objectValue?["turnId"]?.stringValue == request.turnID, request.turnID != nil else {
                throw CodexRemoteError.invalid("Request is no longer pending in this turn")
            }
            _ = try reply(request, pending)
        } else if request.action != "queue" {
            guard let turnID = request.turnID, state.activeTurnID == turnID else {
                throw CodexRemoteError.invalid("Active turn changed; refresh controls")
            }
            if request.action == "steer", state.needsAttention { throw CodexRemoteError.invalid("Answer the pending request first") }
        } else {
            guard state.runtime.type == "idle", state.activeTurnID == nil, !state.needsAttention else {
                throw CodexRemoteError.invalid("Session is not eligible for queued input")
            }
        }
    }

    private func reply(_ request: CodexRemoteRequest, _ pending: CodexServerRequest) throws -> CodexServerReply {
        let model = CodexConversationRequest(pending)
        if model.isApproval, let raw = request.decision, let decision = CodexApprovalDecision(rawValue: raw),
           [.accept, .decline].contains(decision) { return try model.approvalReply(decision) }
        if model.isInput, let answers = request.answers, !model.questions.contains(where: { $0.isSecret }) {
            return try model.inputReply(answers)
        }
        throw CodexRemoteError.invalid("Use offered Approve Once/Deny choices, or answer non-secret questions on desktop")
    }

    private func submit(_ request: CodexRemoteRequest) async {
        guard let id = request.sessionID else { return }
        var sent = false
        do {
            try validateAction(request)
            let input: [CodexJSONValue] = [.object(["type": .string("text"), "text": .string(request.text ?? "")])]
            let result: CodexJSONValue
            switch request.action {
            case "queue":
                result = try await coordinator.startTurn(sessionID: id, input: input, authorization: { [weak self] in
                    guard let self else { throw CodexRemoteError.denied }
                    _ = try self.bound(request)
                }, willSubmit: { sent = true })
            case "steer": result = try await coordinator.steer(sessionID: id, expectedTurnID: request.turnID!, input: input, authorization: { _ = try self.bound(request) }, willSubmit: { sent = true })
            case "stop": try await coordinator.interrupt(sessionID: id, expectedTurnID: request.turnID!, authorization: { _ = try self.bound(request) }, willSubmit: { sent = true }); result = .object([:])
            case "respond":
                let pending = coordinator.states[id]!.pendingRequests.first { $0.id == request.requestID }!
                sent = true
                try coordinator.respond(sessionID: id, requestID: pending.id, reply: reply(request, pending))
                result = .object([:])
            default: return
            }
            try updateReceipt(request, status: "submitted", result: result)
        } catch {
            // No automatic retry even when rejection looks definite: a process
            // crash or lost response may hide a successful runtime submission.
            let definiteRejection: Bool
            if case .remote = error as? CodexAppServerError { definiteRejection = true } else { definiteRejection = false }
            do { try updateReceipt(request, status: (!sent || definiteRejection) ? "rejected" : "uncertain", result: nil) }
            catch { storageError = "Remote receipt could not be saved; Slack control is unavailable"; isOnline = false }
        }
        append(id, "submission")
    }

    private func updateReceipt(_ request: CodexRemoteRequest, status: String, result: CodexJSONValue?) throws {
        try commit { next in
            if let index = next.receipts.firstIndex(where: { $0.request == request }) {
                next.receipts[index].status = status; next.receipts[index].result = result
            }
        }
    }

    private func scheduleDrain(_ id: String) {
        guard drains[id] == nil, policy.enabled else { return }
        drains[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.drains.removeValue(forKey: id) }
            while !Task.isCancelled, self.policy.enabled,
                  let state = self.coordinator.states[id], state.connection == .subscribed,
                  state.runtime.type == "idle", state.activeTurnID == nil, !state.needsAttention,
                  !self.journal.receipts.contains(where: { $0.request.sessionID == id && ["submitting", "uncertain"].contains($0.status) }),
                  let receipt = self.journal.receipts.first(where: { $0.request.sessionID == id && $0.status == "queued" }) {
                do {
                    _ = try self.bound(receipt.request)
                    try self.updateReceipt(receipt.request, status: "submitting", result: nil)
                    await self.submit(receipt.request)
                } catch { return }
            }
        }
    }

    private func changed(_ id: String, _ state: CodexThreadState) {
        guard journal.attachments.contains(where: { $0.sessionID == id }) else { return }
        if state.connection == .connecting { conversations[id, default: .init()].beginHydration() }
        let requests = state.pendingRequests.map(\.id)
        let newRequest = requests.contains { !(previousAttention[id] ?? []).contains($0) }
        previousAttention[id] = requests
        let kind: String
        switch state.connection {
        case .failed, .unavailable, .writerConflict: kind = "error"
        default: kind = newRequest ? "attention" : "state"
        }
        append(id, kind)
        scheduleDrain(id)
    }
    private func hydrate(_ id: String, _ thread: CodexJSONValue) {
        guard journal.attachments.contains(where: { $0.sessionID == id && isCurrent($0) }), let threadID = coordinator.states[id]?.binding.threadID else { return }
        conversations[id, default: .init()].hydrate(thread: thread, threadID: threadID)
    }
    private func receive(_ id: String, _ method: String, _ params: CodexJSONValue) {
        guard journal.attachments.contains(where: { $0.sessionID == id && isCurrent($0) }), let threadID = coordinator.states[id]?.binding.threadID else { return }
        conversations[id, default: .init()].receive(method: method, params: params, threadID: threadID)
        if ["turn/completed", "item/completed", "serverRequest/resolved", "error"].contains(method) { append(id, method) }
    }
    private func append(_ id: String, _ kind: String, attachment: CodexRemoteAttachment? = nil) {
        guard policy.enabled, let attachment = attachment ?? journal.attachments.first(where: { $0.sessionID == id }) else { return }
        cursor += 1
        events.append(Event(cursor: cursor, sessionID: id, kind: kind, attachment: attachment))
        if events.count > 256 { events.removeFirst(events.count - 256) }
        wake(); onChange?()
    }
    private func wake() {
        let pending = waiters.values; waiters = [:]
        for waiter in pending { waiter.resume() }
    }
    private func touchLease() {
        isOnline = true; lease?.cancel(); onChange?()
        lease = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            self?.isOnline = false; self?.onChange?()
        }
    }
    private func batch(_ request: CodexRemoteRequest, refresh: Bool) -> CodexJSONValue {
        let visible = journal.attachments.filter { $0.workspace == request.principal.workspace && $0.channel == request.principal.channel }
        let gap = refresh || request.epoch != epoch || (request.cursor ?? -1) < (events.first?.cursor ?? cursor) - 1
            || (request.cursor ?? 0) > cursor
        let delivered = events.filter { $0.cursor > (request.cursor ?? -1) && $0.attachment.workspace == request.principal.workspace
            && $0.attachment.channel == request.principal.channel }
        return .object(["epoch": .string(epoch), "cursor": .integer(Int64(cursor)), "refresh": .bool(gap),
            "sessions": .array(visible.map { summary($0.sessionID, context: true) }),
            "events": .array(delivered.map { .object(["cursor": .integer(Int64($0.cursor)), "kind": .string($0.kind),
                "sessionID": .string($0.sessionID), "attachment": (try? value($0.attachment)) ?? .null]) })])
    }
    private func summary(_ id: String, context: Bool) -> CodexJSONValue {
        guard let state = coordinator.states[id], let metadata = metadata(id) else { return .null }
        var result: [String: CodexJSONValue] = ["sessionID": .string(id), "threadID": state.binding.threadID.map(CodexJSONValue.string) ?? .null,
            "title": .string(String(metadata.title.prefix(200))), "project": .string(metadata.project),
            "state": .string(state.runtime.type), "needsAttention": .bool(state.needsAttention),
            "available": .bool(state.connection == .subscribed), "turnID": state.activeTurnID.map(CodexJSONValue.string) ?? .null,
            "lastTurnStatus": state.lastTurnStatus.map(CodexJSONValue.string) ?? .null]
        guard context else { return .object(result) }
        result["attachment"] = journal.attachments.first(where: { $0.sessionID == id }).flatMap { try? value($0) } ?? .null
        result["receipts"] = .array(journal.receipts.filter { $0.request.sessionID == id }.suffix(32).map {
            .object(["operationID": .string($0.request.operationID ?? ""), "status": .string($0.status)])
        })
        result["context"] = .array((recentConversation(id)?.turns ?? conversations[id]?.turns ?? []).flatMap { $0.items }.filter {
            ["userMessage", "agentMessage", "plan", "commandExecution", "mcpToolCall"].contains($0.type)
        }.suffix(12).map { .object(["type": .string($0.type), "text": .string(String($0.text.prefix(2000)))]) })
        result["requests"] = .array(state.pendingRequests.map { request in
            let model = CodexConversationRequest(request)
            let fields = request.params.objectValue ?? [:]
            let answerable = coordinator.requestIsAnswerable(sessionID: id, requestID: request.id)
            return .object(["id": request.id, "turnID": fields["turnId"] ?? .null, "title": .string(model.title),
                "answerable": .bool(answerable),
                "detail": .string(String((fields["command"]?.stringValue ?? fields["reason"]?.stringValue ?? "").prefix(2000))),
                "decisions": .array((answerable ? model.decisions : []).filter { [.accept, .decline].contains($0) }.map { .string($0.rawValue) }),
                "questions": .array(model.questions.map { q in .object(["id": .string(q.id), "question": .string(q.question),
                    "options": .array(q.options), "allowsOther": .bool(q.allowsOther), "secret": .bool(q.isSecret)]) })])
        })
        return .object(result)
    }
    private func value<T: Encodable>(_ data: T) throws -> CodexJSONValue {
        try JSONDecoder().decode(CodexJSONValue.self, from: JSONEncoder().encode(data))
    }
}
