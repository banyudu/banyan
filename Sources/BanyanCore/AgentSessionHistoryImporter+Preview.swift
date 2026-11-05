import Foundation

extension AgentSessionHistoryImporter {

    public static func transcriptPreview(from url: URL, provider: CodingAgentProvider, maxMessages: Int = 40) -> String {
        let lines = readLinePrefix(from: url, maxLines: 800, maxBytes: 2_000_000)
        let messages = lines.compactMap { line -> String? in
            guard let object = jsonObject(from: line) else { return nil }
            switch provider {
            case .codex:
                return codexPreviewLine(object)
            case .claude:
                return claudePreviewLine(object)
            default:
                return nil
            }
        }
        let preview = messages.prefix(maxMessages).joined(separator: "\n\n")
        return preview.isEmpty ? "No readable transcript preview is available for this history file." : preview
    }

    private static func codexPreviewLine(_ object: [String: Any]) -> String? {
        guard let type = object["type"] as? String else { return nil }
        if type == "session_meta", let payload = object["payload"] as? [String: Any] {
            let cwd = payload["cwd"] as? String
            return cwd.map { "Session started in \($0)" }
        }
        guard let payload = object["payload"] as? [String: Any] else { return nil }
        if let message = payload["message"] as? [String: Any],
           let role = message["role"] as? String,
           let content = plainText(from: message["content"]) {
            return "\(role.capitalized): \(content)"
        }
        if let text = payload["text"] as? String, let title = sanitizedBody(text) {
            return title
        }
        return nil
    }

    static func codexUserPrompt(_ object: [String: Any]) -> String? {
        guard let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else { return nil }
        if type == "event_msg",
           payload["type"] as? String == "user_message",
           let message = payload["message"] as? String {
            return sanitizedBody(message)
        }
        // Newer Codex rollouts record prompts as `response_item` messages
        // (`payload.type == "message"`, `role == "user"`) instead of
        // `event_msg` / `user_message`. The first such message is the injected
        // AGENTS.md bundle, not a user prompt, so it must be skipped or every
        // new session would title itself after the instructions header.
        if type == "response_item",
           payload["type"] as? String == "message",
           (payload["role"] as? String)?.lowercased() == "user",
           let text = plainText(from: payload["content"]),
           !isCodexAgentsMDInstructions(text) {
            return sanitizedBody(text)
        }
        return nil
    }

    private static func isCodexAgentsMDInstructions(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("# AGENTS.md") { return true }
        if trimmed.contains("<INSTRUCTIONS>") { return true }
        if trimmed.contains("Treat `~/.agents` as the source of truth") { return true }
        return false
    }

    private static func claudePreviewLine(_ object: [String: Any]) -> String? {
        guard let type = object["type"] as? String,
              ["user", "assistant"].contains(type),
              let message = object["message"] as? [String: Any],
              let role = message["role"] as? String,
              let content = plainText(from: message["content"]) else {
            return nil
        }
        if type == "user", isSkippableClaudeUserObject(object) {
            return nil
        }
        return "\(role.capitalized): \(content)"
    }

    private static func plainText(from value: Any?) -> String? {
        if let text = value as? String {
            return sanitizedBody(text)
        }
        guard let parts = value as? [[String: Any]] else { return nil }
        let texts = parts.compactMap { part -> String? in
            if let text = part["text"] as? String {
                return text
            }
            if let content = part["content"] as? String {
                return content
            }
            return nil
        }
        return sanitizedBody(texts.joined(separator: "\n"))
    }

    static func sanitizedTitle(_ value: String?) -> String? {
        guard let body = sanitizedBody(value) else { return nil }
        let normalized = SessionTitleGenerator.replacingImagePlaceholders(in: body)
        let firstLine = SessionTitleGenerator.firstPromptTitleLine(in: normalized)
        let collapsed = firstLine.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "__cache-warm-ping__" else { return nil }
        return String(trimmed.prefix(80))
    }

    static func sanitizedBody(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, trimmed.isEmpty == false else { return nil }
        guard !isClaudeLocalCommandText(trimmed) else { return nil }
        return trimmed
    }

    static func isSkippableClaudeUserObject(_ object: [String: Any]) -> Bool {
        if object["isMeta"] as? Bool == true {
            return true
        }
        guard let message = object["message"] as? [String: Any] else {
            return false
        }
        return isClaudeLocalCommandContent(message["content"])
    }

    private static func isClaudeLocalCommandContent(_ value: Any?) -> Bool {
        if let text = value as? String {
            return isClaudeLocalCommandText(text)
        }
        guard let parts = value as? [[String: Any]] else {
            return false
        }
        return parts.contains { part in
            if let text = part["text"] as? String, isClaudeLocalCommandText(text) {
                return true
            }
            if let content = part["content"] as? String, isClaudeLocalCommandText(content) {
                return true
            }
            return false
        }
    }

    private static func isClaudeLocalCommandText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let localCommandTags = [
            "command-args",
            "command-message",
            "command-name",
            "local-command-caveat",
            "local-command-stderr",
            "local-command-stdout"
        ]
        return localCommandTags.contains { tag in
            trimmed.range(
                of: #"^<\#(tag)(?:\s[^>]*)?>"#,
                options: .regularExpression
            ) != nil
        }
    }
}
