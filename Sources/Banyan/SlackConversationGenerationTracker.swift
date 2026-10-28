import BanyanCore
import CryptoKit
import Foundation

/// Persists only transcript fingerprints and generation IDs, not transcript
/// text. A bounded checkpoint distinguishes verified appends from resets,
/// compaction, rewrites of the observed window, and file replacement across restarts.
actor SlackConversationGenerationTracker: ConversationGenerationTracking {
    private struct Record: Codable {
        let sessionID: String
        let conversationID: String
        let deviceNumber: UInt64
        let fileNumber: UInt64
        let byteCount: Int
        let digest: String
        let resetCount: Int
        let generation: String
        let windowStart: UInt64?
        let headerDigest: String?
    }
    private struct State: Codable { var version = 1; var records: [Record] = [] }
    private let file: URL
    private var state: State?
    private var failed = false
    private let maximumJournalBytes = 4 * 1024 * 1024
    private let maximumWindowBytes = 4 * 1024 * 1024

    init(file: URL) { self.file = file }

    func identity(sessionID: String, conversationID: String, proof: ConversationHistoryReader.Proof) async throws -> SlackConversationIdentity {
        guard !failed, !sessionID.isEmpty, sessionID.utf8.count <= 1024,
              !conversationID.isEmpty, conversationID.utf8.count <= 1024,
              proof.bytes.count <= maximumWindowBytes, proof.resetCount >= 0 else { throw Failure.unavailable }
        try loadIfNeeded()
        guard var next = state else { throw Failure.unavailable }
        let old = next.records.first { $0.sessionID == sessionID && $0.conversationID == conversationID }
        let unchangedPrefix = try old.map { record in
            try ConversationHistoryReader.extends(.init(deviceNumber: record.deviceNumber, fileNumber: record.fileNumber,
                startOffset: record.windowStart ?? 0, byteCount: record.byteCount, digest: record.digest,
                resetCount: record.resetCount, headerDigest: record.headerDigest), with: proof)
        } ?? false
        // A random first generation also prevents an erased index from reusing
        // an old mapping whose deduplication evidence still exists elsewhere.
        let generation = unchangedPrefix ? old!.generation : UUID().uuidString
        if unchangedPrefix, old?.byteCount == proof.bytes.count, (old?.windowStart ?? 0) == proof.startOffset {
            return SlackConversationIdentity(kind: "terminalCodex", conversationID: conversationID, generation: generation)
        }
        let record = Record(sessionID: sessionID, conversationID: conversationID,
                            deviceNumber: proof.deviceNumber, fileNumber: proof.fileNumber,
                            byteCount: proof.bytes.count, digest: Self.digest(proof.bytes),
                            resetCount: proof.resetCount, generation: generation, windowStart: proof.startOffset,
                            headerDigest: proof.header.map(Self.digest))
        if let index = next.records.firstIndex(where: { $0.sessionID == sessionID && $0.conversationID == conversationID }) {
            next.records[index] = record
        } else {
            guard next.records.count < 4096 else { throw Failure.unavailable }
            next.records.append(record)
        }
        let encoded = try JSONEncoder().encode(next)
        guard encoded.count <= maximumJournalBytes else { throw Failure.unavailable }
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try encoded.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            failed = true
            throw Failure.unavailable
        }
        state = next
        return SlackConversationIdentity(kind: "terminalCodex", conversationID: conversationID, generation: generation)
    }

    private func loadIfNeeded() throws {
        guard !failed else { throw Failure.unavailable }
        guard state == nil else { return }
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumJournalBytes else { throw Failure.unavailable }
                let decoded = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
                var keys: Set<String> = []
                guard decoded.version == 1, decoded.records.count <= 4096,
                      decoded.records.allSatisfy({ record in
                          let key = "\(record.sessionID.utf8.count):\(record.sessionID)\(record.conversationID)"
                          return !record.sessionID.isEmpty && !record.conversationID.isEmpty &&
                              record.byteCount >= 0 && record.byteCount <= maximumWindowBytes && record.resetCount >= 0 &&
                              UUID(uuidString: record.generation) != nil && record.digest.count == 64 &&
                              record.digest.allSatisfy { $0.isHexDigit } &&
                              (record.headerDigest.map { $0.count == 64 && $0.allSatisfy(\.isHexDigit) } ?? true) && keys.insert(key).inserted
                      }) else { throw Failure.unavailable }
                state = decoded
            } else { state = State() }
        } catch {
            failed = true
            throw Failure.unavailable
        }
    }

    private static func digest<D: DataProtocol>(_ data: D) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private enum Failure: Error { case unavailable }
}
