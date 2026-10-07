import BanyanCore

/// Keep native backend names and their binding/provenance intact. Only the
/// app's terminal backend needs the historical CLI name, "tmux".
enum UnifiedSessionCatalog {
    static func appRow(_ session: [String: Any]) -> [String: Any] {
        var row = session
        if row["backend"] == nil || row["backend"] as? String == SessionBackendKind.terminal.rawValue {
            row["backend"] = "tmux"
        }
        return row
    }
}
