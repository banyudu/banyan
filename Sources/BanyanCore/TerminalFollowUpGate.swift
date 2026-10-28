import Foundation

/// A remote reply may enter only an empty, recognizable Codex composer. This
/// deliberately refuses unknown TUI layouts and partially typed local drafts.
public enum TerminalFollowUpGate {
    public static func permits(provider: CodingAgentProvider?, status: SessionStatus, paneInMode: Bool,
                               isSuspended: Bool, isFrozen: Bool, isDeepSuspended: Bool, visibleText: String) -> Bool {
        guard provider == .codex, [.idle, .needInput].contains(status), !paneInMode,
              !isSuspended, !isFrozen, !isDeepSuspended,
              AgentPromptParser.parse(visibleText: visibleText) == nil,
              !AgentSupervisor.looksLikeAgentExecuting(visibleText) else { return false }
        let tail = visibleText.split(separator: "\n", omittingEmptySubsequences: false).suffix(12)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Avoid a picker or search overlay drawn over the composer even when the
        // prompt parser cannot confidently interpret its choices.
        guard !tail.contains(where: { line in
            let lower = line.lowercased()
            return lower.contains("select model") || lower.contains("choose an option") ||
                lower.contains("search models") || lower.contains("press enter to select") ||
                line.range(of: #"^[›❯]\s*[0-9]+[.)]"#, options: .regularExpression) != nil
        }) else { return false }
        // A bare arrow is also used by pickers. It is not enough evidence of
        // an input field, even if the surrounding footer looks familiar.
        guard let marker = tail.lastIndex(where: { $0 == "› Ask Codex to do anything" }) else { return false }
        // The composer must be in the final visible area, with only known footer
        // lines after it. Unknown overlays or typed drafts fail closed.
        return tail[tail.index(after: marker)...].allSatisfy { line in
            if line.isEmpty || line.allSatisfy({ "─━═┄┅┈┉".contains($0) }) { return true }
            if line.range(of: #"\A\? for shortcuts(?:\s+⚠\s+[0-9]+ warnings? · f2 to view)?\z"#,
                          options: .regularExpression) != nil { return true }
            // Match the entire model/status footer, not a hint word that may
            // also appear in a draft, menu item or unrecognized overlay.
            return line.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._/-]*(?: [A-Za-z0-9_-]+){0,4} · (?:[^·\r\n]+ · )?Context [0-9]{1,3}%(?: used)?(?: · weekly [0-9]{1,3}% left)?(?: · [^·\[\]\r\n]+ \[[A-Za-z0-9_.-]+\])?\z"#,
                              options: .regularExpression) != nil
        }
    }

    /// Literal tmux input is intentionally restricted to one printable line;
    /// multiline paste requires a separately verified bracketed-paste path.
    public static func acceptsText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 16_384 &&
            text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
