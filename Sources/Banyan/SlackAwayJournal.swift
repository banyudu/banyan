import BanyanCore
import Foundation

/// The selection and checkpoint live in Banyan. No transcript or credential is
/// stored here; event replay remains bounded and is never assumed complete.
@MainActor
final class SlackAwayJournal {
    struct State: Codable, Equatable {
        var version = 1
        var enabled = false
        var workspace = ""
        var channel = ""
        var sessionIDs: [String] = []
        var projectIDs: [String] = []
        var activationID: String?
        var checkpointEpoch: String?
        var checkpointCursor: Int?
        var revision: UInt64 = 0
    }
    private let file: URL
    private(set) var state: State
    private(set) var storageError: String?
    private let maxBytes = 2 * 1024 * 1024

    init(file: URL) {
        self.file = file
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                guard let size = attrs[.size] as? NSNumber, size.intValue <= maxBytes else { throw Failure.invalid }
                let decoded = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
                guard Self.valid(decoded) else { throw Failure.invalid }
                state = decoded
            } else { state = State() }
        } catch {
            state = State()
            storageError = "Away state is unavailable; preserve and repair it locally"
        }
    }

    func status(principal: CodexRemotePrincipal) throws -> State {
        try available()
        guard state.workspace.isEmpty || (state.workspace == principal.workspace && state.channel == principal.channel) else { throw Failure.denied }
        return state
    }

    /// Called on the main actor with an event cursor captured in the same turn.
    /// Repeated enable is idempotent; a changed scope starts a new catch-up.
    func configure(principal: CodexRemotePrincipal, enabled: Bool?, sessionID: String?, projectID: String?,
                   follow: Bool?, epoch: String, cursor: Int) throws -> State {
        try available()
        guard !principal.workspace.isEmpty, !principal.channel.isEmpty, !principal.user.isEmpty,
              !epoch.isEmpty, cursor >= 0, (sessionID == nil || projectID == nil),
              ((sessionID != nil || projectID != nil) == (follow != nil)) else { throw Failure.invalid }
        if !state.workspace.isEmpty && (state.workspace != principal.workspace || state.channel != principal.channel) { throw Failure.denied }
        var next = state
        next.workspace = principal.workspace; next.channel = principal.channel
        if let sessionID, let follow { try Self.set(sessionID, follow: follow, in: &next.sessionIDs) }
        if let projectID, let follow { try Self.set(projectID, follow: follow, in: &next.projectIDs) }
        if let enabled { next.enabled = enabled }
        guard !next.enabled || !next.sessionIDs.isEmpty || !next.projectIDs.isEmpty else { throw Failure.emptyScope }
        let scopeChanged = next.sessionIDs != state.sessionIDs || next.projectIDs != state.projectIDs
        if next.enabled && (!state.enabled || scopeChanged) {
            next.activationID = UUID().uuidString
            next.checkpointEpoch = epoch
            next.checkpointCursor = cursor
        }
        if next != state {
            next.revision &+= 1
            try commit(next)
        }
        return state
    }

    func includes(sessionID: String, projectID: String, principal: CodexRemotePrincipal) -> Bool {
        storageError == nil && state.enabled && state.workspace == principal.workspace && state.channel == principal.channel &&
            (state.sessionIDs.contains(sessionID) || state.projectIDs.contains(projectID))
    }

    /// A policy change may remove the only control channel. Do not retain its
    /// scope for a different channel or prevent that channel from configuring
    /// Away. Ordinary disable/re-enable preserves the scope when its tuple is
    /// still present. The caller invokes this after committing local policy.
    func resetIfChannelRemoved(allowed: [CodexRemotePrincipal]) throws {
        try available()
        guard !state.workspace.isEmpty,
              !allowed.contains(where: { $0.workspace == state.workspace && $0.channel == state.channel }) else { return }
        try commit(State())
    }

    private static func set(_ value: String, follow: Bool, in values: inout [String]) throws {
        guard !value.isEmpty, value.utf8.count <= 1024 else { throw Failure.invalid }
        if follow, !values.contains(value) { guard values.count < 4096 else { throw Failure.full }; values.append(value); values.sort() }
        if !follow { values.removeAll { $0 == value } }
    }
    private func commit(_ next: State) throws {
        try available()
        let data = try JSONEncoder().encode(next)
        guard data.count <= maxBytes else { throw Failure.full }
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { storageError = "Away state write failed; proactive delivery is unavailable"; throw Failure.unavailable }
        state = next
    }
    private func available() throws { if storageError != nil { throw Failure.unavailable } }
    private static func valid(_ state: State) -> Bool {
        guard state.version == 1, state.sessionIDs.count <= 4096, state.projectIDs.count <= 4096,
              Set(state.sessionIDs).count == state.sessionIDs.count, Set(state.projectIDs).count == state.projectIDs.count,
              (state.sessionIDs + state.projectIDs).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }),
              (state.workspace.isEmpty == state.channel.isEmpty),
              state.checkpointCursor.map({ $0 >= 0 }) ?? true else { return false }
        if state.enabled {
            return !state.workspace.isEmpty && (!state.sessionIDs.isEmpty || !state.projectIDs.isEmpty) &&
                state.activationID.flatMap(UUID.init(uuidString:)) != nil && state.checkpointEpoch.flatMap(UUID.init(uuidString:)) != nil && state.checkpointCursor != nil
        }
        return true
    }
    enum Failure: Error { case invalid, denied, emptyScope, full, unavailable }
}
