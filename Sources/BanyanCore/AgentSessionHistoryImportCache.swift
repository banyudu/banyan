import Foundation


struct CodexTranscriptMetadata {
    let cwd: String?
    let createdAt: Date?
    let promptTitle: String?
    let segmentTitle: String?
    let segmentWasCleared: Bool
}

/// Keeps parsed metadata for the bounded set of recent transcript files.
/// Index-title changes can reuse these entries; an appended or replaced
/// transcript changes its size or modification date and is parsed again.
public final class AgentSessionHistoryImportCache: @unchecked Sendable {
    private struct Signature: Equatable {
        let modifiedAt: Date
        let fileSize: Int
    }

    private struct Entry<Value> {
        let signature: Signature
        let value: Value
    }

    private let lock = NSLock()
    private var codex: [URL: Entry<CodexTranscriptMetadata>] = [:]
    private var claude: [URL: Entry<ImportedAgentSession>] = [:]
    private var parseCount = 0

    public init() {}

    /// A diagnostic counter used by import tests to prove cache hits avoid I/O.
    var parsedTranscriptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return parseCount
    }

    func codexMetadata(
        for url: URL,
        modifiedAt: Date,
        fileSize: Int?,
        parse: () -> CodexTranscriptMetadata
    ) -> CodexTranscriptMetadata {
        let signature = fileSize.map { Signature(modifiedAt: modifiedAt, fileSize: $0) }
        lock.lock()
        let cached = codex[url]
        lock.unlock()
        if let signature, cached?.signature == signature, let cached {
            return cached.value
        }
        let parsed = parse()
        lock.lock()
        parseCount += 1
        if let signature {
            codex[url] = Entry(signature: signature, value: parsed)
        }
        lock.unlock()
        return parsed
    }

    func claudeSession(
        for url: URL,
        modifiedAt: Date,
        fileSize: Int?,
        parse: () -> ImportedAgentSession?
    ) -> ImportedAgentSession? {
        let signature = fileSize.map { Signature(modifiedAt: modifiedAt, fileSize: $0) }
        lock.lock()
        let cached = claude[url]
        lock.unlock()
        if let signature, cached?.signature == signature, let cached {
            return cached.value
        }
        let parsed = parse()
        lock.lock()
        parseCount += 1
        if let signature, let parsed {
            claude[url] = Entry(signature: signature, value: parsed)
        }
        lock.unlock()
        return parsed
    }

    func retainCodex(_ urls: Set<URL>) {
        lock.lock()
        codex = codex.filter { urls.contains($0.key) }
        lock.unlock()
    }

    func retainClaude(_ urls: Set<URL>) {
        lock.lock()
        claude = claude.filter { urls.contains($0.key) }
        lock.unlock()
    }
}
