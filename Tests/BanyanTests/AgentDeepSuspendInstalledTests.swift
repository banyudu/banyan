import AppKit
import BanyanCore
import Darwin
import Foundation
import Testing
@testable import Banyan

/// The existing credential-free Responses harness serves the installed CLI.
/// Only the UUID socket and private home supplied by that harness are used.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BANYAN_CODEX_DEEP_ROOT"] != nil))
func installedCodexDeepSuspendAndExactResume() async throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BANYAN_CODEX_DEEP_ROOT"]))
    let executable = try #require(ProcessInfo.processInfo.environment["BANYAN_CODEX_DEEP_EXECUTABLE"])
    let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let home = root.appendingPathComponent("home")
    let config = home.appendingPathComponent(".codex/deep-fixture.config.toml")
    let cwd = PathDisplayName.canonicalPath(fixture.project.path)
    let key = String(decoding: try JSONSerialization.data(withJSONObject: [cwd], options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
    let quotedCWD = String(key.dropFirst().dropLast())
    let original = try String(contentsOf: config, encoding: .utf8)
    try (original + "\n[projects.\(quotedCWD)]\ntrust_level = \"trusted\"\n").write(to: config, atomically: true, encoding: .utf8)
    try "export BANYAN_DEEP_EXPORT=retained\n".write(to: home.appendingPathComponent(".profile"), atomically: true, encoding: .utf8)
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let host = package.appendingPathComponent(".build/debug/banyanctl").path
    let environment = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "HOME": home.path,
        "CODEX_HOME": home.appendingPathComponent(".codex").path, "SHELL": "/bin/sh",
        "LANG": "en_US.UTF-8", "TERM": "xterm-256color", "BANYAN_PROCESS_HOST": host]
    let backend = TmuxBackend(environment: environment, workingDirectory: cwd,
        socketName: "banyan-deep-installed-\(UUID().uuidString)")
    let history = DefaultSessionHistoryBackend(homeDirectory: home)
    let store = fixture.makeStore(historyBackend: history, tmuxBackend: backend, processTable: LiveProcessTableProvider())
    let launch = [executable, "--no-daemon", "-s", "read-only", "-a", "never", "-p", "deep-fixture",
        "-c", "model_reasoning_effort=\"low\"", "-m", "fixture-model", "--no-alt-screen", "fixture:hello"]
        .map(AgentLaunchCommand.shellQuote).joined(separator: " ")
    let session = store.spawn(id: "installed-deep", title: "Private installed Codex", cwd: cwd, command: launch, select: false)
    defer { session.killBackingSession() }
    try await waitForPuckState(timeout: .seconds(15)) { backend.primaryPaneSnapshot(named: session.tmuxSessionName) != nil }
    let pane = try #require(backend.primaryPaneSnapshot(named: session.tmuxSessionName))

    func terminal(_ serial: Int, attached: Bool) async throws {
        let request: [String: Any] = ["serial": serial, "socket": backend.socketName,
            "session": session.tmuxSessionName, "attached": attached]
        try JSONSerialization.data(withJSONObject: request).write(to: root.appendingPathComponent("terminal-request.json"), options: .atomic)
        try await waitForPuckState(timeout: .seconds(10)) {
            FileManager.default.fileExists(atPath: root.appendingPathComponent("terminal-ack-\(serial)").path)
        }
    }

    try await terminal(1, attached: true)
    try await waitForPuckState(timeout: .seconds(30)) {
        backend.captureVisibleText(paneID: pane.paneID, lineLimit: 60).contains("FIXTURE_HELLO_OK")
    }
    let candidate = try #require(history.resumeCandidates(cwd: cwd, provider: .codex, maxFilesScanned: 100).first)
    let disk = AgentDiskSession(provider: .codex, id: candidate.sourceID, cwd: cwd)
    let rows = ProcessTable.snapshot().descendants(of: pane.rootPID)
    let agent = try #require(rows.first { AgentDeepSuspend.confirmsRecovery(disk, process: $0) })
    let before = try #require(AgentProcessSample.read(pid: Int32(agent.pid)))
    let transcript = try #require(AgentDeepSuspend.openTranscripts(pid: before.identity.pid).first { $0.lastPathComponent.contains(disk.id) })
    let shell = try #require(rows.first { $0.parentPID == pane.rootPID })
    let shellIdentity = try #require(AgentProcessSample.read(pid: Int32(shell.pid))?.identity)
    let completedBeforeHold = try String(contentsOf: transcript, encoding: .utf8).components(separatedBy: "task_complete").count
    _ = try await store.injectInput(id: session.id, keys: [], text: "fixture:steer", submit: false)
    try await Task.sleep(for: .milliseconds(600))
    _ = try await store.injectInput(id: session.id, keys: [], text: nil, submit: true)
    try await waitForPuckState(timeout: .seconds(10)) {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).contains {
            $0.lastPathComponent.hasPrefix("request-") && ((try? String(contentsOf: $0, encoding: .utf8))?.contains("fixture:steer") == true)
        }
    }
    try await terminal(2, attached: false)
    try await Task.sleep(for: .seconds(2.1))
    // A real Responses request is quiet and still in flight. Deliberately stale
    // frontend status must not override process-bound rollout turn evidence.
    session.status = .idle
    session.lastFreezeInteractionAt = .distantPast
    do {
        try await store.deepSuspendAgent(id: session.id)
        Issue.record("Deep suspend terminated Codex during a held model request")
    } catch {
        #expect(error.localizedDescription.contains("completed Codex turn"), "\(error.localizedDescription)")
    }
    #expect(AgentProcessSample.read(pid: before.identity.pid)?.identity == before.identity)
    #expect(backend.suspendTicket(named: session.tmuxSessionName) == nil)
    try Data().write(to: root.appendingPathComponent("release-steer"))
    try await terminal(3, attached: true)
    try await waitForPuckState(timeout: .seconds(10)) {
        ((try? String(contentsOf: transcript, encoding: .utf8))?.components(separatedBy: "task_complete").count ?? 0) > completedBeforeHold
    }
    try await terminal(4, attached: false)
    try await Task.sleep(for: .seconds(2.1))
    session.status = .idle
    session.lastFreezeInteractionAt = .distantPast
    try await store.deepSuspendAgent(id: session.id)
    #expect(AgentProcessSample.read(pid: before.identity.pid) == nil)
    #expect(session.suspendTicket?.disk == disk)
    #expect(backend.primaryPaneSnapshot(named: session.tmuxSessionName)?.paneID == pane.paneID)
    #expect(backend.primaryPaneSnapshot(named: session.tmuxSessionName)?.rootPID == pane.rootPID)
    #expect(AgentProcessSample.read(pid: shellIdentity.pid)?.identity == shellIdentity)
    try await waitForPuckState { AgentProcessSample.read(pid: shellIdentity.pid)?.foregroundGroupID == AgentProcessSample.read(pid: shellIdentity.pid)?.groupID }
    let shellProof = root.appendingPathComponent("shell-proof.txt")
    try backend.sendLiteral(paneID: pane.paneID, text: "printf '%s|%s' \"$PWD\" \"$BANYAN_DEEP_EXPORT\" > " + AgentLaunchCommand.shellQuote(shellProof.path))
    try backend.sendKeys(paneID: pane.paneID, keys: [.enter])
    try await waitForPuckState { FileManager.default.fileExists(atPath: shellProof.path) }
    let proof = try String(contentsOf: shellProof, encoding: .utf8)
    #expect(proof == cwd + "|retained")
    try store.deepResumeAgent(id: session.id)
    try await terminal(5, attached: true)
    try await waitForPuckState(timeout: .seconds(20)) { !session.isDeepResuming }
    #expect(!session.isDeepSuspended, "\(session.deepSuspendError ?? "")")
    let resumed = try #require(ProcessTable.snapshot().descendants(of: pane.rootPID).first {
        AgentDeepSuspend.confirmsRecovery(disk, process: $0)
    })
    #expect(resumed.pid != agent.pid)
    let actual = try #require(AgentDeepSuspend.providerCommand(provider: .codex, process: resumed)
        .flatMap(AgentSessionHistory.literalArguments))
    for (flag, value) in [("-s", "read-only"), ("-a", "never"), ("-p", "deep-fixture"),
        ("-c", "model_reasoning_effort=\"low\""), ("-m", "fixture-model")] {
        let index = try #require(actual.firstIndex(of: flag))
        #expect(actual.indices.contains(index + 1) && actual[index + 1] == value)
    }
    let previous = try String(contentsOf: transcript, encoding: .utf8).components(separatedBy: "task_complete").count
    _ = try await store.injectInput(id: session.id, keys: [], text: "fixture:hello-after-deep-resume", submit: false)
    try await Task.sleep(for: .milliseconds(600))
    _ = try await store.injectInput(id: session.id, keys: [], text: nil, submit: true)
    try await waitForPuckState(timeout: .seconds(20)) {
        ((try? String(contentsOf: transcript, encoding: .utf8))?.components(separatedBy: "task_complete").count ?? 0) > previous
    }
    let contexts = try String(contentsOf: transcript, encoding: .utf8).split(separator: "\n").compactMap { line -> [String: Any]? in
        guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              row["type"] as? String == "turn_context" else { return nil }
        return row["payload"] as? [String: Any]
    }
    let context = try #require(contexts.last)
    #expect(context["approval_policy"] as? String == "never")
    #expect((context["sandbox_policy"] as? [String: Any])?["type"] as? String == "read-only")
    #expect(context["model"] as? String == "fixture-model")
    let report: [String: Any] = ["provider": "codex", "sessionID": disk.id, "oldPID": agent.pid,
        "newPID": resumed.pid, "oldRSSBytes": before.residentBytes, "oldPIDAbsentAfterTERM": true,
        "paneID": pane.paneID, "paneRootPID": pane.rootPID, "shellPID": shell.pid,
        "samePaneAndShell": true, "cwdAndExportPreserved": true, "postResumeTurnCompleted": true,
        "quietInFlightRequestRefusedWithStaleIdleStatus": true, "busyPIDPreservedAndNoJournal": true,
        "sandboxApprovalProfileConfigModelPreserved": true]
    try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(to: root.appendingPathComponent("deep-suspend-evidence.json"))
    try await terminal(6, attached: false)
}
