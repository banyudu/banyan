import Foundation
import Testing
@testable import BanyanCore

private final class ConversationPane: TmuxSessionBackend, @unchecked Sendable {
    var pane = TmuxPaneSnapshot(paneID: "%1", rootPID: 100, currentCommand: "codex", currentPath: "/tmp", isDead: false, isInMode: false)
    var reads = 0
    var replaceOnSecondRead = false
    var text = ""
    func hasSession(named: String) -> Bool { true }
    func primaryPaneSnapshot(named: String) -> TmuxPaneSnapshot? {
        reads += 1
        if replaceOnSecondRead && reads == 2 {
            return .init(paneID: "%2", rootPID: 100, currentCommand: "codex", currentPath: "/tmp", isDead: false, isInMode: false)
        }
        return pane
    }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String { text }
}

private final class ConversationInspector: CodexTUIProcessInspecting, @unchecked Sendable {
    let root = AgentProcessIdentity(pid: 100, startSeconds: 1, startMicroseconds: 0)
    let writer = AgentProcessIdentity(pid: 101, startSeconds: 2, startMicroseconds: 0)
    var paths: [String]
    var reads = 0
    var replaceWriter = false
    var secondWriter = false
    init(_ paths: [String]) { self.paths = paths }
    func tree(rootPID: Int32) throws -> [CodexTUIProcess] {
        reads += 1
        let current = replaceWriter && reads > 1 ? AgentProcessIdentity(pid: 101, startSeconds: 3, startMicroseconds: 0) : writer
        var tree = [CodexTUIProcess(identity: root, isCodex: false, openRollouts: []),
                    CodexTUIProcess(identity: current, isCodex: true, openRollouts: paths)]
        if secondWriter { tree.append(.init(identity: .init(pid: 102, startSeconds: 4, startMicroseconds: 0), isCodex: true, openRollouts: [])) }
        return tree
    }
    func hasExited(_ identity: AgentProcessIdentity) throws -> Bool { false }
}

private func conversationRollout() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-owner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("rollout-fixture.jsonl")
    try Data(#"{"type":"session_meta","payload":{"id":"thread-a"}}"#.utf8).write(to: url)
    let file = try FileHandle(forWritingTo: url)
    try file.seekToEnd(); try file.write(contentsOf: Data("\n".utf8)); try file.close()
    return url
}

@Test func terminalConversationRequiresOpenProcessEvidence() throws {
    let url = try conversationRollout()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let backend = ConversationPane()
    let inspector = ConversationInspector([url.path])
    let resolved = try CodexTerminalConversationResolver.resolve(sessionName: "fixture", backend: backend, inspector: inspector)
    #expect(resolved.conversationID == "thread-a")
    #expect(resolved.paneID == "%1")
    #expect(resolved.writer == inspector.writer)
    #expect(resolved.transcriptURL == url.resolvingSymlinksInPath())
    inspector.paths = []
    #expect(throws: CodexTerminalConversationResolver.ResolutionError.ambiguous) {
        try CodexTerminalConversationResolver.resolve(sessionName: "fixture", backend: backend, inspector: inspector)
    }
    inspector.paths = [url.path, url.deletingLastPathComponent().appendingPathComponent("rollout-other.jsonl").path]
    #expect(throws: CodexTerminalConversationResolver.ResolutionError.ambiguous) {
        try CodexTerminalConversationResolver.resolve(sessionName: "fixture", backend: backend, inspector: inspector)
    }
    inspector.paths = [url.path]; inspector.secondWriter = true
    #expect(throws: CodexTerminalConversationResolver.ResolutionError.ambiguous) {
        try CodexTerminalConversationResolver.resolve(sessionName: "fixture", backend: backend, inspector: inspector)
    }
}

@Test func terminalConversationRejectsChangedPaneOrProcess() throws {
    let url = try conversationRollout()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let inspector = ConversationInspector([url.path])
    let pane = ConversationPane(); pane.replaceOnSecondRead = true
    #expect(throws: CodexTerminalConversationResolver.ResolutionError.changed) {
        try CodexTerminalConversationResolver.resolve(sessionName: "fixture", backend: pane, inspector: inspector)
    }
    inspector.replaceWriter = true; inspector.reads = 0
    #expect(throws: CodexTerminalConversationResolver.ResolutionError.changed) {
        try CodexTerminalConversationResolver.resolve(sessionName: "fixture", backend: ConversationPane(), inspector: inspector)
    }
}

@Test func terminalConversationRejectsInvalidMetadata() throws {
    let url = try conversationRollout()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try Data(#"{"type":"session_meta","payload":{"id":"a","session_id":"b"}}"#.utf8).write(to: url)
    let file = try FileHandle(forWritingTo: url)
    try file.seekToEnd(); try file.write(contentsOf: Data("\n".utf8)); try file.close()
    #expect(throws: CodexTerminalConversationResolver.ResolutionError.invalidTranscript) {
        try CodexTerminalConversationResolver.resolve(sessionName: "fixture", backend: ConversationPane(), inspector: ConversationInspector([url.path]))
    }
}

@Test func terminalContextReadsHistoryOrExplicitlyFallsBackWithoutInput() async throws {
    let url = try conversationRollout()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let file = try FileHandle(forWritingTo: url)
    try file.seekToEnd()
    try file.write(contentsOf: Data(#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"before away"}]}}"#.utf8))
    try file.write(contentsOf: Data("\n".utf8)); try file.close()
    let pane = ConversationPane()
    let inspector = ConversationInspector([url.path])
    let reader = TerminalConversationContextReader(backend: pane, inspector: inspector)
    let context = try await reader.read(sessionID: "row", sessionName: "fixture", provider: .codex)
    #expect(context.source == .providerTranscript)
    #expect(context.conversationID == "thread-a")
    #expect(context.messages.map(\.text) == ["before away"])
    inspector.paths = []; pane.text = "retained output"
    let missing = try await reader.read(sessionID: "row", sessionName: "fixture", provider: .codex)
    #expect(missing.source == .terminalOutput)
    #expect(missing.output == "retained output")
    #expect(missing.binding?.kind == "terminalPane")
    #expect(missing.limitation?.contains("Replies are disabled") == true)
    #expect(missing.mayBeStale && missing.truncated)
}

@Test func truncatedTranscriptRemainsReadableWithAReadOnlyPaneBinding() async throws {
    let url = try conversationRollout()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let file = try FileHandle(forWritingTo: url)
    try file.seekToEnd()
    for index in 0..<30 {
        let row = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"message-\#(index)"}]}}"# + "\n"
        try file.write(contentsOf: Data(row.utf8))
    }
    try file.close()
    let context = TerminalConversationContextReader(backend: ConversationPane(), inspector: ConversationInspector([url.path]),
        history: ConversationHistoryReader(maxBytes: 500))
    let page = try await context.read(sessionID: "row", sessionName: "fixture", provider: .codex, limit: 1)
    #expect(page.source == .providerTranscript && page.messages.last?.text == "message-29")
    #expect(page.binding?.kind == "terminalPane" && page.truncated)
    #expect(page.limitation?.contains("replies are disabled") == true)
    let earlier = try await context.read(sessionID: "row", sessionName: "fixture", provider: .codex,
                                         earlier: try #require(page.earlier), limit: 1)
    #expect(earlier.binding == page.binding && earlier.messages.last?.text == "message-28")
    let appended = try FileHandle(forWritingTo: url)
    try appended.seekToEnd()
    try appended.write(contentsOf: Data((#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"new"}]}}"# + "\n").utf8))
    try appended.close()
    let latest = try await context.read(sessionID: "row", sessionName: "fixture", provider: .codex, limit: 1)
    #expect(latest.messages.last?.text == "new" && latest.binding != page.binding)
}

@Test func terminalContextRefusesCursorAfterOwnershipChanges() async throws {
    let url = try conversationRollout()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let file = try FileHandle(forWritingTo: url)
    try file.seekToEnd()
    for text in ["first", "second"] {
        let row = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(text)"}]}}"# + "\n"
        try file.write(contentsOf: Data(row.utf8))
    }
    try file.close()
    let pane = ConversationPane()
    let inspector = ConversationInspector([url.path])
    let reader = TerminalConversationContextReader(backend: pane, inspector: inspector)
    let page = try await reader.read(sessionID: "one", sessionName: "fixture", provider: .codex, limit: 1)
    let cursor = try #require(page.earlier)
    await #expect(throws: TerminalConversationContextReader.ContextError.changed) {
        try await reader.read(sessionID: "another", sessionName: "fixture", provider: .codex, earlier: cursor)
    }
    inspector.paths = []
    await #expect(throws: TerminalConversationContextReader.ContextError.changed) {
        try await reader.read(sessionID: "one", sessionName: "fixture", provider: .codex, earlier: cursor)
    }
}
