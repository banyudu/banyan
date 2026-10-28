import Foundation

/// A bounded snapshot of one explicitly identified provider transcript.
/// Callers must resolve the transcript from the exact session identity; this
/// reader deliberately does not discover files by working directory.
public actor ConversationHistoryReader {
    /// Cursor identity includes the owning Banyan row and live process
    /// generation, not just a provider file shared by multiple sessions.
    public struct TerminalOwner: Hashable, Sendable {
        public let sessionID: String
        public let paneID: String
        public let root: AgentProcessIdentity
        public let writer: AgentProcessIdentity

        public init(sessionID: String, paneID: String, root: AgentProcessIdentity, writer: AgentProcessIdentity) {
            self.sessionID = sessionID; self.paneID = paneID; self.root = root; self.writer = writer
        }
    }

    public struct Identity: Hashable, Sendable {
        public let provider: CodingAgentProvider
        public let conversationID: String
        public let transcriptURL: URL
        public let terminalOwner: TerminalOwner?

        public init(provider: CodingAgentProvider, conversationID: String, transcriptURL: URL,
                    terminalOwner: TerminalOwner? = nil) {
            self.provider = provider
            self.conversationID = conversationID
            self.transcriptURL = transcriptURL.standardizedFileURL
            self.terminalOwner = terminalOwner
        }
    }

    public struct Message: Codable, Equatable, Sendable {
        public let role: String
        public let text: String
        public let truncated: Bool
    }

    public struct Proof: Sendable {
        public let bytes: Data
        public let deviceNumber: UInt64
        public let fileNumber: UInt64
        public let resetCount: Int
    }

    public struct Page: Sendable {
        public let snapshotID: UUID
        /// Present only when the entire completed transcript fits the read bound.
        public let proof: Proof?
        public let messages: [Message]
        public let earlier: String?
        public let incompleteTail: Bool
        /// Number of reset boundaries in the verified snapshot window.
        public let resetCount: Int
        /// Older transcript bytes were outside the bounded snapshot.
        public let truncatedBefore: Bool
        /// Digest of the bounded snapshot, used to fence read-only fallback
        /// threads when a full transcript generation cannot be proven.
        public let windowDigest: String
    }

    public enum ReadError: Error, Equatable {
        case unavailable, unsupported, identityMismatch, changed, invalidCursor
    }

    private struct Snapshot {
        let identity: Identity
        let bytes: Data
        let start: UInt64
        let header: Data
        let fileNumber: NSNumber
        let deviceNumber: NSNumber
        let messages: [Message]
        let incompleteTail: Bool
        let resetCount: Int
        let windowDigest: String
    }

    private let maxBytes: Int
    private let maxSnapshots: Int
    private var snapshots: [UUID: Snapshot] = [:]
    private var snapshotOrder: [UUID] = []

    public init(maxBytes: Int = 4 * 1024 * 1024, maxSnapshots: Int = 8) {
        self.maxBytes = max(1, maxBytes)
        self.maxSnapshots = max(1, maxSnapshots)
    }

    /// Opens the latest snapshot or follows an opaque earlier cursor. A cursor
    /// refers to a fixed snapshot, so later appends do not duplicate its pages.
    /// A replacement, rewrite, reset, truncation, eviction, or growth beyond the
    /// bounded validation window invalidates it.
    public func page(identity: Identity, earlier cursor: String? = nil, limit: Int = 20) throws -> Page {
        let pageSize = min(max(limit, 1), 100)
        let id: UUID
        let snapshot: Snapshot
        let end: Int
        if let cursor {
            let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let parsedID = UUID(uuidString: String(parts[0])),
                  let parsedEnd = Int(parts[1]), let stored = snapshots[parsedID],
                  stored.identity == identity, (0...stored.messages.count).contains(parsedEnd) else {
                throw ReadError.invalidCursor
            }
            try validate(stored)
            id = parsedID
            snapshot = stored
            end = parsedEnd
        } else {
            snapshot = try load(identity)
            id = UUID()
            snapshots[id] = snapshot
            snapshotOrder.append(id)
            while snapshotOrder.count > maxSnapshots {
                snapshots.removeValue(forKey: snapshotOrder.removeFirst())
            }
            end = snapshot.messages.count
        }
        let start = max(0, end - pageSize)
        let proof = snapshot.start == 0 && !snapshot.incompleteTail
            ? Proof(bytes: snapshot.bytes, deviceNumber: snapshot.deviceNumber.uint64Value,
                    fileNumber: snapshot.fileNumber.uint64Value, resetCount: snapshot.resetCount) : nil
        return Page(snapshotID: id, proof: proof, messages: Array(snapshot.messages[start..<end]),
                    earlier: start > 0 ? "\(id.uuidString):\(start)" : nil,
                    incompleteTail: snapshot.incompleteTail, resetCount: snapshot.resetCount,
                    truncatedBefore: snapshot.start > 0, windowDigest: snapshot.windowDigest)
    }

    /// Revalidate after other async work before returning or publishing a page.
    public func revalidate(identity: Identity, snapshotID: UUID) throws {
        guard let snapshot = snapshots[snapshotID], snapshot.identity == identity else { throw ReadError.invalidCursor }
        try validate(snapshot)
    }

    private func attributes(_ url: URL) throws -> (NSNumber, NSNumber, UInt64) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = attrs[.systemFileNumber] as? NSNumber,
              let device = attrs[.systemNumber] as? NSNumber,
              let size = attrs[.size] as? NSNumber,
              attrs[.type] as? FileAttributeType == .typeRegular else { throw ReadError.unavailable }
        return (inode, device, size.uint64Value)
    }

    private func readRange(_ url: URL, start: UInt64 = 0, count: Int) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: start)
            return try handle.read(upToCount: count) ?? Data()
        } catch { throw ReadError.unavailable }
    }

    private func parseBytes(header: Data, window: Data, start: UInt64) -> Data {
        guard start > 0 else { return window }
        // The first bytes of a tail window may be a partial JSONL record.
        guard let newline = window.firstIndex(of: 10) else { return header }
        return header + window.suffix(from: window.index(after: newline))
    }

    private func validate(_ snapshot: Snapshot) throws {
        let url = snapshot.identity.transcriptURL
        let (inode, device, size) = try attributes(url)
        let originalEnd = snapshot.start + UInt64(snapshot.bytes.count)
        guard inode == snapshot.fileNumber, device == snapshot.deviceNumber,
              size >= originalEnd, size - snapshot.start <= maxBytes else { throw ReadError.changed }
        let header = try readRange(url, count: snapshot.header.count)
        let current = try readRange(url, start: snapshot.start, count: Int(size - snapshot.start))
        guard header == snapshot.header, current.count == size - snapshot.start,
              current.prefix(snapshot.bytes.count) == snapshot.bytes,
              try parse(parseBytes(header: header, window: current, start: snapshot.start),
                        identity: snapshot.identity).resetCount == snapshot.resetCount else {
            throw ReadError.changed
        }
        let (afterInode, afterDevice, afterSize) = try attributes(url)
        guard afterInode == inode, afterDevice == device, afterSize == size else { throw ReadError.changed }
    }

    private func load(_ identity: Identity) throws -> Snapshot {
        guard !identity.conversationID.isEmpty else { throw ReadError.identityMismatch }
        guard identity.provider == .codex || identity.provider == .claude else { throw ReadError.unsupported }
        let (inode, device, size) = try attributes(identity.transcriptURL)
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        let bytes = try readRange(identity.transcriptURL, start: start, count: Int(size - start))
        guard bytes.count == size - start else { throw ReadError.changed }
        var header = Data()
        if start > 0, identity.provider == .codex {
            let prefix = try readRange(identity.transcriptURL, count: min(Int(size), 65_536))
            guard let end = prefix.firstIndex(of: 10) else { throw ReadError.unavailable }
            header = Data(prefix.prefix(through: end))
        }
        let parsed = try parse(parseBytes(header: header, window: bytes, start: start), identity: identity)
        let snapshot = Snapshot(identity: identity, bytes: bytes, start: start, header: header,
                                fileNumber: inode, deviceNumber: device, messages: parsed.messages,
                                incompleteTail: !bytes.isEmpty && bytes.last != 10,
                                resetCount: parsed.resetCount,
                                windowDigest: ConversationWindowDigest.hex(header + bytes))
        try validate(snapshot)
        return snapshot
    }

    private func parse(_ data: Data, identity: Identity) throws -> (messages: [Message], resetCount: Int) {
        // Never display a partially written JSONL record.
        let complete = data.last == 10 ? data : Data(data.prefix(throughLastNewline: ()))
        let lines = complete.split(separator: 10, omittingEmptySubsequences: true)
        guard !lines.isEmpty else { throw ReadError.identityMismatch }
        var messages: [Message] = []
        var sawIdentity = false
        var resetCount = 0
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = ISO8601DateFormatter()
        var previousCodex: (role: String, text: String, source: String, time: Date)?
        func appendCodex(role: String, text: String, source: String, timestamp: String?) {
            let time = timestamp.flatMap { fractional.date(from: $0) ?? seconds.date(from: $0) }
            // Codex can record the same utterance as both a response item and
            // an event. Only coalesce adjacent matching records with timestamps
            // close enough to identify the mirror; do not merge repeated events
            // or repeated response items from the same source.
            if let time, let previous = previousCodex, previous.role == role, previous.text == text,
               previous.source != source, abs(time.timeIntervalSince(previous.time)) < 2 {
                previousCodex = nil
                return
            }
            messages.append(Self.message(role: role, text: text))
            previousCodex = time.map { (role, text, source, $0) }
        }
        for (index, line) in lines.enumerated() {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                throw ReadError.changed
            }
            if identity.provider == .codex {
                if index == 0 {
                    guard row["type"] as? String == "session_meta",
                          let payload = row["payload"] as? [String: Any] else { throw ReadError.identityMismatch }
                    let ids = [payload["id"] as? String, payload["session_id"] as? String].compactMap { $0 }
                    guard !ids.isEmpty, ids.allSatisfy({ $0 == identity.conversationID }) else { throw ReadError.identityMismatch }
                    sawIdentity = true
                } else if row["type"] as? String == "session_meta" {
                    throw ReadError.identityMismatch
                }
                if row["type"] as? String == "event_msg",
                   let payload = row["payload"] as? [String: Any],
                   let event = payload["type"] as? String,
                   ["user_message", "agent_message"].contains(event),
                   let text = Self.text(payload["message"]) {
                    let role = event == "user_message" ? "user" : "assistant"
                    if role == "user", Self.isReset(text) {
                        messages.removeAll(); resetCount += 1; previousCodex = nil
                    } else if role != "user" || (!text.hasPrefix("# AGENTS.md") && !text.contains("<INSTRUCTIONS>")) {
                        appendCodex(role: role, text: text, source: "event", timestamp: row["timestamp"] as? String)
                    }
                    continue
                }
                if row["type"] as? String == "response_item",
                   let payload = row["payload"] as? [String: Any],
                   payload["type"] as? String == "function_call_output",
                   let output = Self.text(payload["output"]) {
                    messages.append(Self.message(role: "tool", text: output))
                    previousCodex = nil
                    continue
                }
                guard row["type"] as? String == "response_item",
                      let payload = row["payload"] as? [String: Any],
                      payload["type"] as? String == "message",
                      let role = payload["role"] as? String, ["user", "assistant"].contains(role),
                      let text = Self.text(payload["content"]) else { continue }
                if role == "user", Self.isReset(text) { messages.removeAll(); resetCount += 1; previousCodex = nil; continue }
                if role == "user", text.hasPrefix("# AGENTS.md") || text.contains("<INSTRUCTIONS>") { continue }
                appendCodex(role: role, text: text, source: "response", timestamp: row["timestamp"] as? String)
            } else {
                if let sessionID = row["sessionId"] as? String {
                    guard sessionID == identity.conversationID else { throw ReadError.identityMismatch }
                    sawIdentity = true
                }
                guard let role = row["type"] as? String, ["user", "assistant"].contains(role),
                      row["isMeta"] as? Bool != true,
                      row["sessionId"] as? String == identity.conversationID,
                      let message = row["message"] as? [String: Any] else { continue }
                if let text = Self.text(message["content"]) {
                    if role == "user", Self.isReset(text) { messages.removeAll(); resetCount += 1; continue }
                    messages.append(Self.message(role: role, text: text))
                }
                if let parts = message["content"] as? [[String: Any]] {
                    for part in parts where part["type"] as? String == "tool_result" {
                        if let text = Self.text(part["content"]) {
                            messages.append(Self.message(role: "tool", text: text))
                        }
                    }
                }
            }
        }
        guard sawIdentity else { throw ReadError.identityMismatch }
        return (messages, resetCount)
    }

    private static func isReset(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "/clear" || value == "/new"
    }

    private static func text(_ content: Any?) -> String? {
        let text: String
        if let value = content as? String { text = value }
        else if let parts = content as? [[String: Any]] {
            text = parts.compactMap { part in
                guard let type = part["type"] as? String,
                      ["text", "input_text", "output_text"].contains(type) else { return nil }
                return part["text"] as? String
            }.joined(separator: "\n")
        } else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func message(role: String, text: String) -> Message {
        let maxCharacters = 8_000
        return Message(role: role, text: String(text.prefix(maxCharacters)), truncated: text.count > maxCharacters)
    }
}

private extension Data {
    func prefix(throughLastNewline: Void) -> SubSequence {
        guard let last = lastIndex(of: 10) else { return prefix(0) }
        return prefix(upTo: index(after: last))
    }
}
