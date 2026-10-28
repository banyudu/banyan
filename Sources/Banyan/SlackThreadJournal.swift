import BanyanCore
import Foundation

/// Durable correlation only: never stores Slack credentials or transcript text.
/// A lost Slack post must be reconciled by the transport before bind is called.
@MainActor
final class SlackThreadJournal {
    struct Mapping: Codable, Equatable {
        let id: String
        let sessionID: String
        let identity: SlackConversationIdentity
        let workspace: String
        let channel: String
        let slackThread: String
    }
    private struct State: Codable {
        var version = 1
        var mappings: [Mapping] = []
    }
    private struct RootKey: Hashable { let workspace: String; let channel: String; let thread: String }
    private struct OwnerKey: Hashable { let workspace: String; let channel: String; let sessionID: String; let identity: SlackConversationIdentity }
    private struct NativeKey: Hashable { let sessionID: String; let identity: SlackConversationIdentity }
    private let file: URL
    private var state: State
    private(set) var storageError: String?
    private let maximumBytes = 4 * 1024 * 1024

    init(file: URL) {
        self.file = file
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else {
                    throw CodexRemoteError.invalid("Thread journal too large")
                }
                let data = try Data(contentsOf: file)
                let decoded = try JSONDecoder().decode(State.self, from: data)
                guard decoded.version == 1, decoded.mappings.count <= 4096,
                      Self.validMappings(decoded.mappings) else { throw CodexRemoteError.invalid("Invalid thread journal") }
                state = decoded
            } else { state = State() }
        } catch {
            state = State()
            storageError = "Slack thread journal is unavailable; preserve and repair it locally"
        }
    }

    func lookup(sessionID: String, identity: SlackConversationIdentity, principal: CodexRemotePrincipal) throws -> Mapping? {
        try available()
        return state.mappings.first { $0.sessionID == sessionID && $0.identity == identity &&
            $0.workspace == principal.workspace && $0.channel == principal.channel }
    }

    func bind(sessionID: String, identity: SlackConversationIdentity, principal: CodexRemotePrincipal,
              slackThread: String) throws -> Mapping {
        try available()
        guard !sessionID.isEmpty, sessionID.utf8.count <= 1024,
              !principal.workspace.isEmpty, !principal.channel.isEmpty, !identity.conversationID.isEmpty,
              identity.conversationID.utf8.count <= 1024, !identity.generation.isEmpty, identity.generation.utf8.count <= 128,
              ["terminalCodex", "terminalPane", "nativeCodex", "puck"].contains(identity.kind),
              identity.kind != "nativeCodex" || identity.generation == "native",
              identity.kind != "puck" || identity.generation == "puck",
              slackThread.range(of: #"^[0-9]{1,20}\.[0-9]{1,20}$"#, options: .regularExpression) != nil else {
            throw CodexRemoteError.invalid("Invalid Slack thread binding")
        }
        if let existing = try lookup(sessionID: sessionID, identity: identity, principal: principal) {
            guard existing.slackThread == slackThread else { throw CodexRemoteError.invalid("Conversation already has a different Slack thread") }
            return existing
        }
        if identity.kind == "nativeCodex", state.mappings.contains(where: { $0.sessionID == sessionID && $0.identity == identity }) {
            throw CodexRemoteError.invalid("Native conversation already has a Slack thread")
        }
        guard !state.mappings.contains(where: { $0.workspace == principal.workspace && $0.channel == principal.channel && $0.slackThread == slackThread }) else {
            throw CodexRemoteError.invalid("Slack thread is already bound to another conversation")
        }
        guard state.mappings.count < 4096 else { throw CodexRemoteError.invalid("Thread journal is full; preserve mappings and maintain it locally") }
        let mapping = Mapping(id: UUID().uuidString, sessionID: sessionID, identity: identity,
                              workspace: principal.workspace, channel: principal.channel, slackThread: slackThread)
        var next = state
        next.mappings.append(mapping)
        let data = try JSONEncoder().encode(next)
        guard data.count <= maximumBytes else { throw CodexRemoteError.invalid("Thread journal is full; preserve mappings and maintain it locally") }
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            storageError = "Slack thread journal write failed; remote bindings are unavailable"
            throw CodexRemoteError.invalid(storageError!)
        }
        state = next
        return mapping
    }

    /// Shared fence for the pre-existing native connector's attach path.
    func permitsNativeAttachment(sessionID: String, threadID: String, principal: CodexRemotePrincipal,
                                 slackThread: String) throws -> Bool {
        try available()
        let identity = SlackConversationIdentity(kind: "nativeCodex", conversationID: threadID, generation: "native")
        return !state.mappings.contains { mapping in
            let sameRoot = mapping.workspace == principal.workspace && mapping.channel == principal.channel && mapping.slackThread == slackThread
            let sameNative = mapping.sessionID == sessionID && mapping.identity == identity
            return (sameRoot && !sameNative) || (sameNative &&
                (mapping.workspace != principal.workspace || mapping.channel != principal.channel || mapping.slackThread != slackThread))
        }
    }

    private static func validMappings(_ mappings: [Mapping]) -> Bool {
        var roots: Set<RootKey> = [], owners: Set<OwnerKey> = [], nativeOwners: Set<NativeKey> = [], ids: Set<String> = []
        for mapping in mappings {
            guard UUID(uuidString: mapping.id) != nil, ids.insert(mapping.id).inserted,
                  !mapping.sessionID.isEmpty, mapping.sessionID.utf8.count <= 1024,
                  !mapping.workspace.isEmpty, !mapping.channel.isEmpty,
                  !mapping.identity.conversationID.isEmpty, mapping.identity.conversationID.utf8.count <= 1024,
                  !mapping.identity.generation.isEmpty, mapping.identity.generation.utf8.count <= 128, ["terminalCodex", "terminalPane", "nativeCodex", "puck"].contains(mapping.identity.kind),
                  mapping.identity.kind != "nativeCodex" || mapping.identity.generation == "native",
                  mapping.identity.kind != "puck" || mapping.identity.generation == "puck",
                  mapping.slackThread.range(of: #"^[0-9]{1,20}\.[0-9]{1,20}$"#, options: .regularExpression) != nil,
                  roots.insert(.init(workspace: mapping.workspace, channel: mapping.channel, thread: mapping.slackThread)).inserted,
                  owners.insert(.init(workspace: mapping.workspace, channel: mapping.channel, sessionID: mapping.sessionID, identity: mapping.identity)).inserted else { return false }
            if mapping.identity.kind == "nativeCodex", !nativeOwners.insert(.init(sessionID: mapping.sessionID, identity: mapping.identity)).inserted { return false }
        }
        return true
    }

    private func available() throws {
        if let storageError { throw CodexRemoteError.invalid(storageError) }
    }
}
