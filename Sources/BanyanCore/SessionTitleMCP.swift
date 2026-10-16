import Foundation

/// A session-scoped MCP tool. The host binds the target session; the model can
/// supply only a title, never a different session ID or a shell command.
public enum SessionTitleMCP {
    public static let subcommand = "__session-title-mcp"
    public static let serverName = "banyan_session"
    public static let toolName = "rename_session"
    public static let instructions = """
    Keep this Banyan session recognizable: call rename_session once the task is clear, \
    then when a significant finding or outcome changes its meaning. Use a specific \
    subject and symptom/cause, e.g. "Checkout timeout: exhausted DB pool", rather than \
    repeating "what happened on this URL". Keep it under 56 characters, use the user's \
    language, and never present a hypothesis as confirmed. Avoid renaming for routine \
    progress. Only the main agent should rename; subagents must not. Manual titles are preserved.
    """

    public static func normalizedTitle(_ value: String) -> String? {
        let cleaned = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) })
        guard let title = SessionTitleGenerator.sanitizeTitle(cleaned),
              SessionTitleGenerator.isUsefulTitle(title) else { return nil }
        return title
    }

    /// Newline-delimited JSON-RPC, with no responses to notifications. Transport
    /// and authenticated localhost writes live in banyanctl, keeping this testable.
    public static func response(to data: Data, updateTitle: (String) throws -> Bool) -> Data? {
        func encode(_ object: [String: Any]) -> Data? {
            try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        func error(_ id: Any, _ code: Int, _ message: String) -> Data? {
            encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
        }
        guard data.count <= 65_536,
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return error(NSNull(), -32700, "Invalid JSON request")
        }
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
            return error(request["id"] ?? NSNull(), -32600, "Invalid JSON-RPC request")
        }
        guard let id = request["id"] else { return nil }
        let params = request["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
            result = [
                "protocolVersion": supported.contains(requested) ? requested : "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": serverName, "version": "1.0.0"],
                "instructions": instructions
            ]
        case "ping": result = [:]
        case "tools/list":
            result = ["tools": [[
                "name": toolName,
                "description": "Rename this Banyan session to reflect the concrete task, significant findings, or outcome. " + instructions,
                "inputSchema": [
                    "type": "object", "properties": ["title": ["type": "string", "minLength": 1, "maxLength": 200]],
                    "required": ["title"], "additionalProperties": false
                ],
                "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
            ]]]
        case "tools/call":
            guard params["name"] as? String == toolName else {
                return error(id, -32602, "Unknown tool")
            }
            guard let arguments = params["arguments"] as? [String: Any],
                  Set(arguments.keys) == ["title"],
                  let raw = arguments["title"] as? String, raw.count <= 200,
                  let title = normalizedTitle(raw) else {
                return error(id, -32602, "Provide one nonempty, specific title (at most 200 characters)")
            }
            do {
                let applied = try updateTitle(title)
                result = ["content": [["type": "text", "text": applied
                    ? "Session title updated to: \(title)"
                    : "Manual session title preserved. Do not retry renaming this session."]], "isError": false]
            } catch {
                result = ["content": [["type": "text", "text": "Could not update the session title: \(error.localizedDescription)"]], "isError": true]
            }
        default: return error(id, -32601, "Method not found")
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }
}
