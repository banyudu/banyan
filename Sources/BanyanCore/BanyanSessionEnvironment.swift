import Foundation

/// Environment contract between Banyan sessions and processes running inside
/// them (agents, `workit`, `banyanctl`, user shells).
///
/// Every tmux session Banyan creates carries `BANYAN_SESSION_ID=<id>` in its
/// session environment (`tmux new-session -e`), so anything spawned from
/// inside the session can discover its enclosing Banyan session without
/// asking the control server. Spawners use that identity to default
/// `--parent` to the calling session, which keeps `spawn ENG-123`-style flows
/// nested under the session they were launched from.
///
/// The banyan-side default resolution order is:
///   1. explicit `--parent` / `--no-parent` on the command line,
///   2. `$BANYAN_PARENT_SESSION_ID` (explicit override), then `$BANYAN_SESSION_ID`,
///   3. the enclosing tmux session name (`banyan-<id>`) when running inside tmux —
///      this covers sessions created before the `-e` injection existed.
///   4. no parent (top-level session).
public enum BanyanSessionEnvironment {
    /// Session environment variable set on every tmux session Banyan creates.
    public static let sessionIDKey = "BANYAN_SESSION_ID"
    /// Optional override: when set, spawners prefer this over `sessionIDKey`.
    /// Mirrors what `workit` already honors.
    public static let parentSessionIDKey = "BANYAN_PARENT_SESSION_ID"

    /// Pure env-dict lookup shared by `banyanctl` (and any future spawner).
    /// Returns the trimmed value, or nil when unset/blank.
    public static func parentSessionID(from environment: [String: String]) -> String? {
        for key in [parentSessionIDKey, sessionIDKey] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Recovers a Banyan session id from a tmux session name.
    /// Tmux names are `banyan-<id>` by construction
    /// (`SessionIdentityPolicy.sessionName(for:)`); anything else yields nil.
    public static func sessionID(fromTmuxSessionName name: String) -> String? {
        let prefix = SessionIdentityPolicy.sessionName(for: "")
        guard name.hasPrefix(prefix) else { return nil }
        let id = String(name.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
}
