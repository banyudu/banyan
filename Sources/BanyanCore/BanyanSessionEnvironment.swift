import Foundation

/// Environment contract between Banyan sessions and processes running inside
/// them (agents, `workit`, `banyanctl`, user shells).
///
/// Every tmux session Banyan creates carries `BANYAN_SESSION_ID=<id>` in its
/// session environment (`tmux new-session -e`), so anything spawned from
/// inside the session can discover its enclosing Banyan session without
/// asking the control server. Spawners use that identity to default
/// `--parent` to the calling session, which keeps `spawn TASK-123`-style flows
/// nested under the session they were launched from.
///
/// The banyan-side default resolution order is:
///   1. explicit `--parent` / `--no-parent` on the command line,
///   2. `$BANYAN_PARENT_SESSION_ID` (explicit override),
///   3. the enclosing tmux session name (`banyan-<id>`) when running inside tmux,
///   4. `$BANYAN_SESSION_ID`,
///   5. no parent (top-level session).
///
/// The tmux identity comes before `$BANYAN_SESSION_ID` because long-lived
/// processes can inherit an old pane environment after their tmux server or
/// Banyan session has gone away. The live pane is the current enclosing
/// session; the inherited variable is only a fallback for callers that have no
/// tmux context.
public enum BanyanSessionEnvironment {
    /// Session environment variable set on every tmux session Banyan creates.
    public static let sessionIDKey = "BANYAN_SESSION_ID"
    /// Optional override: when set, spawners prefer this over `sessionIDKey`.
    /// Mirrors what `workit` already honors.
    public static let parentSessionIDKey = "BANYAN_PARENT_SESSION_ID"

    /// The app is a host, not a child of the pane that launched it. Tmux keys
    /// must also go so helpers cannot rediscover that pane as their parent.
    public static let inheritedContextKeys: Set<String> = [
        sessionIDKey, parentSessionIDKey, "TMUX", "TMUX_PANE"
    ]

    public static func appEnvironment(from environment: [String: String]) -> [String: String] {
        environment.filter { !inheritedContextKeys.contains($0.key) }
    }

    /// Pure lookup shared by `banyanctl` (and any future spawner). An explicit
    /// parent override wins, then the live enclosing tmux session, then the
    /// inherited session identity. Values are trimmed; blank values are nil.
    public static func parentSessionID(
        from environment: [String: String],
        enclosingTmuxSessionID: String? = nil
    ) -> String? {
        if let value = normalized(environment[parentSessionIDKey]) {
            return value
        }
        if let value = normalized(enclosingTmuxSessionID) {
            return value
        }
        return normalized(environment[sessionIDKey])
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
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
