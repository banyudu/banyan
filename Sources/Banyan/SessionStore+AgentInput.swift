import BanyanCore
import Foundation

/// Everything a pane operation needs about a session, snapshotted on the main
/// actor so the tmux subprocesses themselves can run off it. Reading a pane costs
/// several `tmux` invocations plus a process-table walk; doing that inline on the
/// main actor would hitch the UI for every control request.
struct SessionPaneTarget: Sendable {
    let id: String
    let tmuxSessionName: String
    let command: String
    let status: SessionStatus
    let cwd: String
    let createdAt: Date
    let environment: [String: String]
    /// Parked sessions are deliberately outside the supervision loop, so a pane
    /// operation has to decide what to do about one rather than quietly resume it.
    let isSuspended: Bool
}

/// One reading of a session's pane: what it shows, and what — if anything — it is
/// blocked on.
struct SessionPaneReading: Sendable {
    let paneID: String
    let status: SessionStatus
    let visibleText: String
    /// Non-nil only when the supervisor agrees the session is waiting on a human.
    /// Parsed from the same capture the supervisor classified, never a second one.
    let prompt: AgentPrompt?
    /// The supervisor's verdict, when it had one, so the caller can fold this
    /// reading back into the sidebar exactly as a tick would. Absent for a parked
    /// session, which was not observed at all.
    let observation: SessionStatusObservation?
    let isSuspended: Bool
}

struct SessionInputReceipt: Sendable {
    let paneID: String
    let keys: [TmuxKey]
    let text: String?
}

struct SessionAnswerReceipt: Sendable {
    let decision: AgentAnswerDecision
    let reading: SessionPaneReading
}

extension SessionStore {
    // MARK: - Reading

    /// Reads a session's pane text and the prompt it is blocked on.
    ///
    /// `lines` only widens the *text* returned for context. The prompt is always
    /// parsed from the supervisor's own capture, because the supervisor's verdict
    /// is what makes the prompt safe to act on — parsing a second, later capture
    /// would let an answer be offered for a question the classification never saw.
    /// A parked session is read but never observed: its status stays frozen at what
    /// was last seen, and no prompt is offered. Parking is the user saying "stop
    /// watching this", so supervising one on demand would undo the thing they
    /// asked for — and an answer injected into a pane Banyan is not rendering
    /// would land somewhere nobody is looking.
    func readPaneOutput(id: String, lines: Int?) async throws -> SessionPaneReading {
        let target = try paneTarget(id: id)
        let backend = tmuxBackend
        let processes = processTable.snapshot()
        let requestedLines = lines
        guard let reading = await Task.detached(priority: .userInitiated, operation: {
            Self.read(target, lines: requestedLines, backend: backend, processTable: processes)
        }).value else {
            throw ControlError.badRequest("session '\(id)' has no live tmux pane")
        }
        absorb(reading, for: id)
        return reading
    }

    // MARK: - Writing

    /// Injects raw keys and/or literal text.
    ///
    /// Deliberately ungated on session status: this is the low-level primitive,
    /// and typing into a session that is *not* blocked is a legitimate use (a
    /// respawn prompt, a scripted `/clear`). Its trust boundary is the control
    /// token, the same one that already authorizes spawning arbitrary commands.
    /// The bounded, prompt-aware path a delivery target is meant to use is
    /// `answerPrompt`.
    func injectInput(id: String, keys: [TmuxKey], text: String?, submit: Bool) async throws -> SessionInputReceipt {
        let target = try paneTarget(id: id)
        try Self.refuseIfSuspended(target)
        let backend = tmuxBackend
        guard let paneID = await Task.detached(priority: .userInitiated, operation: {
            backend.primaryPaneSnapshot(named: target.tmuxSessionName)?.paneID
        }).value else {
            throw ControlError.badRequest("session '\(id)' has no live tmux pane")
        }

        // Text first, then keys: a caller sending both means "type this, then
        // press that", which is the order a human would use.
        let trailingKeys = submit ? keys + [.enter] : keys
        let literal = text
        do {
            try await Task.detached(priority: .userInitiated, operation: {
                if let literal, !literal.isEmpty {
                    try backend.sendLiteral(paneID: paneID, text: literal)
                }
                if !trailingKeys.isEmpty {
                    try backend.sendKeys(paneID: paneID, keys: trailingKeys)
                }
            }).value
        } catch {
            throw ControlError.badRequest("could not send input to session '\(id)': \(error.localizedDescription)")
        }

        noteInjection(id: id)
        return SessionInputReceipt(paneID: paneID, keys: trailingKeys, text: literal)
    }

    /// Answers the prompt a session is blocked on, or refuses and sends nothing.
    ///
    /// Re-reads the pane first: the answer was written against a prompt a human
    /// saw some time ago, and the only way to know it is still on screen is to
    /// look now. Every rejection path returns before a single keystroke is sent.
    func answerPrompt(id: String, request: AgentAnswerRequest) async throws -> SessionAnswerReceipt {
        try Self.refuseIfSuspended(paneTarget(id: id))
        let reading = try await readPaneOutput(id: id, lines: nil)
        let decision = decideAnswer(id: id, request: request, reading: reading)
        guard case .send(let keys, _) = decision else {
            return SessionAnswerReceipt(decision: decision, reading: reading)
        }

        let backend = tmuxBackend
        let paneID = reading.paneID
        do {
            try await Task.detached(priority: .userInitiated, operation: {
                try backend.sendKeys(paneID: paneID, keys: keys)
            }).value
        } catch {
            // The footprint was consumed before the send so a redelivery arriving
            // mid-flight cannot double-inject. A genuine tmux failure releases it
            // again, because nothing reached the pane.
            releaseConsumedAnswer(id: id)
            throw ControlError.badRequest("could not answer session '\(id)': \(error.localizedDescription)")
        }

        noteInjection(id: id)
        return SessionAnswerReceipt(decision: decision, reading: reading)
    }

    // MARK: - Pane work (off the main actor)

    /// Parking means "Banyan is not watching this". Typing into one would put the
    /// answer somewhere the user has told the app not to render, so both write
    /// paths refuse and name the reason — a delivery target can then retire a
    /// message it is holding rather than retry forever.
    nonisolated static func refuseIfSuspended(_ target: SessionPaneTarget) throws {
        guard target.isSuspended else { return }
        throw ControlError.conflict(
            code: "session_suspended",
            message: "session '\(target.id)' is parked; resume it before sending input"
        )
    }

    nonisolated private static func read(
        _ target: SessionPaneTarget,
        lines: Int?,
        backend: any TmuxSessionStoreBackend,
        processTable: ProcessTable
    ) -> SessionPaneReading? {
        guard let pane = backend.primaryPaneSnapshot(named: target.tmuxSessionName) else { return nil }

        guard !target.isSuspended else {
            // Read the pane, observe nothing. One capture in answer to an explicit
            // request is not the supervision loop parking switched off.
            return SessionPaneReading(
                paneID: pane.paneID,
                status: target.status,
                visibleText: backend.captureVisibleText(
                    paneID: pane.paneID,
                    lineLimit: lines ?? AgentSupervisor.captureLineLimit
                ),
                prompt: nil,
                observation: nil,
                isSuspended: true
            )
        }

        let supervisor = AgentSupervisor(backend: backend, processTable: processTable)
        let result = supervisor.inspect(
            tmuxSessionName: target.tmuxSessionName,
            launchCommand: target.command,
            currentStatus: target.status,
            cwd: target.cwd,
            sessionStartedAt: target.createdAt,
            environment: target.environment,
            paneSnapshot: pane
        )

        let status = result?.status ?? target.status
        let classifiedText = result?.visibleText
        // Only the supervisor's own capture can produce a prompt. When it declined
        // to classify at all, the persisted status is all we have and it may be
        // stale, so no options are offered.
        let prompt = AgentPromptGate.prompt(status: status, classifiedText: classifiedText)

        let requested = lines ?? AgentSupervisor.captureLineLimit
        let visibleText: String = if requested == AgentSupervisor.captureLineLimit, let classifiedText {
            classifiedText
        } else {
            backend.captureVisibleText(paneID: pane.paneID, lineLimit: requested)
        }

        return SessionPaneReading(
            paneID: pane.paneID,
            status: status,
            visibleText: visibleText,
            prompt: prompt,
            observation: result.map { result in
                SessionStatusObservation(
                    id: target.id,
                    status: result.status,
                    tone: result.tone,
                    provider: result.provider,
                    modelID: result.modelID,
                    modelIDIsExact: result.modelIDIsExact,
                    currentPath: result.currentPath
                )
            },
            isSuspended: false
        )
    }
}
