import Foundation
import Testing
@testable import BanyanCore

/// Opt-in: never reads login files or connects to a running Codex/Banyan server.
/// A refused loopback inference persists a rollout without credentials or cost.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BANYAN_TEST_INSTALLED_CODEX"] == "1"),
    arguments: (ProcessInfo.processInfo.environment["BANYAN_TEST_CODEX_EXECUTABLES"] ?? "codex").split(separator: "\n").map(String.init))
func installedCodexSchemaStartupAndExactThreadResume(command: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("banyan-codex-smoke-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        "HOME": root.path, "CODEX_HOME": root.path, "TERM": "xterm-256color"]
    // Resolve once inside the same subprocess environment as the probe. A
    // parent shell's command lookup can differ from Foundation's child PATH.
    let lookup = try await SubprocessRunner.runAsync(arguments: ["/usr/bin/which", command],
        cwd: root.path, environment: environment, timeout: 10)
    try #require(lookup.terminationStatus == 0)
    let executable = String(decoding: lookup.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    try #require(executable.hasPrefix("/"))
    let version = try await SubprocessRunner.runAsync(arguments: [executable, "--version"],
        cwd: root.path, environment: environment, timeout: 10)
    #expect(version.terminationStatus == 0)
    let versionText = String(decoding: version.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(["codex-cli 0.160.0", "codex-cli 0.160.1"].contains(versionText))

    let schemaRoot = root.appendingPathComponent("schema")
    let generated = try await SubprocessRunner.runAsync(arguments: [executable, "app-server", "generate-json-schema", "--out", schemaRoot.path],
        cwd: root.path, environment: environment, timeout: 15)
    #expect(generated.terminationStatus == 0)
    for (file, fields) in [
        ("v1/InitializeResponse.json", ["userAgent"]),
        ("v2/ThreadStartParams.json", ["cwd", "model", "modelProvider", "approvalPolicy", "sandbox", "config"]),
        ("v2/ThreadResumeParams.json", ["threadId", "cwd", "model", "modelProvider", "approvalPolicy", "sandbox", "config"]),
        ("v2/ThreadUnsubscribeResponse.json", ["status"])
    ] {
        let schema = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: schemaRoot.appendingPathComponent(file))) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(fields).isSubset(of: Set(properties.keys)))
    }
    try #"""
    model_provider = "offline_probe"
    model = "test-model"
    [model_providers.offline_probe]
    name = "Private offline smoke"
    base_url = "http://127.0.0.1:1/v1"
    wire_api = "responses"
    requires_openai_auth = false
    supports_websockets = false
    request_max_retries = 0
    stream_max_retries = 0
    """#.write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    let client = CodexAppServerClient(executable: executable, environment: environment, requestTimeout: 15)
    do {
        let events = await client.events()
        try await client.connect()
        #expect(await client.storageHome() == root.path)
        let settings = CodexThreadSettings(model: "test-model", modelProvider: "offline_probe",
            approvalPolicy: "never", sandbox: "read-only")
        let started = try await client.request("thread/start", params: .object(settings.parameters(cwd: root.path)))
        let threadID = try #require(started.objectValue?["thread"]?.objectValue?["id"]?.stringValue)
        _ = try await client.request("turn/start", params: .object([
            "threadId": .string(threadID), "input": .array([.object([
                "type": .string("text"), "text": .string("Reply OK."), "text_elements": .array([])
            ])])
        ]))
        let completion = try await withThrowingTaskGroup(of: CodexJSONValue.self) { group in
            group.addTask {
                for await event in events {
                    if case .notification(method: "turn/completed", params: let params) = event { return params }
                }
                throw CodexAppServerError.disconnected("smoke event stream ended")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(25))
                throw CodexAppServerError.timedOut("offline turn")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        #expect(completion.objectValue?["turn"]?.objectValue?["status"] == .string("failed"))
        _ = try await client.request("thread/read", params: .object(["threadId": .string(threadID), "includeTurns": .bool(true)]))
        let detached = try await client.request("thread/unsubscribe", params: .object(["threadId": .string(threadID)]))
        #expect(detached.objectValue?["status"] == .string("unsubscribed"))
        try await client.disconnectForHandoff()
        var resume = settings.parameters(cwd: root.path)
        resume["threadId"] = .string(threadID)
        let restored = try await client.request("thread/resume", params: .object(resume))
        #expect(restored.objectValue?["thread"]?.objectValue?["id"] == .string(threadID))
        #expect(restored.objectValue?["modelProvider"] == .string("offline_probe"))
        #expect(restored.objectValue?["cwd"] == .string(root.path))
        // Run the generated fallback command through the installed CLI parser
        // without opening a TUI; settings serialization has fixture coverage.
        let command = try CodexCLIFallback.command(binding: .init(threadID: threadID, cwd: root.path,
            settings: settings, codexHome: root.path), executable: executable)
        let parsed = try await SubprocessRunner.runAsync(arguments: ["/bin/sh", "-c", command + " --help"],
            cwd: root.path, environment: environment, timeout: 10)
        #expect(parsed.terminationStatus == 0)
        #expect(String(decoding: parsed.standardOutput, as: UTF8.self).contains("Resume a previous interactive session"))
    } catch {
        await client.stop()
        throw error
    }
    await client.stop()
}
