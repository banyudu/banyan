import Foundation

/// Issue delivery is independent of the process supervisor's status.
public struct SessionWorkflow: Codable, Equatable, Sendable {
    public enum State: String, Codable, CaseIterable, Sendable {
        case working, waiting, verified, paused, cancelled
        case needsYou = "needs-you"

        public var label: String {
            switch self {
            case .working: return "Working"
            case .waiting: return "Auto-waiting"
            case .needsYou: return "Needs you"
            case .verified: return "Verified"
            case .paused: return "Paused"
            case .cancelled: return "Cancelled"
            }
        }

        public var permitsWake: Bool { self == .working || self == .waiting }
        public var permitsClose: Bool { [.verified, .paused, .cancelled].contains(self) }
    }

    public struct Wake: Codable, Equatable, Sendable {
        public enum Status: String, Codable, Sendable {
            case pending, delivered, uncertain
            case notDelivered = "not-delivered"
        }
        public let id: String
        public var status: Status
        public init(id: String, status: Status) { self.id = id; self.status = status }
    }

    public let owner: String
    public let jobID: String
    public let revision: Int
    public let state: State
    public let detail: String
    public var wake: Wake?

    public init(owner: String, jobID: String, revision: Int, state: State, detail: String = "", wake: Wake? = nil) {
        self.owner = owner; self.jobID = jobID; self.revision = revision
        self.state = state; self.detail = detail; self.wake = wake
    }

    public func replacing(_ next: SessionWorkflow) throws -> SessionWorkflow {
        guard owner == next.owner, jobID == next.jobID else { throw WorkflowError.refused("workflow owner does not match") }
        guard next.revision >= revision else { throw WorkflowError.refused("stale workflow revision") }
        if next.revision == revision {
            guard state == next.state, detail == next.detail else { throw WorkflowError.refused("revision already has different content") }
            return self
        }
        var result = next
        result.wake = wake
        return result
    }

    /// A retry of a delivered wake is acknowledged without another side effect.
    /// Pending/uncertain receipts require inspection, never blind redelivery.
    public func shouldDeliver(jobID: String, revision: Int, wakeID: String) throws -> Bool {
        guard self.jobID == jobID else { throw WorkflowError.refused("workflow job does not match") }
        if let wake, wake.id == wakeID {
            if wake.status == .delivered { return false }
            guard wake.status == .notDelivered else { throw WorkflowError.refused("wake delivery is uncertain; inspect the conversation") }
        }
        guard self.revision == revision else { throw WorkflowError.refused("stale workflow revision") }
        guard state.permitsWake else { throw WorkflowError.refused("workflow is \(state.rawValue)") }
        guard wake?.status != .pending, wake?.status != .uncertain else {
            throw WorkflowError.refused("previous wake delivery is uncertain; inspect the conversation")
        }
        return true
    }
}

public enum WorkflowError: Error, LocalizedError {
    case refused(String)
    case notDelivered(String)
    public var errorDescription: String? {
        switch self { case .refused(let reason), .notDelivered(let reason): return reason }
    }
}

/// A separate throwing journal keeps continuation receipts out of best-effort
/// session snapshots. Persist the intent before any input/network side effect.
public struct SessionWorkflowJournal: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private var storage: SessionJournalStorage<SessionWorkflow> {
        .init(directory: directory)
    }

    public func load(id: String) throws -> SessionWorkflow? {
        try storage.load(id: id)
    }

    public func save(_ workflow: SessionWorkflow, id: String) throws {
        try storage.save(workflow, id: id)
    }
}

public enum SessionWorkflowPolicy {
    public static func canRecover(observed: AgentAdmissionPaneInspection, current: AgentAdmissionPaneInspection) -> Bool {
        switch (observed, current) {
        case (.absent, .absent): return true
        case (.present(let before), .present(let after)):
            return before.isDead && after.isDead && before.paneID == after.paneID && before.rootPID == after.rootPID
        default: return false
        }
    }

    public static func canWake(status: SessionStatus, isSuspended: Bool, isFrozen: Bool,
                               isDeepSuspended: Bool, hasObservation: Bool, isAgent: Bool,
                               hasHumanPrompt: Bool = false, hasEmptyInput: Bool = false) -> Bool {
        isAgent && hasObservation && !isSuspended && !isFrozen && !isDeepSuspended
            && !hasHumanPrompt && ([.idle, .review].contains(status) || (status == .needInput && hasEmptyInput))
    }

    /// Used turns are need-input in the process supervisor. Require an empty
    /// native input row; never infer readiness merely from a quiet process.
    ///
    /// `text` may be a styled capture (`capture-pane -e`): faint placeholder or
    /// prompt-suggestion text inside Claude's input box then counts as empty.
    public static func hasEmptyInput(_ text: String) -> Bool {
        let capture = TerminalStyledCapture(text)
        let lines = capture.rows.map { $0.text.trimmingCharacters(in: .whitespaces) }
        if let index = lines.indices.last(where: { lines[$0].hasPrefix("›") || lines[$0].hasPrefix("❯") }) {
            let isCodexComposer = lines[index].hasPrefix("›")
            let draft = lines[index].dropFirst().trimmingCharacters(in: .whitespaces)
            // Inline TUIs leave blank rows below their output when the pane is
            // taller than the content; only drawn rows count toward the window.
            let drawnRows = (lines.lastIndex(where: { !$0.isEmpty }) ?? 0) + 1
            guard index >= max(0, drawnRows - 12) else { return false }
            if !isCodexComposer, isClaudeInputBox(lines, composer: index) {
                return isGhostOrEmpty(capture.rows[index].solidText)
                    && isClaudeFooter(lines.dropFirst(index + 2))
            }
            guard draft.isEmpty || (isCodexComposer && draft == "Ask Codex to do anything") else { return false }
            return lines.dropFirst(index + 1).allSatisfy {
                // Footer-shaped rows must match the known layout, or a clipped
                // prefix that still identifies the footer. Arbitrary overlay
                // text is not allowed.
                let row = isCodexComposer ? withoutCodexAgentsHint($0) : $0
                if isCodexComposer && row.contains(" · ") && !row.hasPrefix("? for shortcuts") {
                    return isCompleteCodexFooter(row) || isClippedCodexFooter(row)
                }
                return isKnownHintRow(row)
            }
        }
        // OpenCode's input block ends with its model/footer line. A draft,
        // picker or permission dialog contains other text inside this block.
        let block = lines.suffix(12).filter { $0.hasPrefix("┃") }
            .map { String($0.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return block.count >= 2 && block.contains("") && block.allSatisfy {
            $0.isEmpty || $0.hasPrefix("Ask anything...") || ($0.contains(" · ") && !$0.contains("?"))
        }
    }

    private static func isKnownHintRow(_ row: String) -> Bool {
        row.isEmpty || row.contains("for shortcuts") || row.contains("context left")
            || row.contains("shift+tab to cycle") || row.contains("ctrl+t to hide")
    }

    /// Claude draws its input row between two horizontal rules. Dialogs and
    /// pickers also mark a row with ❯, but never between rules, and a multi-line
    /// draft pushes the bottom rule away from the ❯ row.
    private static func isClaudeInputBox(_ lines: [String], composer index: Int) -> Bool {
        func isRule(_ position: Int) -> Bool {
            lines.indices.contains(position) && !lines[position].isEmpty && lines[position].allSatisfy { $0 == "─" }
        }
        return isRule(index - 1) && isRule(index + 1)
    }

    /// Only faint text may follow the prompt glyph: a placeholder or a
    /// suggestion, which the first typed character replaces. Plain captures
    /// carry no styling, so any text there still counts as a draft.
    private static func isGhostOrEmpty(_ solidRow: String) -> Bool {
        var row = solidRow.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("❯") { row = String(row.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return row.isEmpty
    }

    /// Below the rule Claude may print a user-configured status line before its
    /// mode/shortcut hint row. The status line is free text, so it is accepted
    /// only above a recognised hint row; nothing but blank rows may follow it.
    private static func isClaudeFooter(_ rows: ArraySlice<String>) -> Bool {
        guard let hint = rows.lastIndex(where: { !$0.isEmpty }) else { return true }
        guard isKnownHintRow(rows[hint]) else { return false }
        return rows[rows.startIndex..<hint].filter { !isKnownHintRow($0) }.count <= maxClaudeStatusLineRows
    }

    private static let maxClaudeStatusLineRows = 3

    /// Codex prefixes its empty-composer shortcut hint with the agents key
    /// (`← for agents · ? for shortcuts`).
    private static func withoutCodexAgentsHint(_ row: String) -> String {
        guard let range = row.range(of: #"\A\S{1,4} for agents · (?=\? for shortcuts)"#, options: .regularExpression)
        else { return row }
        return String(row[range.upperBound...])
    }

    private static func isCompleteCodexFooter(_ line: String) -> Bool {
        line.range(
            of: #"\A[^\s·][^·\r\n]* · [^\s·][^·\r\n]* · Context [0-9]{1,3}% used · weekly [0-9]{1,3}% left(?: · [^\s·\[\]](?:[^·\[\]\r\n]*[^\s·\[\]])? \[[A-Za-z0-9_-][A-Za-z0-9_.-]*\])?\z"#,
            options: .regularExpression) != nil
    }

    /// Codex clips its model/path/usage footer with an ellipsis when the pane
    /// is too narrow. The visible prefix still identifies the footer: it starts
    /// with the model/effort and a path, and any later field starts with a known
    /// label. Drafts and overlays do not have that shape.
    private static func isClippedCodexFooter(_ line: String) -> Bool {
        guard line.hasSuffix("…") else { return false }
        let pathClipped = #"\A[^\s·]+ [^\s·]+ · (?:~|/)[^·\r\n]*…\z"#
        let usageClipped = #"\A[^\s·]+ [^\s·]+ · (?:~|/)[^·\r\n]* · (?:Context |weekly )[^\r\n]*…\z"#
        return line.range(of: pathClipped, options: .regularExpression) != nil
            || line.range(of: usageClipped, options: .regularExpression) != nil
    }

    public static func shouldCloseVerified(workflow: SessionWorkflow?, status: SessionStatus) -> Bool {
        workflow?.state == .verified && status != .closed && ![.running, .executing, .subagents, .longRunningShell, .asking, .needInput].contains(status)
    }
}

public struct WorkflowControlPayload: Decodable {
    public let apiVersion: String?
    public let id: String?
    public let owner: String?
    public let jobID: String?
    public let revision: LenientInt?
    public let state: String?
    public let detail: String?
    public let wakeID: String?
    public let text: String?
    public let outcome: String?

    public func workflow() throws -> SessionWorkflow {
        guard let id, !id.isEmpty, let owner, !owner.isEmpty, let jobID, !jobID.isEmpty,
              let revision = revision?.value, revision >= 0,
              let state = state.flatMap(SessionWorkflow.State.init(rawValue:)) else {
            throw WorkflowError.refused("id, owner, jobID, non-negative revision and valid state are required")
        }
        return SessionWorkflow(owner: owner, jobID: jobID, revision: revision, state: state, detail: detail ?? "")
    }
}
