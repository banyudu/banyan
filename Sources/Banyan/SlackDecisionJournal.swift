import BanyanCore
import Foundation

/// A request can be resolved while an off-main send is being prepared.
final class SlackDecisionFence: @unchecked Sendable {
    private let lock = NSLock()
    private var active: Set<String> = []
    func replace(_ ids: Set<String>) { lock.lock(); defer { lock.unlock() }; active = ids }
    func invalidate(_ id: String) { lock.lock(); defer { lock.unlock() }; active.remove(id) }
    func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return active.contains(id) }
}

/// Request identities and write-ahead operation receipts. No prompt, answer
/// text, or credentials are persisted here.
@MainActor
final class SlackDecisionJournal {
    struct Request: Codable, Equatable {
        let id: String
        let sessionID: String
        let identity: SlackConversationIdentity
        let workspace: String
        let channel: String
        let slackThread: String
        let paneID: String
        let rootPID: Int
        let footprint: String
        var status: String
    }
    struct Receipt: Codable, Equatable {
        let operationID: String
        let principal: CodexRemotePrincipal
        let requestID: String
        let option: Int
        var status: String
        var reason: String?
    }
    private struct State: Codable { var version = 1; var requests: [Request] = []; var receipts: [Receipt] = [] }
    private let file: URL
    private var state: State
    private(set) var storageError: String?
    let fence = SlackDecisionFence()
    private let maxBytes = 8 * 1024 * 1024

    init(file: URL) {
        self.file = file
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                guard let size = attrs[.size] as? NSNumber, size.intValue <= maxBytes else { throw Failure.invalid }
                var decoded = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
                guard Self.valid(decoded) else { throw Failure.invalid }
                // A crash while preparing sent nothing; a crash after the
                // write-ahead send marker may have delivered input.
                for i in decoded.receipts.indices {
                    if decoded.receipts[i].status == "sending" { decoded.receipts[i].status = "uncertain" }
                    if decoded.receipts[i].status == "preparing" { decoded.receipts[i].status = "rejected"; decoded.receipts[i].reason = "interrupted_before_send" }
                }
                for i in decoded.requests.indices {
                    if decoded.requests[i].status == "sending" { decoded.requests[i].status = "uncertain" }
                    if decoded.requests[i].status == "preparing" { decoded.requests[i].status = "resolved" }
                }
                state = decoded
            } else { state = State() }
        } catch {
            state = State()
            storageError = "Slack decision journal is unavailable; preserve and repair it locally"
        }
        syncFence()
    }

    /// Retires the old card when the observed pane no longer has that request.
    /// The same still-visible prompt keeps its request ID and cannot be answered twice.
    func observe(sessionID: String, identity: SlackConversationIdentity, principal: CodexRemotePrincipal,
                 slackThread: String, paneID: String, rootPID: Int, footprint: String?) throws -> Request? {
        try available()
        var next = state
        let active = next.requests.lastIndex { $0.sessionID == sessionID && $0.workspace == principal.workspace &&
            $0.channel == principal.channel && $0.slackThread == slackThread && $0.status != "resolved" }
        if let active {
            let old = next.requests[active]
            if let footprint, old.identity == identity, old.paneID == paneID, old.rootPID == rootPID, old.footprint == footprint {
                return old
            }
            // Fence any already-running dispatch before the journal write.
            fence.invalidate(old.id)
            next.requests[active].status = "resolved"
        }
        var created: Request?
        if let footprint, !footprint.isEmpty {
            guard next.requests.count < 4096 else { throw Failure.full }
            let request = Request(id: UUID().uuidString, sessionID: sessionID, identity: identity,
                workspace: principal.workspace, channel: principal.channel, slackThread: slackThread,
                paneID: paneID, rootPID: rootPID, footprint: footprint, status: "pending")
            next.requests.append(request); created = request
        }
        if active != nil || created != nil { try commit(next) }
        return created
    }

    func request(id: String, sessionID: String, identity: SlackConversationIdentity,
                 principal: CodexRemotePrincipal, slackThread: String) throws -> Request {
        try available()
        guard let request = state.requests.first(where: { $0.id == id }), request.sessionID == sessionID,
              request.identity == identity, request.workspace == principal.workspace,
              request.channel == principal.channel, request.slackThread == slackThread else { throw Failure.stale }
        return request
    }

    /// Claims a request before any async work can deliver input. Replays return
    /// the same receipt; a second operation cannot consume the same request.
    func claim(operationID: String, principal: CodexRemotePrincipal, request: Request, option: Int) throws -> (Receipt, Bool) {
        try available()
        guard !operationID.isEmpty, operationID.utf8.count <= 256, option > 0 else { throw Failure.invalid }
        if let old = state.receipts.first(where: { $0.operationID == operationID && $0.principal.workspace == principal.workspace }) {
            guard old.principal == principal, old.requestID == request.id, old.option == option else { throw Failure.stale }
            return (old, false)
        }
        guard let index = state.requests.firstIndex(where: { $0.id == request.id }),
              state.requests[index].status == "pending" else { throw Failure.stale }
        guard state.receipts.count < 4096 else { throw Failure.full }
        var next = state
        next.requests[index].status = "preparing"
        let receipt = Receipt(operationID: operationID, principal: principal, requestID: request.id,
                              option: option, status: "preparing", reason: nil)
        next.receipts.append(receipt)
        try commit(next)
        return (receipt, true)
    }

    func markSending(_ receipt: Receipt) throws { try transition(receipt, from: "preparing", to: "sending", requestStatus: "sending", reason: nil) }
    func reject(_ receipt: Receipt, reason: String) throws { try transition(receipt, from: "preparing", to: "rejected", requestStatus: "resolved", reason: reason) }
    func finish(_ receipt: Receipt, sent: Bool, reason: String?) throws {
        try transition(receipt, from: "sending", to: sent ? "submitted" : "uncertain", requestStatus: sent ? "answered" : "uncertain", reason: reason)
    }
    func rejectBeforeSend(_ receipt: Receipt, reason: String) throws {
        try transition(receipt, from: "sending", to: "rejected", requestStatus: "resolved", reason: reason)
    }
    func receipt(operationID: String, principal: CodexRemotePrincipal) throws -> Receipt? {
        try available()
        return state.receipts.first { $0.operationID == operationID && $0.principal == principal }
    }

    private func transition(_ receipt: Receipt, from: String, to: String, requestStatus: String, reason: String?) throws {
        try available()
        guard let index = state.receipts.firstIndex(where: { $0.operationID == receipt.operationID && $0.principal == receipt.principal }),
              state.receipts[index].status == from,
              let requestIndex = state.requests.firstIndex(where: { $0.id == receipt.requestID }) else { throw Failure.stale }
        if from == "preparing", to == "sending", state.requests[requestIndex].status != "preparing" { throw Failure.stale }
        if to != "sending" { fence.invalidate(receipt.requestID) }
        var next = state
        next.receipts[index].status = to; next.receipts[index].reason = reason
        // An observation may already have resolved the card while delivery was
        // in flight. Do not make that obsolete card actionable again.
        if next.requests[requestIndex].status != "resolved" { next.requests[requestIndex].status = requestStatus }
        try commit(next)
    }

    private func commit(_ next: State) throws {
        try available()
        let data = try JSONEncoder().encode(next)
        guard data.count <= maxBytes else { throw Failure.full }
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            storageError = "Slack decision journal write failed; remote input is unavailable"
            fence.replace([])
            throw Failure.unavailable
        }
        state = next
        syncFence()
    }
    private func syncFence() {
        fence.replace(Set(state.requests.filter { ["pending", "preparing", "sending"].contains($0.status) }.map(\.id)))
    }
    private func available() throws { if storageError != nil { throw Failure.unavailable } }
    private static func valid(_ state: State) -> Bool {
        guard state.version == 1, state.requests.count <= 4096, state.receipts.count <= 4096 else { return false }
        let requestIDs = state.requests.map(\.id)
        guard Set(requestIDs).count == requestIDs.count else { return false }
        var keys: Set<String> = []
        return state.requests.allSatisfy { UUID(uuidString: $0.id) != nil && !$0.sessionID.isEmpty && !$0.footprint.isEmpty &&
            ["pending", "preparing", "sending", "answered", "uncertain", "resolved"].contains($0.status) } &&
            state.receipts.allSatisfy { receipt in
                let key = "\(receipt.principal.workspace.utf8.count):\(receipt.principal.workspace)\(receipt.operationID)"
                return !receipt.operationID.isEmpty && receipt.operationID.utf8.count <= 256 && receipt.option > 0 &&
                    requestIDs.contains(receipt.requestID) && keys.insert(key).inserted &&
                    ["preparing", "sending", "submitted", "rejected", "uncertain"].contains(receipt.status)
            }
    }
    enum Failure: Error { case invalid, stale, full, unavailable }
}
