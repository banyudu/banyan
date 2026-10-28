import BanyanCore
import CryptoKit
import Foundation

/// Write-ahead receipts for literal terminal input. Only a digest of the text
/// is retained; uncertain sends block later replies until local reconciliation.
@MainActor
final class SlackFollowUpJournal {
    struct Receipt: Codable, Equatable {
        let operationID: String
        let principal: CodexRemotePrincipal
        let sessionID: String
        let identity: SlackConversationIdentity
        let slackThread: String
        let textDigest: String
        let textBytes: Int
        var status: String
        var reason: String?
    }
    private struct State: Codable { var version = 1; var receipts: [Receipt] = [] }
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
                for index in decoded.receipts.indices {
                    if decoded.receipts[index].status == "sending" { decoded.receipts[index].status = "uncertain" }
                    if decoded.receipts[index].status == "preparing" {
                        decoded.receipts[index].status = "rejected"; decoded.receipts[index].reason = "interrupted_before_send"
                    }
                }
                state = decoded
            } else { state = State() }
        } catch {
            state = State()
            storageError = "Slack reply journal is unavailable; preserve and repair it locally"
        }
        syncFence()
    }

    func claim(operationID: String, principal: CodexRemotePrincipal, sessionID: String,
               identity: SlackConversationIdentity, slackThread: String, text: String) throws -> (Receipt, Bool) {
        try available()
        guard !operationID.isEmpty, operationID.utf8.count <= 256, !sessionID.isEmpty,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 16_384,
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw Failure.invalid }
        let digest = Self.digest(text)
        if let old = state.receipts.first(where: { $0.operationID == operationID && $0.principal.workspace == principal.workspace }) {
            guard old.principal == principal, old.sessionID == sessionID, old.identity == identity,
                  old.slackThread == slackThread, old.textDigest == digest, old.textBytes == text.utf8.count else { throw Failure.conflict }
            return (old, false)
        }
        guard !state.receipts.contains(where: { $0.sessionID == sessionID && ["preparing", "sending", "uncertain"].contains($0.status) }) else {
            throw Failure.unresolved
        }
        guard state.receipts.count < 4096 else { throw Failure.full }
        let receipt = Receipt(operationID: operationID, principal: principal, sessionID: sessionID,
            identity: identity, slackThread: slackThread, textDigest: digest, textBytes: text.utf8.count,
            status: "preparing", reason: nil)
        var next = state; next.receipts.append(receipt); try commit(next)
        return (receipt, true)
    }

    func markSending(_ receipt: Receipt) throws { try transition(receipt, from: "preparing", to: "sending", reason: nil) }
    func reject(_ receipt: Receipt, reason: String) throws { try transition(receipt, from: "preparing", to: "rejected", reason: reason) }
    func rejectBeforeSend(_ receipt: Receipt, reason: String) throws { try transition(receipt, from: "sending", to: "rejected", reason: reason) }
    func finish(_ receipt: Receipt, sent: Bool) throws {
        try transition(receipt, from: "sending", to: sent ? "submitted" : "uncertain", reason: sent ? nil : "delivery_outcome_unknown")
    }
    func receipt(operationID: String, principal: CodexRemotePrincipal) throws -> Receipt? {
        try available()
        return state.receipts.first { $0.operationID == operationID && $0.principal == principal }
    }
    /// Local administration only, after inspecting the desktop conversation.
    /// Retains the receipt as a tombstone and never resubmits the text.
    func acknowledgeUncertain(operationID: String, workspace: String) throws {
        try available()
        guard let index = state.receipts.firstIndex(where: { $0.operationID == operationID && $0.principal.workspace == workspace }),
              state.receipts[index].status == "uncertain" else { throw Failure.invalid }
        var next = state
        next.receipts[index].status = "acknowledged"; next.receipts[index].reason = "locally_reconciled"
        try commit(next)
    }

    private func transition(_ receipt: Receipt, from: String, to: String, reason: String?) throws {
        try available()
        guard let index = state.receipts.firstIndex(where: { $0.operationID == receipt.operationID && $0.principal == receipt.principal }),
              state.receipts[index].status == from else { throw Failure.conflict }
        if to != "sending" { fence.invalidate(Self.key(receipt)) }
        var next = state; next.receipts[index].status = to; next.receipts[index].reason = reason
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
            storageError = "Slack reply journal write failed; remote input is unavailable"
            fence.replace([])
            throw Failure.unavailable
        }
        state = next; syncFence()
    }
    private func syncFence() {
        fence.replace(Set(state.receipts.filter { ["preparing", "sending"].contains($0.status) }.map(Self.key)))
    }
    static func key(_ receipt: Receipt) -> String { "\(receipt.principal.workspace.utf8.count):\(receipt.principal.workspace)\(receipt.operationID)" }
    private func available() throws { if storageError != nil { throw Failure.unavailable } }
    private static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func valid(_ state: State) -> Bool {
        guard state.version == 1, state.receipts.count <= 4096 else { return false }
        var keys: Set<String> = []
        return state.receipts.allSatisfy { receipt in
            !receipt.operationID.isEmpty && receipt.operationID.utf8.count <= 256 && !receipt.sessionID.isEmpty &&
            !receipt.principal.workspace.isEmpty && !receipt.principal.channel.isEmpty && !receipt.principal.user.isEmpty &&
            receipt.textBytes > 0 && receipt.textBytes <= 16_384 && receipt.textDigest.count == 64 &&
            receipt.textDigest.allSatisfy { $0.isHexDigit } && keys.insert(key(receipt)).inserted &&
            ["preparing", "sending", "submitted", "rejected", "uncertain", "acknowledged"].contains(receipt.status)
        }
    }
    enum Failure: Error { case invalid, conflict, unresolved, full, unavailable }
}
