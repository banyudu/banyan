import BanyanCore
import AppKit
import Foundation
import Network

extension ControlServer {
    /// Decodes a request body, then lets any query string override it.
    ///
    /// `/output` and `/events` are documented as GETs with parameters, and a GET
    /// carries no body — so the query string has to reach the same payload type
    /// the POST routes decode.
    func payload(for request: HTTPControlRequest) throws -> ControlPayload {
        let query = ControlRoute.queryItems(in: request.path)
        guard !query.isEmpty else {
            return try request.decode(ControlPayload.self)
        }
        var merged = try JSONSerialization.jsonObject(
            with: request.body.isEmpty ? Data("{}".utf8) : request.body
        ) as? [String: Any] ?? [:]
        for (name, value) in query {
            merged[name] = value
        }
        let data = try JSONSerialization.data(withJSONObject: merged)
        return try JSONDecoder().decode(ControlPayload.self, from: data)
    }

    @MainActor
    func spawnPuckSession(
        store: SessionStore,
        binding: PuckSessionBinding,
        body: ControlPayload,
        parentSessionID: String?,
        tone: SessionTone,
        select: Bool,
        respond: @escaping @MainActor (Response) -> Void
    ) {
        let expiresAt = Date().addingTimeInterval(4)
        Task { @MainActor in
            do {
                let session = try await store.createPuckSession(
                    binding: binding,
                    cwd: body.cwd,
                    id: body.id,
                    title: body.title,
                    titleURL: body.titleURL,
                    parentSessionID: parentSessionID,
                    tone: tone,
                    prompt: nil,
                    select: select
                )
                if let prompt = body.agentPrompt, !prompt.isEmpty {
                    _ = try await store.startPuckTurnImmediately(id: session.id, prompt: prompt, expiresAt: expiresAt)
                }
                respond(.ok(["session": self.summary(session)]))
            } catch let error as PuckTurnError {
                respond(.failure(502, "puck_turn_failed", error.localizedDescription))
            } catch let error as ControlError {
                respond(.failure(error.httpStatus, error.code, error.localizedDescription))
            } catch let error as PuckDaemonError {
                if case .unavailable = error {
                    respond(.failure(503, "puck_create_failed", error.localizedDescription))
                } else {
                    respond(.failure(400, "puck_create_failed", error.localizedDescription))
                }
            } catch {
                respond(.failure(400, "puck_create_failed", error.localizedDescription))
            }
        }
    }

    // MARK: - Pane routes

    @MainActor
    func readOutput(
        store: SessionStore,
        body: ControlPayload,
        respond: @escaping @MainActor (Response) -> Void
    ) {
        let id = body.id!
        let lines = body.lines.map { max(1, min(2_000, $0.value)) }
        Task { @MainActor in
            do {
                let reading = try await store.readPaneOutput(id: id, lines: lines)
                respond(.ok(self.outputBody(id: id, store: store, reading: reading)))
            } catch {
                respond(self.failure(for: error))
            }
        }
    }

    @MainActor
    func sendInput(
        store: SessionStore,
        body: ControlPayload,
        respond: @escaping @MainActor (Response) -> Void
    ) {
        let id = body.id!
        var keys: [TmuxKey] = []
        for name in body.keys ?? [] {
            guard let key = TmuxKey(name: name) else {
                return respond(.failure(
                    400,
                    "unknown_key",
                    "unknown key '\(name)'; allowed: \(TmuxKey.allCases.map(\.rawValue).joined(separator: ", "))"
                ))
            }
            keys.append(key)
        }
        let text = body.text
        let submit = body.submit?.value ?? false
        Task { @MainActor in
            do {
                let receipt = try await store.injectInput(id: id, keys: keys, text: text, submit: submit)
                respond(.ok([
                    "id": id,
                    "paneID": receipt.paneID,
                    "keys": receipt.keys.map(\.rawValue),
                    "text": receipt.text ?? ""
                ]))
            } catch {
                respond(self.failure(for: error))
            }
        }
    }

    @MainActor
    func sendAnswer(
        store: SessionStore,
        body: ControlPayload,
        respond: @escaping @MainActor (Response) -> Void
    ) {
        let id = body.id!
        var choice: AgentPromptChoice?
        if let raw = body.choice, !raw.isEmpty {
            guard let parsed = AgentPromptChoice(name: raw) else {
                return respond(.failure(
                    400,
                    "unknown_choice",
                    "unknown choice '\(raw)'; allowed: \(AgentPromptChoice.allCases.map(\.rawValue).joined(separator: ", "))"
                ))
            }
            choice = parsed
        }
        let request = AgentAnswerRequest(
            option: body.option?.value,
            choice: choice,
            confirm: body.confirm?.value ?? false,
            footprint: body.footprint!
        )
        Task { @MainActor in
            do {
                let receipt = try await store.answerPrompt(id: id, request: request)
                switch receipt.decision {
                case .send(let keys, let option):
                    var payload = self.outputBody(id: id, store: store, reading: receipt.reading)
                    payload["sent"] = true
                    payload["keys"] = keys.map(\.rawValue)
                    payload["option"] = option.index
                    payload["optionLabel"] = option.label
                    respond(.ok(payload))
                case .reject(let rejection):
                    // A refusal still carries the current reading, so a delivery
                    // target can redraw what the session actually shows now instead
                    // of asking again.
                    respond(Response(
                        status: rejection.httpStatus,
                        data: self.outputBody(id: id, store: store, reading: receipt.reading),
                        error: ControlErrorBody(code: rejection.rawValue, message: rejection.message)
                    ))
                }
            } catch {
                respond(self.failure(for: error))
            }
        }
    }
}
