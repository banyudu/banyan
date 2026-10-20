import Foundation

/// Optional process-level overrides used by disposable lab instances.
///
/// Normal launches leave every key unset. A lab launch sets all of them so it
/// cannot share the production control port, tmux server, or data directory.
public enum LabEnvironment {
    public static let tmuxSocketKey = "BANYAN_TMUX_SOCKET"
    public static let controlPortKey = "BANYAN_CONTROL_PORT"

    /// A tmux socket name is a filename component under the per-user tmux
    /// directory. Keep it to characters that cannot escape that directory.
    public static func tmuxSocketName(from environment: [String: String]) -> String? {
        guard let raw = environment[tmuxSocketKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.count <= 64,
              raw.first != ".", raw.first != "-" else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard raw.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else { return nil }
        return raw
    }

    public static func controlPort(from environment: [String: String]) -> UInt16? {
        guard let raw = environment[controlPortKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = UInt16(raw), value > 0 else { return nil }
        return value
    }
}
