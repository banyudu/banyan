import Foundation
import Testing
@testable import BanyanCore

/// Local transport evidence only: Desktop/mobile uses its own server/account.
/// The real installed CLI, rollout, tmux pane, and JSON-RPC here are not mocks.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BANYAN_CODEX_INTEGRATION_ROOT"] != nil))
func installedCodexTUIHandoffIntegration() async throws {
    let environment = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(environment["BANYAN_CODEX_INTEGRATION_ROOT"]))
    let executable = try #require(environment["BANYAN_CODEX_INTEGRATION_EXECUTABLE"])
    let home = root.appendingPathComponent("codex-home")
    let cwd = root.appendingPathComponent("legacy-worktree")
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    let marker = cwd.appendingPathComponent("preserve.txt")
    try Data("KEEP".utf8).write(to: marker)
    let childEnvironment = ["PATH": environment["PATH"] ?? "/usr/bin:/bin", "HOME": home.path,
        "CODEX_HOME": home.path, "TERM": "xterm-256color", "NO_COLOR": "1", "LANG": "en_US.UTF-8"]
    let settings = CodexThreadSettings(model: "fixture-model", modelProvider: "loopback",
        approvalPolicy: "never", sandbox: "read-only")
    let seed = CodexAppServerClient(executable: executable, environment: childEnvironment, requestTimeout: 15)
    let owner = CodexThreadCoordinator(service: seed)
    let threadID: String
    do {
        try owner.register(sessionID: "seed", binding: .init(cwd: cwd.path, settings: settings, codexHome: home.path))
        try await owner.select(sessionID: "seed")
        threadID = try #require(owner.states["seed"]?.binding.threadID)
        _ = try await owner.startTurn(sessionID: "seed", input: [.object([
            "type": .string("text"), "text": .string("fixture:hello"), "text_elements": .array([])])])
        try await handoffWait(root: root) { owner.states["seed"]?.lastTurnStatus == "completed" }
    } catch { await seed.stop(); throw error }
    await seed.stop()
    let binding = CodexThreadBinding(threadID: threadID, cwd: cwd.path, settings: settings, codexHome: home.path)
    let socket = "banyan-handoff-test-" + UUID().uuidString.prefix(8)
    let name = "banyan-fixture"
    let command = try CodexCLIFallback.command(binding: binding, executable: executable)
    let backend = TmuxBackend(environment: childEnvironment, workingDirectory: cwd.path, socketName: String(socket))
    let inspector = CodexTUIProcessInspector()
    try await handoffWrite(root: root, file: "legacy-tui.json", value: .object([
        "command": .string(command), "cwd": .string(cwd.path), "threadID": .string(threadID),
        "codexHome": .string(home.path), "socket": .string(String(socket)), "session": .string(name)]))
    try await handoffWait(root: root) { FileManager.default.fileExists(atPath: root.appendingPathComponent("legacy-ready.json").path) }
    let enumerator = try #require(FileManager.default.enumerator(at: home.appendingPathComponent("sessions"), includingPropertiesForKeys: nil))
    let transcript = try #require(enumerator.compactMap { $0 as? URL }.first { $0.lastPathComponent.hasSuffix(threadID + ".jsonl") })
    let diagnostic = try SubprocessRunner.run(arguments: [backend.executableURL.path, "-L", String(socket), "list-panes", "-t", name,
        "-F", "#{pane_id}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_dead}\t#{pane_in_mode}"],
        cwd: cwd.path, environment: childEnvironment, timeout: 5)
    try await handoffWrite(root: root, file: "legacy-tmux-diagnostic.json", value: .object([
        "status": .number(Double(diagnostic.terminationStatus)),
        "stdout": .string(String(decoding: diagnostic.standardOutput, as: UTF8.self)),
        "stderr": .string(String(decoding: diagnostic.standardError, as: UTF8.self))]))
    let pane = try #require(backend.primaryPaneSnapshot(named: name))
    // Exercise a genuine running turn before arming preservation.
    try await handoffWrite(root: root, file: "legacy-action.json", value: .object([
        "sequence": .number(1), "action": .string("prompt"), "text": .string("fixture:steer")]))
    try await handoffWait(root: root) { backend.captureCurrentVisibleText(paneID: pane.paneID).contains("WORKING") }
    #expect(throws: CodexTUIHandoffError.self) {
        try CodexTUIHandoff.prepare(threadID: threadID, cwd: cwd.path, transcriptURL: transcript,
            sessionName: name, backend: backend, inspector: inspector)
    }
    #expect(try backend.codexHandoffReceipt(paneID: pane.paneID) == nil)
    try Data().write(to: root.appendingPathComponent("release-steer"))
    try await handoffWait(root: root) {
        let rows = (try? String(contentsOf: transcript, encoding: .utf8)) ?? ""
        return rows.contains("FIXTURE_STEER_OK") && (try? CodexTUIHandoff.validateCompletedTranscript(transcript, threadID: threadID, cwd: cwd.path)) != nil
    }
    try await handoffWrite(root: root, file: "legacy-action.json", value: .object([
        "sequence": .number(2), "action": .string("prompt"), "text": .string("fixture:question")]))
    try await handoffWait(root: root) { backend.captureCurrentVisibleText(paneID: pane.paneID).contains("Choose a fixture answer") }
    #expect(throws: CodexTUIHandoffError.self) {
        try CodexTUIHandoff.prepare(threadID: threadID, cwd: cwd.path, transcriptURL: transcript,
            sessionName: name, backend: backend, inspector: inspector)
    }
    #expect(try backend.codexHandoffReceipt(paneID: pane.paneID) == nil)
    try await handoffWrite(root: root, file: "legacy-action.json", value: .object([
        "sequence": .number(3), "action": .string("answer")]))
    try await handoffWait(root: root) {
        let rows = (try? String(contentsOf: transcript, encoding: .utf8)) ?? ""
        return rows.contains("FIXTURE_QUESTION_OK") && (try? CodexTUIHandoff.validateCompletedTranscript(transcript, threadID: threadID, cwd: cwd.path)) != nil
    }
    // Attempt the actual installed server's cross-process resume. Record its
    // real response; versions need not enforce Desktop's ownership in stdio.
    let remote = CodexAppServerClient(executable: executable, environment: childEnvironment, requestTimeout: 15)
    let adapter = CodexThreadCoordinator(service: remote)
    try adapter.register(sessionID: "remote", binding: binding)
    var before: CodexJSONValue
    do {
        let read = try await adapter.read(sessionID: "remote")
        #expect(read.objectValue?["thread"]?.objectValue?["id"] == .string(threadID))
        do {
            try await adapter.select(sessionID: "remote")
            before = .object(["conflictObserved": .bool(false), "note": .string("Installed stdio server permitted resume while CLI was open; Desktop/mobile conflict remains a separate check.")])
        } catch {
            let message = error.localizedDescription
            #expect(message.lowercased().contains("active writer") || message.lowercased().contains("already being controlled"))
            if case .writerConflict? = adapter.states["remote"]?.connection {} else { Issue.record("Real writer conflict was not recognized") }
            before = .object(["conflictObserved": .bool(true), "error": .string(message)])
        }
        try await handoffWrite(root: root, file: "legacy-before-resume.json", value: before)
    } catch { await remote.stop(); throw error }
    await remote.stop()
    let receipt = try CodexTUIHandoff.prepare(threadID: threadID, cwd: cwd.path, transcriptURL: transcript,
        sessionName: name, backend: backend, inspector: inspector)
    #expect(receipt.threadID == threadID && receipt.paneID == pane.paneID)
    #expect(try CodexTUIHandoff.check(sessionName: name, threadID: threadID, backend: backend, inspector: inspector) == .awaitingCLIExit)
    let original = try Data(contentsOf: transcript)
    try await handoffWrite(root: root, file: "legacy-action.json", value: .object([
        "sequence": .number(4), "action": .string("quit")]))
    try await handoffWait(root: root) { backend.primaryPaneSnapshot(named: name)?.isDead == true }
    #expect(try CodexTUIHandoff.check(sessionName: name, threadID: threadID, backend: backend, inspector: inspector) == .cliExited)
    #expect(backend.hasSession(named: name))
    #expect(backend.primaryPaneSnapshot(named: name)?.paneID == pane.paneID)
    #expect(try Data(contentsOf: marker) == Data("KEEP".utf8))
    #expect(try Data(contentsOf: transcript).starts(with: original))
    let after = CodexAppServerClient(executable: executable, environment: childEnvironment, requestTimeout: 15)
    do {
        var params = settings.parameters(cwd: cwd.path)
        params["threadId"] = .string(threadID)
        let resumed = try await after.request("thread/resume", params: .object(params))
        #expect(resumed.objectValue?["thread"]?.objectValue?["id"] == .string(threadID))
        let read = try await after.request("thread/read", params: .object(["threadId": .string(threadID), "includeTurns": .bool(true)]))
        #expect(read.inspectableText.contains("FIXTURE_STEER_OK"))
        try await handoffWrite(root: root, file: "legacy-after-resume.json", value: .object([
            "threadID": .string(threadID), "cliExited": .bool(true), "samePaneRetained": .bool(true),
            "sameTranscriptRetained": .bool(true), "resumed": .bool(true), "mobileVerified": .bool(false)]))
    } catch { await after.stop(); throw error }
    await after.stop()
}

@MainActor
private func handoffWait(root: URL, timeout: TimeInterval = 30, condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if let error = try? String(contentsOf: root.appendingPathComponent("legacy-driver-error.json"), encoding: .utf8) {
            throw CodexTUIHandoffError.refused(error)
        }
        guard Date() < deadline else { throw CodexTUIHandoffError.refused("Private handoff fixture timed out") }
        try await Task.sleep(for: .milliseconds(50))
    }
}

private func handoffWrite(root: URL, file: String, value: CodexJSONValue) async throws {
    try JSONEncoder().encode(value).write(to: root.appendingPathComponent(file), options: .atomic)
}
