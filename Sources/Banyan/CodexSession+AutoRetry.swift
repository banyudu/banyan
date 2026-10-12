import BanyanCore
import Foundation

extension CodexSession {
    func receiveCodexRetryEvent(method: String, params: CodexJSONValue) {
        let fields = params.objectValue ?? [:]
        let turn = fields["turn"]?.objectValue ?? [:]
        guard let turnID = fields["turnId"]?.stringValue ?? turn["id"]?.stringValue else { return }
        if method == "turn/started" {
            codexRetryLatestTurnID = turnID
            codexOwnsRetryTurnID = nil
            return
        }
        if method == "error" {
            if fields["willRetry"] == .bool(true) { codexOwnsRetryTurnID = turnID }
            else if codexOwnsRetryTurnID == turnID { codexOwnsRetryTurnID = nil }
            return
        }
        guard method == "turn/completed", state.activeTurnID == nil,
              codexRetryLatestTurnID == nil || codexRetryLatestTurnID == turnID else { return }
        codexRetryLatestTurnID = turnID
        guard turn["status"]?.stringValue == "failed" else {
            if turn["status"]?.stringValue == "completed" { codexAutoRetry.reset() }
            else { codexAutoRetry.cancel() }
            return
        }
        guard autoRetryCodexFailures, codexOwnsRetryTurnID != turnID,
              status != .closed, !isSuspended, draft.isEmpty, !state.needsAttention,
              let error = turn["error"], let reason = CodexRetryPolicy.reason(error: error) else {
            codexAutoRetry.cancel()
            return
        }
        let binding = state.binding
        let generation = codexAutoRetry.generation
        codexAutoRetry.schedule(failureID: "\(binding.threadID ?? ""):" + turnID, reason: reason) { [weak self] in
            guard let self else { throw CancellationError() }
            let authorize = { [weak self] in
                guard let self, self.autoRetryCodexFailures, self.codexAutoRetry.generation == generation,
                      self.status != .closed, !self.isSuspended, self.draft.isEmpty,
                      self.state.binding == binding, self.codexRetryLatestTurnID == turnID,
                      !self.state.needsAttention, self.state.activeTurnID == nil else { throw CancellationError() }
            }
            try authorize()
            let input: [CodexJSONValue] = [.object(["type": .string("text"), "text": .string(CodexRetryPolicy.continuation)])]
            _ = try await self.coordinator.startTurn(sessionID: self.id, input: input, authorization: authorize)
        }
    }
}
